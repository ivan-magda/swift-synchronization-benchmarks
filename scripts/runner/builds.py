from __future__ import annotations

from dataclasses import asdict
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import tempfile
from typing import Any, Dict, List, Optional

from runner.config import LocalConfig, Phone
from runner.processes import CommandRunner

FROZEN_XCODE = ('27.1', '27A9275')
FROZEN_SWIFT = 'swiftlang-6.4.0.34.1'
DEPLOYMENT_TARGETS = {'ios26': '26.0', 'ios18': '18.0'}
SETTINGS = (
    'SWIFT_VERSION',
    'SWIFT_OPTIMIZATION_LEVEL',
    'SWIFT_COMPILATION_MODE',
    'SWIFT_DEFAULT_ACTOR_ISOLATION',
    'SWIFT_APPROACHABLE_CONCURRENCY',
    'SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT',
    'SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES',
    'SWIFT_ENFORCE_EXCLUSIVE_ACCESS',
    'IPHONEOS_DEPLOYMENT_TARGET',
    'ARCHS',
    'ENABLE_TESTABILITY',
)


class BuildError(ValueError):
    """Build failure messages exclude private arguments and tool output."""


def make_build_id(commit: str, dirty: bool, target: str, now: datetime) -> str:
    if target not in DEPLOYMENT_TARGETS:
        raise BuildError('unknown build target')
    if not re.fullmatch(r'[0-9a-f]{12,40}', commit):
        raise BuildError('git commit must be a hexadecimal revision')
    if now.tzinfo is None:
        raise BuildError('build time requires a timezone')
    stamp = now.astimezone(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    return f'{commit[:12]}-{"dirty" if dirty else "clean"}-{target}-{stamp}'


def xcodebuild_arguments(
    target: str,
    config: LocalConfig,
    phone: Phone,
    build_id: str,
    commit: str,
    dirty: bool,
    derived_data: Path,
) -> List[str]:
    if target not in DEPLOYMENT_TARGETS:
        raise BuildError('unknown build target')
    return [
        'xcodebuild',
        '-project',
        'SyncBench.xcodeproj',
        '-scheme',
        'SyncBench',
        '-configuration',
        'Release',
        '-destination',
        'id=' + phone.udid,
        '-derivedDataPath',
        str(derived_data),
        '-allowProvisioningUpdates',
        '-allowProvisioningDeviceRegistration',
        'DEVELOPMENT_TEAM=' + config.team_id,
        'PRODUCT_BUNDLE_IDENTIFIER=' + config.bundle_id,
        'IPHONEOS_DEPLOYMENT_TARGET=' + DEPLOYMENT_TARGETS[target],
        'BENCH_BUILD_ID=' + build_id,
        'BENCH_GIT_COMMIT=' + commit,
        'BENCH_GIT_DIRTY=' + ('YES' if dirty else 'NO'),
        'BENCH_BUILD_TARGET=' + target,
        'build',
    ]


def _checked(
    arguments: List[str], run_command: CommandRunner, timeout: float = 60
) -> str:
    result = run_command(arguments, timeout)
    if result.return_code:
        raise BuildError(arguments[0] + ' failed')
    return result.stdout


def code_hash(executable: Path, run_command: CommandRunner) -> str:
    """SHA-256 of a copy of the executable after codesign --remove-signature."""
    with tempfile.TemporaryDirectory() as temporary:
        copy = Path(temporary) / executable.name
        shutil.copy2(executable, copy)
        _checked(['codesign', '--remove-signature', str(copy)], run_command)
        return hashlib.sha256(copy.read_bytes()).hexdigest()


def profile_expiry(app: Path, run_command: CommandRunner) -> datetime:
    text = _checked(
        ['security', 'cms', '-D', '-i', str(app / 'embedded.mobileprovision')],
        run_command,
    )
    try:
        expiry = plistlib.loads(text.encode('utf-8'))['ExpirationDate']
        if not isinstance(expiry, datetime):
            raise ValueError()
        return (
            expiry.replace(tzinfo=timezone.utc)
            if expiry.tzinfo is None
            else expiry.astimezone(timezone.utc)
        )
    except (ValueError, KeyError, TypeError, plistlib.InvalidFileException):
        raise BuildError('provisioning profile has no valid ExpirationDate') from None


def toolchain(run_command: CommandRunner) -> Dict[str, str]:
    xcode = _checked(['xcodebuild', '-version'], run_command)
    swift = _checked(['xcrun', 'swiftc', '--version'], run_command)
    sdk = _checked(
        ['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], run_command
    ).strip()
    version = re.search(r'^Xcode ([\d.]+)$', xcode, re.MULTILINE)
    build_version = re.search(r'^Build version ([A-Za-z0-9]+)$', xcode, re.MULTILINE)
    swift_version = re.search(r'swiftlang-[\d.]+', swift)
    if (
        not version
        or not build_version
        or not swift_version
        or not re.fullmatch(r'[\d.]+', sdk)
    ):
        raise BuildError('toolchain version output is invalid')
    return {
        'xcodeVersion': version[1],
        'xcodeBuild': build_version[1],
        'swiftVersion': swift_version[0],
        'sdkVersion': sdk,
    }


def build(
    target: str,
    config: LocalConfig,
    phone: Phone,
    results: Path,
    run_command: CommandRunner,
    now: datetime,
) -> Dict[str, Any]:
    root = results.resolve().parent
    if Path.cwd().resolve() != root:
        raise BuildError('build must run from the repository root')
    scratch = root / 'build' / 'private'
    scratch.mkdir(parents=True, exist_ok=True)

    def recorded(arguments, timeout=None):
        result = run_command(arguments, timeout)
        with tempfile.NamedTemporaryFile(
            mode='w',
            encoding='utf-8',
            dir=scratch,
            suffix='.diagnostic.json',
            delete=False,
        ) as output:
            json.dump(asdict(result), output, sort_keys=True, indent=2)
            output.write('\n')
        return result

    commit = _checked(['git', 'rev-parse', 'HEAD'], recorded).strip()
    dirty = bool(_checked(['git', 'status', '--porcelain'], recorded).strip())
    build_id = make_build_id(commit, dirty, target, now)
    destination = results / 'builds' / build_id
    artifact = root / 'build' / 'artifacts' / build_id / 'SyncBench.app'
    if destination.exists() or artifact.exists():
        raise BuildError('build ID already exists; retry with a later timestamp')
    versions = toolchain(recorded)
    if (
        (versions['xcodeVersion'], versions['xcodeBuild']) != FROZEN_XCODE
        or versions['swiftVersion'] != FROZEN_SWIFT
    ):
        raise BuildError('build requires the frozen Xcode and Swift toolchain')
    derived_data = root / 'build' / target
    arguments = xcodebuild_arguments(
        target, config, phone, build_id, commit, dirty, derived_data
    )
    _checked(['xcodegen', 'generate'], recorded)
    _checked(arguments, recorded, 1800)
    settings_text = _checked(
        arguments[:-1] + ['-showBuildSettings', '-json'], recorded, 120
    )
    try:
        targets = json.loads(settings_text)
        settings = next(
            entry['buildSettings']
            for entry in targets
            if entry['target'] == 'SyncBench'
        )
        selected = {key: settings.get(key, '') for key in SETTINGS}
    except (ValueError, KeyError, TypeError, StopIteration):
        raise BuildError('xcodebuild returned invalid build settings') from None
    source = (
        derived_data / 'Build' / 'Products' / 'Release-iphoneos' / 'SyncBench.app'
    )
    digest = code_hash(source / 'SyncBench', recorded)
    expiry = profile_expiry(source, recorded)
    info = dict(
        versions,
        buildID=build_id,
        commit=commit,
        dirty=dirty,
        target=target,
        deploymentTarget=DEPLOYMENT_TARGETS[target],
        codeHash=digest,
        profileExpires=expiry.isoformat(),
        app=artifact.relative_to(root).as_posix(),
        builtAt=now.astimezone(timezone.utc).isoformat(),
        settings=selected,
    )
    encoded = json.dumps(info, sort_keys=True, indent=2) + '\n'
    private_values = [config.team_id, config.bundle_id, str(root)] + [
        item.udid for item in config.phones.values()
    ]
    if any(value in encoded for value in private_values):
        raise BuildError('refusing to write private build metadata')
    # Original signatures/profiles contain private identities: retain the
    # installable app only in ignored build/.
    artifact.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, artifact)
    destination.mkdir(parents=True)
    (destination / 'build-info.json').write_text(encoded, encoding='utf-8')
    latest = {'buildID': build_id, 'app': info['app']}
    (results / 'builds' / ('latest-' + target + '.json')).write_text(
        json.dumps(latest, sort_keys=True, indent=2) + '\n', encoding='utf-8'
    )
    return info


def latest_build(results: Path, target: str) -> Optional[Dict[str, Any]]:
    if target not in DEPLOYMENT_TARGETS:
        raise BuildError('unknown build target')
    try:
        latest = json.loads(
            (results / 'builds' / ('latest-' + target + '.json')).read_text(
                encoding='utf-8'
            )
        )
        build_id = latest['buildID']
        if not isinstance(build_id, str) or not re.fullmatch(
            r'[A-Za-z0-9._-]+', build_id
        ):
            raise ValueError()
        info = json.loads(
            (results / 'builds' / build_id / 'build-info.json').read_text(
                encoding='utf-8'
            )
        )
        app = Path(info['app'])
        root = results.resolve().parent
        if app.is_absolute() or not (root / app).resolve().is_relative_to(root):
            raise ValueError()
        if not (root / app).is_dir():
            return None
        return info
    except FileNotFoundError:
        return None
    except (OSError, ValueError, KeyError, TypeError):
        raise BuildError('latest build metadata is invalid') from None
