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
    code_hash,
    latest_build,
    make_build_id,
    profile_expiry,
    xcodebuild_arguments,
)
from runner.config import LocalConfig, Phone
from runner.processes import ProcessResult

FIXTURES = Path(__file__).parent / 'fixtures'
NOW = datetime(2026, 11, 5, tzinfo=timezone.utc)
PHONE = Phone('fixture', 'UDID-FIXTURE', 'iPhone')
CONFIG = LocalConfig('TEAM-PRIVATE', 'dev.private.fixture', {'fixture': PHONE})


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
            output = json.dumps(
                [
                    {
                        'target': 'SyncBench',
                        'buildSettings': {
                            'SWIFT_VERSION': '6.0',
                            'SWIFT_OPTIMIZATION_LEVEL': '-O',
                            'DEVELOPMENT_TEAM': CONFIG.team_id,
                            'PRODUCT_BUNDLE_IDENTIFIER': CONFIG.bundle_id,
                        },
                    }
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
    def test_build_id_format(self):
        self.assertEqual(
            make_build_id('0123456789abcdef', False, 'ios26', NOW),
            '0123456789ab-clean-ios26-20261105T000000Z',
        )

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
            self.assertEqual(latest_build(results, 'ios26'), info)
            self.assertIsNone(latest_build(results, 'ios18'))

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

    def test_profile_expiry_is_read(self):
        self.assertEqual(
            profile_expiry(Path('app'), BuildRunner()),
            datetime(2026, 11, 12, tzinfo=timezone.utc),
        )

    def test_code_hash_ignores_the_signature_without_mutating_executable(self):
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / 'SyncBench'
            executable.write_bytes(b'codeSIGNATURE')
            self.assertEqual(
                code_hash(executable, BuildRunner()),
                '5694d08a2e53ffcae0c3103e5ad6f6076abd960eb1f8a56577040bc1028f702b',
            )
            self.assertEqual(executable.read_bytes(), b'codeSIGNATURE')
