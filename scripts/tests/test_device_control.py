from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest

from runner.device_control import DeviceControl, DeviceControlError
from runner.processes import ProcessResult

FIXTURES = Path(__file__).parent / 'fixtures' / 'devicectl'


class DeviceRunner:
    """Replays captured CLI files and records the external command boundary."""

    def __init__(self, fixtures):
        self.fixtures = iter(fixtures)
        self.calls = []

    def __call__(self, arguments, timeout=None):
        self.calls.append((list(arguments), timeout))
        fixture = next(self.fixtures)
        if isinstance(fixture, str):
            document = json.loads((FIXTURES / (fixture + '.json')).read_text())
            response = {'return_code': 0, 'stdout': '', 'stderr': ''}
        else:
            response = fixture
            document = fixture.get('document', {})
        output = Path(arguments[arguments.index('--json-output') + 1])
        output.write_text(json.dumps(document))
        return ProcessResult(
            list(arguments),
            response['return_code'],
            response['stdout'],
            response['stderr'],
        )


class DeviceControlTests(unittest.TestCase):
    # The task requires >3 tests: the CLI boundary owns distinct parsing, lifecycle,
    # timeout, missing-file, timestamp, diagnostic and privacy contracts.
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)

    def device(self, fixtures):
        self.runner = DeviceRunner(fixtures)
        return DeviceControl(self.runner, self.folder)

    def test_launch_returns_pid_and_passes_arguments_after_double_dash(self):
        device = self.device(['launch'])
        self.assertEqual(
            device.launch(
                'PRIVATE-UDID', 'example.SyncBench', ['--bench-request', 'encoded']
            ),
            6323,
        )
        arguments = self.runner.calls[0][0]
        self.assertEqual(
            arguments[arguments.index('--') + 1 :], ['--bench-request', 'encoded']
        )
        self.assertLess(arguments.index('--json-output'), arguments.index('--'))

    def test_await_exited_and_timed_out(self):
        timeout = json.loads((FIXTURES / 'await-timeout.txt').read_text())
        device = self.device(
            ['await-exited', timeout, {'return_code': 124, 'stdout': '', 'stderr': ''}]
        )
        self.assertEqual(device.await_termination('PRIVATE-UDID', 6323, 30), (True, 0))
        self.assertEqual(
            device.await_termination('PRIVATE-UDID', 6323, 5), (False, None)
        )
        self.assertEqual(
            device.await_termination('PRIVATE-UDID', 6323, 1), (False, None)
        )
        arguments, deadline = self.runner.calls[-1]
        self.assertEqual(arguments[arguments.index('--timeout') + 1], '5')
        self.assertEqual(deadline, 1)

    def test_running_pids_filters_by_bundle(self):
        device = self.device(['launch', 'processes', 'processes'])
        device.launch('PRIVATE-UDID', 'example.SyncBench', [])
        self.assertEqual(
            device.running_pids('PRIVATE-UDID', 'example.SyncBench'), [6325]
        )
        with self.assertRaises(DeviceControlError):
            device.running_pids('PRIVATE-UDID', 'other.bundle')

    def test_copy_of_missing_file_returns_false(self):
        failure = json.loads((FIXTURES / 'copy-missing.json').read_text())
        missing = {'return_code': 1, 'stdout': '', 'stderr': '', 'document': failure}
        device = self.device([missing, missing, 'copy-from'])
        self.assertFalse(
            device.copy_from_app(
                'PRIVATE-UDID',
                'example.SyncBench',
                'Documents/runs/task13.no-such-file',
                self.folder / 'missing',
            )
        )
        self.assertFalse(
            device.copy_crash_log(
                'PRIVATE-UDID',
                'Documents/runs/task13.no-such-file',
                self.folder / 'missing',
            )
        )
        self.assertTrue(
            device.copy_from_app(
                'PRIVATE-UDID',
                'example.SyncBench',
                'Documents/runs/run.jsonl',
                self.folder / 'result',
            )
        )

    def test_crash_logs_filtered_by_name_and_strict_launch_timestamp(self):
        device = self.device(['crash-logs'] * 4)
        self.assertEqual(
            device.crash_logs('PRIVATE-UDID', 'Other-0'), ['NAME-Other-0.ips']
        )
        self.assertEqual(device.crash_logs('PRIVATE-UDID', 'SyncBench'), [])
        boundary = datetime(2026, 11, 5, 5, 0, 46, tzinfo=timezone.utc)
        self.assertEqual(device.crash_logs('PRIVATE-UDID', 'Other', boundary), [])
        self.assertEqual(
            device.crash_logs(
                'PRIVATE-UDID', 'Other', datetime(2026, 11, 5, tzinfo=timezone.utc)
            ),
            ['NAME-Other-0.ips'],
        )

    def test_malformed_json_raises_with_command_and_raw_file(self):
        # Wrong field types must not turn into success or leak private argv/output.
        malformed = json.loads((FIXTURES / 'malformed.json').read_text())
        cases = [
            ('install', lambda d: d.install('PRIVATE-UDID', Path('app')), malformed),
            (
                'launch',
                lambda d: d.launch('PRIVATE-UDID', 'PRIVATE-BUNDLE', []),
                {'process': {'processIdentifier': True}},
            ),
            (
                'awaitTermination',
                lambda d: d.await_termination('PRIVATE-UDID', 1, 5),
                {'terminationStatus': {}},
            ),
            (
                'processes',
                lambda d: d.running_pids('PRIVATE-UDID', 'PRIVATE-BUNDLE'),
                {'runningProcesses': None},
            ),
            ('terminate', lambda d: d.terminate('PRIVATE-UDID', 1), {}),
            (
                'copy from',
                lambda d: d.copy_crash_log(
                    'PRIVATE-UDID', 'name', self.folder / 'file'
                ),
                {},
            ),
            (
                'files',
                lambda d: d.crash_logs('PRIVATE-UDID', 'Other'),
                {
                    'files': [
                        {
                            'name': 'Other',
                            'relativePath': 'Other',
                            'resources': {'isDirectory': False},
                            'metadata': {'lastModDate': 'invalid'},
                        }
                    ]
                },
            ),
            ('list devices', lambda d: d.list_devices(), {'devices': [None]}),
        ]
        for label, invoke, payload in cases:
            with self.subTest(command=label):
                document = (
                    payload
                    if 'info' in payload
                    else {'info': {'outcome': 'success'}, 'result': payload}
                )
                device = self.device(
                    [
                        {
                            'return_code': 0,
                            'stdout': 'PRIVATE-OUTPUT',
                            'stderr': '',
                            'document': document,
                        }
                    ]
                )
                with self.assertRaises(DeviceControlError) as failure:
                    invoke(device)
                message = str(failure.exception)
                self.assertIn(label, message)
                self.assertNotIn('PRIVATE-', message)
                self.assertTrue(
                    any(
                        path.name in message
                        for path in self.folder.glob('*.diagnostic.json')
                    )
                )

    def test_unrecognized_command_failure_is_not_timeout_or_missing(self):
        for action in (
            lambda d: d.await_termination('PRIVATE-UDID', 1, 5),
            lambda d: d.copy_crash_log('PRIVATE-UDID', 'file', self.folder / 'file'),
        ):
            for error in ({'code': 7000, 'domain': 'other'}, []):
                device = self.device(
                    [
                        {
                            'return_code': 1,
                            'stdout': '',
                            'stderr': 'PRIVATE-ERROR',
                            'document': {'error': error},
                        }
                    ]
                )
                with self.assertRaises(DeviceControlError):
                    action(device)

    def test_commands_are_exact(self):
        device = self.device(
            [
                'install',
                'launch',
                'await-exited',
                'processes',
                'terminate',
                'copy-from',
                'crash-logs',
                'copy-crash',
            ]
        )
        destination = self.folder / 'result'
        device.install('UDID-TEST', Path('SyncBench.app'))
        device.launch(
            'UDID-TEST', 'example.SyncBench', ['--bench-request', 'encoded']
        )
        device.await_termination('UDID-TEST', 6323, 30)
        device.running_pids('UDID-TEST', 'example.SyncBench')
        device.terminate('UDID-TEST', 6326)
        device.copy_from_app(
            'UDID-TEST', 'example.SyncBench', 'Documents/runs/run.jsonl', destination
        )
        device.crash_logs('UDID-TEST', 'SyncBench')
        self.assertTrue(device.copy_crash_log('UDID-TEST', 'report.ips', destination))
        expected = [
            ['device', 'install', 'app', '--device', 'UDID-TEST', 'SyncBench.app'],
            [
                'device',
                'process',
                'launch',
                '--device',
                'UDID-TEST',
                '--terminate-existing',
                'example.SyncBench',
                '--',
                '--bench-request',
                'encoded',
            ],
            [
                'device',
                'process',
                'awaitTermination',
                '--device',
                'UDID-TEST',
                '--pid',
                '6323',
                '--timeout',
                '30',
            ],
            ['device', 'info', 'processes', '--device', 'UDID-TEST'],
            [
                'device',
                'process',
                'terminate',
                '--device',
                'UDID-TEST',
                '--pid',
                '6326',
                '--kill',
            ],
            [
                'device',
                'copy',
                'from',
                '--device',
                'UDID-TEST',
                '--domain-type',
                'appDataContainer',
                '--domain-identifier',
                'example.SyncBench',
                '--source',
                'Documents/runs/run.jsonl',
                '--destination',
                str(destination),
            ],
            [
                'device',
                'info',
                'files',
                '--device',
                'UDID-TEST',
                '--domain-type',
                'systemCrashLogs',
            ],
            [
                'device',
                'copy',
                'from',
                '--device',
                'UDID-TEST',
                '--domain-type',
                'systemCrashLogs',
                '--source',
                'report.ips',
                '--destination',
                str(destination),
            ],
        ]
        actual = []
        for arguments, _ in self.runner.calls:
            index = arguments.index('--json-output')
            self.assertEqual(Path(arguments[index + 1]).parent, self.folder)
            actual.append(arguments[2:index] + arguments[index + 2 :])
        self.assertEqual(actual, expected)
