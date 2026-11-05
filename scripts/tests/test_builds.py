from __future__ import annotations

import json
import tempfile
import unittest
from unittest.mock import patch
from datetime import datetime, timezone
from pathlib import Path

from runner.builds import (
    BuildError,
    build,
    latest_build,
    xcodebuild_arguments,
)
from runner.config import LocalConfig, Phone
from runner.processes import ProcessResult

FIXTURES = Path(__file__).parent / 'fixtures'
NOW = datetime(2026, 11, 5, tzinfo=timezone.utc)
PHONE = Phone('fixture', 'UDID-FIXTURE', 'iPhone')
CONFIG = LocalConfig('TEAM-PRIVATE', 'dev.private.fixture', {'fixture': PHONE})
# The settings of the two experiment 7C libraries as -showBuildSettings reports them.
TEMPLATE_SETTINGS = {
    'SWIFT_VERSION': '5.0',
    'SWIFT_APPROACHABLE_CONCURRENCY': 'YES',
    'SWIFT_DEFAULT_ACTOR_ISOLATION': 'MainActor',
    # Unset: they follow SWIFT_APPROACHABLE_CONCURRENCY, as in the Xcode template.
    'SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT': '',
    'SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES': '',
    'SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY': 'YES',
    'SWIFT_OPTIMIZATION_LEVEL': '-O',
    'SWIFT_COMPILATION_MODE': 'wholemodule',
}
SWIFT6_SETTINGS = {
    'SWIFT_VERSION': '6.0',
    'SWIFT_APPROACHABLE_CONCURRENCY': 'NO',
    'SWIFT_DEFAULT_ACTOR_ISOLATION': 'nonisolated',
    'SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT': 'NO',
    'SWIFT_UPCOMING_FEATURE_INFER_ISOLATED_CONFORMANCES': 'NO',
    'SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY': '',
    'SWIFT_OPTIMIZATION_LEVEL': '-O',
    'SWIFT_COMPILATION_MODE': 'wholemodule',
}
TARGET_SETTINGS = {
    'SyncBench': {
        'SWIFT_VERSION': '6.0',
        'SWIFT_OPTIMIZATION_LEVEL': '-O',
        'DEVELOPMENT_TEAM': CONFIG.team_id,
        'PRODUCT_BUNDLE_IDENTIFIER': CONFIG.bundle_id,
    },
    'IsolationProbeTemplate': dict(TEMPLATE_SETTINGS, DEVELOPMENT_TEAM=CONFIG.team_id),
    'IsolationProbeSwift6': SWIFT6_SETTINGS,
}


class BuildRunner:
    """Supplies tool responses and creates the app product on a build command."""

    def __call__(self, arguments, timeout=None):
        arguments = list(map(str, arguments))
        output = ''
        if arguments[:2] == ['git', 'rev-parse']:
            output = '0123456789abcdef\n'
        elif arguments[:2] == ['git', 'status']:
            output = ' M scripts/bench.py\n'
        elif arguments == ['xcodebuild', '-version']:
            output = 'Xcode 27.1\nBuild version 27A9275\n'
        elif arguments[:3] == ['xcrun', 'swiftc', '--version']:
            output = 'Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-test)\n'
        elif '--show-sdk-version' in arguments:
            output = '27.1\n'
        elif '-showBuildSettings' in arguments:
            # Like xcodebuild: a scheme lists only its own build target, SyncBench;
            # each -target lists that target.
            names = [
                arguments[index + 1]
                for index, argument in enumerate(arguments)
                if argument == '-target'
            ]
            output = json.dumps(
                [
                    {'target': name, 'buildSettings': TARGET_SETTINGS[name]}
                    for name in names or ['SyncBench']
                ]
            )
        elif arguments[0] == 'xcodebuild' and arguments[-1] == 'build':
            product = (
                Path(arguments[arguments.index('-derivedDataPath') + 1])
                / 'Build/Products/Release-iphoneos/SyncBench.app'
            )
            product.mkdir(parents=True, exist_ok=True)
            (product / 'SyncBench').write_bytes(b'codeSIGNATURE')
            (product / 'embedded.mobileprovision').write_bytes(b'profile')
        elif arguments[:2] == ['codesign', '--remove-signature']:
            path = Path(arguments[-1])
            path.write_bytes(path.read_bytes().replace(b'SIGNATURE', b''))
        elif arguments[:3] == ['security', 'cms', '-D']:
            output = (FIXTURES / 'profile.plist').read_text()
        return ProcessResult(arguments, 0, output, '')


class BuildsTests(unittest.TestCase):
    # These cover persisted metadata, signature-independent identity, and build settings:
    # separate contracts need more than the usual three tests.

    def test_ios18_arguments(self):
        arguments = xcodebuild_arguments(
            'ios18', CONFIG, PHONE, 'build-id', 'abc', True, Path('build/ios18')
        )
        for setting in (
            'IPHONEOS_DEPLOYMENT_TARGET=18.0',
            'BENCH_BUILD_ID=build-id',
            'BENCH_GIT_COMMIT=abc',
            'BENCH_GIT_DIRTY=YES',
            'BENCH_BUILD_TARGET=ios18',
            'DEVELOPMENT_TEAM=TEAM-PRIVATE',
            'PRODUCT_BUNDLE_IDENTIFIER=dev.private.fixture',
        ):
            self.assertIn(setting, arguments)
        self.assertIn('-allowProvisioningDeviceRegistration', arguments)
        self.assertEqual(arguments[-1], 'build')

    def test_build_info_has_no_personal_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            results = Path(temporary) / 'results'
            with patch('runner.builds.Path.cwd', return_value=results.parent.resolve()):
                info = build('ios26', CONFIG, PHONE, results, BuildRunner(), NOW)
            stored = results / 'builds' / info['buildID'] / 'build-info.json'
            document = stored.read_text()

            for private in (CONFIG.team_id, CONFIG.bundle_id, PHONE.udid, temporary):
                self.assertNotIn(private, document)

            self.assertFalse(Path(info['app']).is_absolute())
            self.assertTrue(info['app'].startswith('build/artifacts/'))
            self.assertFalse(any(results.rglob('*.app')))
            self.assertEqual(
                (results.parent / info['app'] / 'SyncBench').read_bytes(),
                b'codeSIGNATURE',
            )
            self.assertEqual(
                info['codeHash'],
                '5694d08a2e53ffcae0c3103e5ad6f6076abd960eb1f8a56577040bc1028f702b',
            )
            self.assertEqual(info['settings']['SWIFT_VERSION'], '6.0')
            self.assertEqual(info['profileExpires'], '2026-11-12T00:00:00+00:00')
            self.assertEqual(latest_build(results, 'ios26'), info)
            self.assertIsNone(latest_build(results, 'ios18'))

    def test_build_info_records_each_isolation_library_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            results = Path(temporary) / 'results'
            with patch('runner.builds.Path.cwd', return_value=results.parent.resolve()):
                info = build('ios26', CONFIG, PHONE, results, BuildRunner(), NOW)
            stored = json.loads(
                (results / 'builds' / info['buildID'] / 'build-info.json').read_text()
            )

        self.assertEqual(stored['settings']['SWIFT_VERSION'], '6.0')
        self.assertEqual(
            stored['librarySettings'],
            {
                'IsolationProbeTemplate': TEMPLATE_SETTINGS,
                'IsolationProbeSwift6': SWIFT6_SETTINGS,
            },
        )

    def test_foreign_cwd_is_rejected_before_commands_or_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch('runner.builds.Path.cwd', return_value=root / 'foreign'):
                with self.assertRaisesRegex(BuildError, 'repository root'):
                    build(
                        'ios26', CONFIG, PHONE, root / 'results',
                        lambda *args: self.fail('foreign build command ran'), NOW,
                    )
            self.assertEqual(list(root.iterdir()), [])
