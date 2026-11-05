"""Resumable sessions with bounded device waits and a durable record per launch."""

from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
from typing import Any, Callable, Dict, Optional, Sequence
from uuid import uuid4

from runner.attempt_check import AttemptVerdict, check_attempt
from runner.builds import latest_build
from runner.config import LocalConfig, Phone
from runner.device_control import DeviceControl, DeviceControlError
from runner.doctor import doctor
from runner.plans import Plan, encode_request, make_attempt_id, make_request
from runner.processes import run_command
from runner.run_state import RunState, state_path


class SessionError(ValueError):
    """Preflight prevented a session from starting."""


@dataclass
class SessionSummary:
    session_id: str
    accepted: int
    rejected: int
    refused: int
    stop_reason: Optional[str]


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _caffeinate(arguments: Sequence[str]):
    return subprocess.Popen(
        arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )


def _write_json(path: Path, document: Any) -> None:
    path.write_text(
        json.dumps(document, sort_keys=True, indent=2, allow_nan=False) + '\n',
        encoding='utf-8',
    )


def _await_exit(devices, phone, bundle_id, pid, deadline, sleep, monotonic) -> bool:
    # Launch, await and polling share the original monotonic deadline.
    if monotonic() >= deadline:
        return False
    try:
        exited, _ = devices.await_termination(
            phone.udid, pid, max(0.001, deadline - monotonic())
        )
        if monotonic() >= deadline:
            return False
        if exited:
            return True
    except DeviceControlError:
        pass
    while monotonic() < deadline:
        remaining = deadline - monotonic()
        try:
            pids = devices.running_pids(
                phone.udid, bundle_id, timeout_seconds=remaining
            )
        except DeviceControlError:
            if monotonic() >= deadline:
                return False
            raise
        if pid not in pids:
            return monotonic() < deadline
        sleep(min(30, max(0, deadline - monotonic())))
    return False


# Identity fields present in modern IPS and legacy crash reports. Keep diagnostic frames,
# symbols, offsets and hardware facts; retain the original only under ignored build/private.
_IDENTITY_KEYS = {
    'incident',
    'incidentid',
    'incidentidentifier',
    'crashreporterkey',
    'deviceidentifier',
    'deviceid',
    'devicename',
    'udid',
    'serialnumber',
    'ecid',
    'teamid',
    'teamidentifier',
    'signingid',
    'signingidentifier',
    'bundleid',
    'bundleidentifier',
    'cfbundleidentifier',
    'coalitionname',
    'userid',
    'anonymousuuid',
    'hostname',
    'username',
    'appleid',
}


def _identity_key(key: str) -> bool:
    return re.sub(r'[^a-z0-9]', '', key.lower()) in _IDENTITY_KEYS


def _scrub_crash(raw: str, config: LocalConfig, root: Path, context: str = '') -> str:
    private_values = {config.team_id, config.bundle_id, str(root)}
    private_values.update(phone.udid for phone in config.phones.values())
    documents = []
    decoder = json.JSONDecoder()
    remaining = raw.lstrip()
    try:
        while remaining:
            document, end = decoder.raw_decode(remaining)
            documents.append(document)
            remaining = remaining[end:].lstrip()
    except ValueError:
        documents = []

    def collect(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if (
                    _identity_key(key)
                    and isinstance(item, (str, int))
                    and not isinstance(item, bool)
                ):
                    private_values.add(str(item))
                collect(item)
        elif isinstance(value, list):
            for item in value:
                collect(item)

    for document in documents:
        collect(document)
    if context:
        remaining_context = context.lstrip()
        try:
            while remaining_context:
                document, end = decoder.raw_decode(remaining_context)
                collect(document)
                remaining_context = remaining_context[end:].lstrip()
        except ValueError:
            pass

    def scrub_text(text):
        for value in sorted(private_values, key=len, reverse=True):
            if value:
                text = text.replace(value, '<redacted>')
        # Paths may contain the phone's app-container identity or the host user's name.
        return re.sub(r'(?<![A-Za-z0-9])/(?:[^\s"<>]+)', '<redacted-path>', text)

    def scrub(value):
        if isinstance(value, dict):
            return {
                key: '<redacted>' if _identity_key(key) else scrub(item)
                for key, item in value.items()
            }
        if isinstance(value, list):
            return [scrub(item) for item in value]
        return scrub_text(value) if isinstance(value, str) else value

    if documents:
        return ''.join(
            json.dumps(scrub(document), sort_keys=True, indent=2) + '\n'
            for document in documents
        )
    # Legacy text reports have the same identities as labelled header lines.
    for line in raw.splitlines():
        label, separator, value = line.partition(':')
        if separator and _identity_key(label.strip()):
            private_values.add(value.strip())
    raw = re.sub(
        r'(?im)^((?:Incident Identifier|CrashReporter Key|Device Name|Identifier|'
        r'Team Identifier|User ID|Anonymous UUID|Serial Number)\s*:).*$',
        r'\1 <redacted>',
        raw,
    )
    return scrub_text(raw)


def _copy_crashes(
    devices,
    phone,
    config,
    results,
    folder,
    attempt_id,
    launched,
    sleep=time.sleep,
    monotonic=time.monotonic,
):
    # iOS publishes crash reports after process exit, sometimes more than 10s later.
    # Share one grace deadline across listing commands and sleeps.
    deadline = monotonic() + 30
    while True:
        remaining = deadline - monotonic()
        if remaining <= 0:
            return 'no matching crash report appeared within 30 seconds'
        sources = devices.crash_logs(
            phone.udid, 'SyncBench', newer_than=launched, timeout_seconds=remaining
        )
        if sources:
            break
        remaining = deadline - monotonic()
        if remaining > 0:
            sleep(min(5, remaining))
    private = (
        results.resolve().parent
        / 'build/private/sessions'
        / folder.name
        / 'crash'
        / attempt_id
    )
    public = folder / 'crash' / attempt_id
    copied = False
    for index, source in enumerate(sources):
        private.mkdir(parents=True, exist_ok=True)
        # Device filenames can themselves contain private identities.
        name = f'{index + 1}.ips'
        original = private / name
        if not devices.copy_crash_log(phone.udid, source, original):
            continue
        raw = original.read_bytes()
        scrubbed = _scrub_crash(
            raw.decode('utf-8', errors='replace'), config, results.resolve().parent
        )
        public.mkdir(parents=True, exist_ok=True)
        (public / name).write_text(scrubbed, encoding='utf-8')
        source_name = _scrub_crash(
            Path(source).name,
            config,
            results.resolve().parent,
            context=raw.decode('utf-8', errors='replace'),
        ).strip()
        _write_json(
            (public / name).with_suffix('.provenance.json'),
            {
                'attemptID': attempt_id,
                'source': source_name,
                'sha256': hashlib.sha256(raw).hexdigest(),
                'scrubbedSHA256': hashlib.sha256(scrubbed.encode('utf-8')).hexdigest(),
                'scrubbed': True,
                'launchedAt': launched.isoformat(),
            },
        )
        copied = True
    return None if copied else 'matching crash reports were unavailable when copied'


def run_session(
    plan: Plan,
    phone: Phone,
    config: LocalConfig,
    results: Path,
    devices: DeviceControl,
    build_info: Dict[str, Any],
    sleep: Callable[[float], None] = time.sleep,
    now: Callable[[], datetime] = utc_now,
    log: Callable[[str], None] = print,
    *,
    inspect_environment=doctor,
    command=run_command,
    caffeinate=_caffeinate,
    monotonic: Callable[[], float] = time.monotonic,
) -> SessionSummary:
    findings = inspect_environment(
        config, phone, plan, results, command, devices, now(), build_info=build_info
    )
    failed = [
        finding.name + ': ' + finding.detail for finding in findings if not finding.ok
    ]
    if failed:
        raise SessionError('doctor failed: ' + '; '.join(failed))
    if build_info.get('target') != plan.build_target:
        raise SessionError('plan build target does not match build metadata target')
    root = results.resolve().parent
    try:
        relative_app = Path(build_info['app'])
        app = (root / relative_app).resolve()
        app.relative_to(root)
        if relative_app.is_absolute() or not app.is_dir():
            raise ValueError()
    except (KeyError, TypeError, ValueError):
        raise SessionError(
            'build app must be an existing repository-relative path'
        ) from None
    state = RunState.load_or_create(
        state_path(
            results, plan, phone.key, build_info['codeHash'], dirty=build_info['dirty']
        ),
        plan,
    )
    started = now().astimezone(timezone.utc)
    session_id = (
        started.strftime('%Y%m%dT%H%M%SZ') + '.' + plan.name + '.' + uuid4().hex[:8]
    )
    folder = results / phone.key / session_id
    folder.mkdir(parents=True)
    summary = SessionSummary(session_id, 0, 0, 0, None)
    metadata = dict(
        phone=phone.key,
        model=phone.model,
        osBuild=None,
        buildID=build_info['buildID'],
        codeHash=build_info['codeHash'],
        dev=build_info['dirty'],
        plan=plan.name,
        planSHA256=plan.sha256,
        start=started.isoformat(),
    )
    _write_json(folder / 'session.json', metadata)
    (folder / 'session.log').touch()
    caffeine = None
    try:
        listed = devices.list_devices()
        device = next((item for item in listed if item.udid == phone.udid), None)
        if device is None:
            summary.stop_reason = 'phone unavailable'
            return summary
        metadata['model'] = device.model
        metadata['osBuild'] = device.os_build
        _write_json(folder / 'session.json', metadata)
        caffeine = caffeinate(['caffeinate', '-i', '-w', str(os.getpid())])
        try:
            devices.install(phone.udid, app)
        except DeviceControlError:
            summary.stop_reason = 'install failed'
            return summary
        sleep(plan.settle_seconds)
        failures = 0

        for run in state.pending_runs():
            # Thermal retries are a per-run allowance for this session. Persisted
            # refusals remain history and never exhaust ordinary maxAttempts.
            thermal_count = 0
            while True:
                attempts = state.attempts(run.run_id)
                if not devices.is_unlocked(phone.udid):
                    summary.stop_reason = 'phone locked'
                    break
                attempt_number = len(attempts) + 1
                launched = now().astimezone(timezone.utc)
                attempt_id = make_attempt_id(
                    run.run_id, attempt_number, launched, uuid4().hex[:8]
                )
                request = make_request(run, attempt_id, attempt_number)
                verdict = AttemptVerdict('launchFailed', False, None, [])
                stop = None
                pid = None
                deadline = monotonic() + run.time_limit_seconds
                try:
                    pid = devices.launch(
                        phone.udid,
                        config.bundle_id,
                        ['--bench-request', encode_request(request)],
                        timeout_seconds=max(0.001, deadline - monotonic()),
                    )
                except (DeviceControlError, OSError):
                    stop = 'launch failed'
                    verdict.reasons.append(stop)
                    if monotonic() >= deadline:
                        verdict = AttemptVerdict(
                            'timeout', False, None, ['run time limit exceeded']
                        )
                        # A timed-out CLI response may have started the app without
                        # returning its PID. Discover it only for bounded cleanup.
                        try:
                            for running_pid in devices.running_pids(
                                phone.udid, config.bundle_id, timeout_seconds=5
                            ):
                                devices.terminate(phone.udid, running_pid)
                        except (DeviceControlError, OSError):
                            verdict.reasons.append('timeout cleanup failed')

                if pid is not None:
                    try:
                        exited = _await_exit(
                            devices,
                            phone,
                            config.bundle_id,
                            pid,
                            deadline,
                            sleep,
                            monotonic,
                        )
                        if not exited:
                            verdict = AttemptVerdict(
                                'timeout', False, None, ['run time limit exceeded']
                            )
                            devices.terminate(phone.udid, pid)
                        else:
                            verdict = AttemptVerdict(
                                'crashed',
                                False,
                                None,
                                ['app exited without a done marker'],
                            )
                    except (DeviceControlError, OSError):
                        stop = 'device wait or termination failed'
                        if verdict.status != 'timeout':
                            verdict = AttemptVerdict(
                                'deviceFailed', False, None, [stop]
                            )
                            try:
                                devices.terminate(phone.udid, pid)
                            except DeviceControlError:
                                pass
                        else:
                            verdict.reasons.append(stop)
                    except KeyboardInterrupt:
                        stop = 'interrupted'
                        if verdict.status != 'timeout':
                            verdict = AttemptVerdict('interrupted', False, None, [stop])
                        try:
                            devices.terminate(phone.udid, pid)
                        except (DeviceControlError, OSError):
                            pass
                    files_copied = False
                    try:
                        if stop == 'interrupted':
                            raise KeyboardInterrupt()
                        result = folder / (attempt_id + '.jsonl')
                        marker = folder / (attempt_id + '.done')
                        devices.copy_from_app(
                            phone.udid,
                            config.bundle_id,
                            'Documents/runs/' + result.name,
                            result,
                        )
                        has_marker = devices.copy_from_app(
                            phone.udid,
                            config.bundle_id,
                            'Documents/runs/' + marker.name,
                            marker,
                        )
                        files_copied = True
                        if verdict.status not in ('timeout', 'deviceFailed'):
                            if has_marker:
                                verdict = check_attempt(
                                    result, marker, request, build_info['buildID']
                                )
                                _write_json(
                                    folder / (attempt_id + '.check.json'),
                                    asdict(verdict),
                                )
                            else:
                                crash_issue = _copy_crashes(
                                    devices,
                                    phone,
                                    config,
                                    results,
                                    folder,
                                    attempt_id,
                                    launched,
                                    sleep,
                                    monotonic,
                                )
                                if crash_issue:
                                    verdict.reasons.append(crash_issue)
                    except (DeviceControlError, OSError):
                        stop = 'result or crash copy failed'
                        if verdict.status not in ('timeout', 'deviceFailed', 'crashed'):
                            verdict = AttemptVerdict('copyFailed', False, None, [stop])
                        elif verdict.status == 'crashed' and not files_copied:
                            # A failed file query cannot prove an absent publication marker.
                            verdict = AttemptVerdict('copyFailed', False, None, [stop])
                        else:
                            verdict.reasons.append(stop)
                    except KeyboardInterrupt:
                        stop = 'interrupted'
                        if verdict.status != 'timeout':
                            verdict = AttemptVerdict('interrupted', False, None, [stop])
                record = dict(
                    time=now().astimezone(timezone.utc).isoformat(),
                    runID=run.run_id,
                    attemptID=attempt_id,
                    attempt=attempt_number,
                    status=verdict.status,
                    accepted=verdict.accepted,
                    reasons=verdict.reasons,
                    sessionID=session_id,
                    buildID=build_info['buildID'],
                    dev=build_info['dirty'],
                    files=[
                        path.relative_to(results).as_posix()
                        for path in sorted(folder.glob(attempt_id + '.*'))
                    ],
                )
                if verdict.reason_code is not None:
                    record['reasonCode'] = verdict.reason_code
                state.record_attempt(run.run_id, record)
                line = json.dumps(record, sort_keys=True)
                with (folder / 'session.log').open('a', encoding='utf-8') as output:
                    output.write(line + '\n')
                log(line)
                if verdict.accepted:
                    summary.accepted += 1
                    failures = 0
                elif verdict.status == 'refused':
                    summary.refused += 1
                    failures = 0
                else:
                    summary.rejected += 1
                    failures += 1
                if stop:
                    summary.stop_reason = stop
                    break
                if verdict.status == 'refused':
                    if verdict.reason_code != 'thermal':
                        summary.stop_reason = 'refused: ' + str(verdict.reason_code)
                        break
                    thermal_count += 1
                    if thermal_count > plan.max_thermal_retries:
                        summary.stop_reason = 'thermal'
                        break
                    sleep(plan.thermal_wait_seconds)
                    continue
                if failures >= 3:
                    summary.stop_reason = '3 failures in a row'
                    break
                sleep(plan.pause_seconds)
                break
            if summary.stop_reason:
                break
    except (DeviceControlError, OSError):
        summary.stop_reason = 'session device or local operation failed'
    except BaseException:
        summary.stop_reason = 'interrupted'
        raise
    finally:
        try:
            if caffeine is not None:
                caffeine.terminate()
                caffeine.wait(timeout=5)
        finally:
            metadata['end'] = now().astimezone(timezone.utc).isoformat()
            metadata['summary'] = asdict(summary)
            _write_json(folder / 'session.json', metadata)
    return summary


def status_report(plan: Plan, phone_key: str, results: Path) -> str:
    info = latest_build(results, plan.build_target)
    if info is None:
        return (
            f'{phone_key}: accepted 0, rejected 0, refused 0, '
            f'pending {len(plan.runs)}, exhausted 0 (no build)'
        )
    state = RunState.load_or_create(
        state_path(results, plan, phone_key, info['codeHash'], dirty=info['dirty']), plan
    )
    attempts = [attempt for run in plan.runs for attempt in state.attempts(run.run_id)]
    accepted = sum(attempt['accepted'] for attempt in attempts)
    refused = sum(attempt.get('status') == 'refused' for attempt in attempts)
    rejected = len(attempts) - accepted - refused
    pending = len(state.pending_runs())
    exhausted = len(plan.runs) - accepted - pending
    return (
        f'{phone_key}: accepted {accepted}, rejected {rejected}, refused {refused}, '
        f'pending {pending}, exhausted {exhausted}'
    )
