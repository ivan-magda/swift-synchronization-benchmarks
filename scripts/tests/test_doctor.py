from __future__ import annotations

from dataclasses import replace
from datetime import timedelta
import json
from pathlib import Path
import tempfile
import unittest

from runner.device_control import DeviceControl, DeviceControlError, DeviceInfo
from runner.doctor import doctor
from runner.plans import load_plan
from runner.processes import ProcessResult, run_command

from tests.test_builds import BuildRunner, CONFIG, FIXTURES, NOW, PHONE


class DeviceRunner:
    """Writes recorded JSON or controlled command failures to devicectl's output file."""

    def __init__(self, locked=False, fail=False):
        self.locked = locked
        self.fail = fail

    def __call__(self, arguments, timeout=None):
        name = (
            'list-devices'
            if 'list' in arguments
            else 'lock-state-' + ('locked' if self.locked else 'unlocked')
        )
        output = Path(arguments[arguments.index('--json-output') + 1])
        if not self.fail:
            output.write_text((FIXTURES / 'devicectl' / (name + '.json')).read_text())
        return ProcessResult(
            list(arguments), int(self.fail), 'private output', 'private error'
        )


class DoctorTests(unittest.TestCase):
    def test_devices_and_lock_state_are_read_with_live_probe_when_tunnel_disconnected(
        self,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            devices = DeviceControl(DeviceRunner(), Path(temporary))
            listed = devices.list_devices()
            self.assertEqual(len(listed), 2)
            self.assertEqual(listed[0].udid, 'UDID-IPHONE11')
            self.assertTrue(
                all(item.available and item.developer_mode for item in listed)
            )
            self.assertTrue(devices.is_unlocked('UDID-IPHONE11'))
            self.assertFalse(
                DeviceControl(DeviceRunner(locked=True), Path(temporary)).is_unlocked(
                    'UDID-IPHONE11'
                )
            )

    def test_device_failure_retains_private_diagnostics_without_exposing_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaises(DeviceControlError) as failure:
                DeviceControl(DeviceRunner(fail=True), Path(temporary)).is_unlocked(
                    'PRIVATE-UDID'
                )
            self.assertIn('lockState', str(failure.exception))
            self.assertNotIn('PRIVATE-UDID', str(failure.exception))
            self.assertNotIn('private error', str(failure.exception))
            self.assertTrue(any(Path(temporary).glob('*.diagnostic.json')))

    def test_doctor_findings(self):
        # Independent preflight gates must all be reported, even when earlier ones fail.
        plan = load_plan(Path('plans/smoke-base-comparison.json'))
        plan = replace(
            plan, ios_builds={PHONE.key: 'EXPECTED-BUILD'}, settle_seconds=60
        )

        class Tools(BuildRunner):
            def __call__(self, arguments, timeout=None):
                if list(arguments) == ['xcodebuild', '-version']:
                    return ProcessResult(
                        list(arguments), 0, 'Xcode 1.0\nBuild version WRONG\n', ''
                    )
                if list(arguments) == ['xcodegen', '--version']:
                    return ProcessResult(list(arguments), 127, '', '')
                return super().__call__(arguments, timeout)

        class Devices:
            def list_devices(self):
                return [
                    DeviceInfo(PHONE.udid, 'iPhone', '26.0', 'OTHER-BUILD', False, True)
                ]

            def is_unlocked(self, udid):
                return False

        with tempfile.TemporaryDirectory() as temporary:
            results = Path(temporary) / 'results'
            folder = results / 'builds' / 'fixture'
            folder.mkdir(parents=True)
            (folder / 'SyncBench.app').mkdir()
            info = {
                'buildID': 'fixture',
                'app': 'results/builds/fixture/SyncBench.app',
                'codeHash': 'a' * 64,
                'dirty': False,
                'profileExpires': (NOW + timedelta(seconds=59)).isoformat(),
            }
            (folder / 'build-info.json').write_text(json.dumps(info))
            (results / 'builds' / ('latest-' + plan.build_target + '.json')).write_text(
                json.dumps(info)
            )
            findings = {
                item.name: item
                for item in doctor(
                    CONFIG, PHONE, plan, results, Tools(), Devices(), NOW
                )
            }
            for name in (
                'xcode',
                'xcodegen',
                'developer-mode',
                'ios-build',
                'unlocked',
            ):
                self.assertFalse(findings[name].ok, name)
            self.assertTrue(findings['available'].ok)
            self.assertNotIn('profile', findings)

    def test_ios_build_fails_when_a_non_smoke_plan_lacks_the_phone(self):
        class Devices:
            def list_devices(self):
                return [
                    DeviceInfo(PHONE.udid, 'iPhone', '26.0', 'FIXTURE', True, True)
                ]

            def is_unlocked(self, udid):
                return True

        base = load_plan(Path('plans/smoke-base-comparison.json'))
        info = {
            'buildID': 'fixture',
            'codeHash': 'a' * 64,
            'profileExpires': (NOW + timedelta(days=1)).isoformat(),
            'dirty': True,
        }
        cases = (
            ({'another-phone': 'FIXTURE'}, False, False),
            ({PHONE.key: 'OTHER-BUILD'}, False, False),
            ({PHONE.key: 'FIXTURE'}, False, True),
            ({}, True, True),
        )
        for builds, smoke, expected in cases:
            with self.subTest(builds=builds, smoke=smoke):
                plan = replace(base, smoke=smoke, ios_builds=builds)
                with tempfile.TemporaryDirectory() as temporary:
                    findings = {
                        item.name: item
                        for item in doctor(
                            CONFIG,
                            PHONE,
                            plan,
                            Path(temporary) / 'results',
                            BuildRunner(),
                            Devices(),
                            NOW,
                            build_info=info,
                        )
                    }
                if smoke:
                    self.assertNotIn('ios-build', findings)
                else:
                    self.assertEqual(findings['ios-build'].ok, expected)

    def test_calibration_finding_requires_the_phone_work_size(self):
        base = load_plan(Path('plans/smoke-base-comparison.json'))
        run = base.runs[0]
        tunables = dict(
            run.tunables, priorityInversion={'holderWorkIterations': 'fromCalibration'}
        )
        plan = replace(base, runs=(replace(run, tunables=tunables),))

        class Devices:
            def list_devices(self):
                return [
                    DeviceInfo(PHONE.udid, 'iPhone', '26.0', 'FIXTURE', True, True)
                ]

            def is_unlocked(self, udid):
                return True

        info = {
            'buildID': 'fixture',
            'codeHash': 'a' * 64,
            'profileExpires': (NOW + timedelta(days=1)).isoformat(),
            'dirty': True,
        }
        with tempfile.TemporaryDirectory() as temporary:
            results = Path(temporary) / 'results'

            def calibration_finding(checked_plan):
                findings = doctor(
                    CONFIG,
                    PHONE,
                    checked_plan,
                    results,
                    BuildRunner(),
                    Devices(),
                    NOW,
                    build_info=info,
                )
                return next(
                    (item for item in findings if item.name == 'calibration'), None
                )

            self.assertIsNone(calibration_finding(base))
            missing = calibration_finding(plan)
            self.assertFalse(missing.ok)
            self.assertIn('results/' + PHONE.key + '/calibration.json', missing.detail)
            (results / PHONE.key).mkdir(parents=True)
            path = results / PHONE.key / 'calibration.json'
            path.write_text(json.dumps({'attemptID': 'calibration-fixture'}))
            self.assertFalse(calibration_finding(plan).ok)
            path.write_text(
                json.dumps(
                    {
                        'attemptID': 'calibration-fixture',
                        'priorityInversion': {'holderWorkIterations': 5_000_000},
                    }
                )
            )
            self.assertTrue(calibration_finding(plan).ok)

    def test_profile_expiry_does_not_block_launches(self):
        class Devices:
            def list_devices(self):
                return [DeviceInfo(PHONE.udid, 'iPhone', '26.0', 'FIXTURE', True, True)]

            def is_unlocked(self, udid):
                return True

        plan = load_plan(Path('plans/smoke-base-comparison.json'))
        for expiry in ((NOW - timedelta(days=1)).isoformat(),
                       (NOW + timedelta(seconds=1)).isoformat()):
            with self.subTest(expiry=expiry), tempfile.TemporaryDirectory() as temporary:
                findings = doctor(
                    CONFIG, PHONE, plan, Path(temporary) / 'results',
                    BuildRunner(), Devices(), NOW,
                    build_info={'buildID': 'fixture', 'codeHash': 'a' * 64,
                                'dirty': False, 'profileExpires': expiry},
                )
                self.assertNotIn('profile', {item.name for item in findings})
                self.assertTrue(all(item.ok for item in findings), findings)

    def test_run_command_handles_failure_missing_command_and_timeout(self):
        import sys

        result = run_command(
            [sys.executable, '-c', 'import sys;print("message");sys.exit(3)']
        )
        self.assertEqual((result.return_code, result.stdout.strip()), (3, 'message'))
        self.assertEqual(run_command(['no-such-task12-command']).return_code, 127)
        self.assertNotEqual(
            run_command(
                [sys.executable, '-c', 'import time;time.sleep(10)'], 0.01
            ).return_code,
            0,
        )
