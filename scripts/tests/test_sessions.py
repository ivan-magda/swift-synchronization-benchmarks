from __future__ import annotations

from contextlib import redirect_stdout
from dataclasses import replace
from io import StringIO
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from runner.config import LocalConfig, Phone
from runner.doctor import DoctorFinding
from runner.plans import load_plan
from runner.run_state import RunState, state_path
from runner.sessions import SessionError, run_session, status_report
from tests.fake_device import FakeCaffeinate, FakeClock, FakeDevice

PLANS = Path(__file__).resolve().parents[2] / 'plans'
PHONE = Phone('fixture', 'FICTIONAL-DEVICE', 'iPhoneFixture')
CONFIG = LocalConfig('FICTIONAL-TEAM', 'example.fixture.bench', {'fixture': PHONE})


class SessionTests(unittest.TestCase):
    # Persistence, recovery, timing and refusal gates each require their own observable case.
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.results = self.root / 'results'
        self.app = self.root / 'build/artifacts/fixture/SyncBench.app'
        self.app.mkdir(parents=True)
        self.info = dict(buildID='fixture-build', codeHash='a' * 64, dirty=True,
                         target='ios26', app='build/artifacts/fixture/SyncBench.app')
        self.plan = load_plan(PLANS / 'smoke-base-comparison.json')
        self.clock = FakeClock()
        self.caffeine = FakeCaffeinate()
        self.devices = FakeDevice(self.root / 'device', [], clock=self.clock)
        self.messages = []

    def run_session(self, outcomes=(), **kwargs):
        self.devices.outcomes.extend(outcomes)
        options = dict(sleep=self.clock.sleep, now=self.clock.now,
                       monotonic=self.clock.monotonic, log=self.messages.append,
                       inspect_environment=lambda *args, **kw: [],
                       command=lambda *args: self.fail('unexpected external command'),
                       caffeinate=self.caffeine)
        options.update(kwargs)
        return run_session(self.plan, PHONE, CONFIG, self.results, self.devices, self.info, **options)

    def state(self):
        return RunState.load_or_create(state_path(self.results, self.plan, PHONE.key,
                                                 self.info['codeHash']), self.plan)

    def metadata(self, summary):
        return json.loads((self.results / PHONE.key / summary.session_id / 'session.json').read_text())

    def test_all_runs_accepted_and_logged(self):
        summary = self.run_session(['complete', 'complete'])
        self.assertEqual((summary.accepted, summary.rejected, summary.refused, summary.stop_reason), (2, 0, 0, None))
        folder = self.results / PHONE.key / summary.session_id
        records = [json.loads(line) for line in (folder / 'session.log').read_text().splitlines()]
        self.assertEqual([item['status'] for item in records], ['completed', 'completed'])
        self.assertEqual([item['attempt'] for item in records], [1, 1])
        self.assertEqual(self.state().pending_runs(), [])
        self.assertTrue(all(json.loads(path.read_text())['accepted'] for path in folder.glob('*.check.json')))
        metadata = self.metadata(summary)
        self.assertTrue(metadata['dev'])
        self.assertEqual((metadata['phone'], metadata['model'], metadata['osBuild']), ('fixture', 'iPhoneFixture', 'FIXTURE-BUILD'))
        self.assertIn('end', metadata)
        self.assertEqual(self.devices.installed, [self.app.resolve()])
        self.assertEqual(self.caffeine.arguments[:3], ['caffeinate', '-i', '-w'])
        self.assertTrue(self.caffeine.stopped)
        self.assertEqual(self.clock.sleeps, [10, 2, 2])
        self.assertEqual({r['variant'] for r in self.devices.requests}, {'oneThread', 'twoThreads'})

    def test_thermal_refusal_retries_with_a_new_attempt_id(self):
        summary = self.run_session(['refuse-thermal', 'complete', 'complete'])
        first = self.plan.runs[0].run_id
        attempts = self.state().attempts(first)
        self.assertEqual([(a['attempt'], a['status']) for a in attempts], [(1, 'refused'), (2, 'completed')])
        self.assertNotEqual(attempts[0]['attemptID'], attempts[1]['attemptID'])
        self.assertIn(300, self.clock.sleeps)
        self.assertEqual((summary.accepted, summary.refused), (2, 1))

    def test_thermal_retries_used_up_stop_the_session(self):
        self.plan = replace(self.plan, max_thermal_retries=1)
        summary = self.run_session(['refuse-thermal', 'refuse-thermal'])
        self.assertEqual((summary.refused, summary.stop_reason), (2, 'thermal'))
        self.assertEqual(len(self.state().attempts(self.plan.runs[0].run_id)), 2)
        resumed = self.run_session(['complete'])
        self.assertEqual(resumed.stop_reason, 'thermal')
        self.assertEqual(len(self.devices.requests), 2)

    def test_other_refusal_stops_the_session(self):
        summary = self.run_session(['refuse-battery'])
        self.assertEqual((summary.refused, summary.stop_reason), (1, 'refused: battery'))
        self.assertEqual(len(self.state().pending_runs()), 2)

    def test_crash_copies_scrubbed_logs_and_preserves_private_original(self):
        summary = self.run_session(['crash', 'complete'])
        self.assertEqual((summary.accepted, summary.rejected), (1, 1))
        copies = list((self.results / PHONE.key / summary.session_id / 'crash').rglob('*.ips'))
        self.assertEqual(len(copies), 1)
        text = copies[0].read_text()
        for private in ('FICTIONAL-DEVICE', 'FICTIONAL-INCIDENT', 'FICTIONAL-REPORTER',
                        'example.fixture.bench', '/private/var'):
            self.assertNotIn(private, text)
        self.assertIn('benchmark', text)
        originals = list((self.root / 'build/private').rglob('*.ips'))
        self.assertEqual(len(originals), 1)
        self.assertIn('FICTIONAL-DEVICE', originals[0].read_text())
        self.assertEqual(self.devices.crash_bounds, [self.clock.now()])
        provenance = json.loads(copies[0].with_suffix('.provenance.json').read_text())
        self.assertEqual(provenance['source'], 'SyncBench-fixture.ips')
        self.assertIn('sha256', provenance)

    def test_hang_is_terminated_as_timeout_even_with_a_done_file(self):
        self.devices.wait_elapsed = 300
        summary = self.run_session(['complete', 'complete'])
        self.assertEqual((summary.rejected, summary.accepted), (2, 0))
        self.assertEqual(self.devices.terminated, [321, 321])
        self.assertTrue(all(a['status'] == 'timeout' for r in self.plan.runs for a in self.state().attempts(r.run_id)))
        self.assertFalse(list((self.results / PHONE.key / summary.session_id).glob('*.check.json')))

    def test_wait_fallback_detects_exit_and_hang_without_resetting_the_deadline(self):
        self.devices.wait_error = True
        summary = self.run_session(['complete', 'hang'])
        self.assertEqual((summary.accepted, summary.rejected), (1, 1))
        self.assertEqual(self.devices.terminated, [321])
        self.assertEqual(self.state().attempts(self.plan.runs[1].run_id)[0]['status'], 'timeout')
        self.assertEqual(self.clock.seconds, 314)

    def test_interrupt_keeps_attempt_and_terminates_the_inflight_process(self):
        self.devices.interrupt_wait = True
        summary = self.run_session(['hang'])
        self.assertEqual((summary.rejected, summary.stop_reason), (1, 'interrupted'))
        self.assertEqual(self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'interrupted')
        self.assertEqual(self.devices.terminated, [321])
        self.assertTrue(self.caffeine.stopped)

    def test_marker_without_result_keeps_local_paths_out_of_public_diagnostics(self):
        self.plan = replace(self.plan, runs=self.plan.runs[:1])
        copy_file = self.devices.copy_from_app

        # The marker is published locally while its result copy is absent.
        def missing_result(udid, bundle_id, source, destination):
            if source.endswith('.jsonl'):
                return False
            return copy_file(udid, bundle_id, source, destination)

        with patch.object(self.devices, 'copy_from_app', side_effect=missing_result):
            summary = self.run_session(['complete'])
        self.assertEqual((summary.accepted, summary.rejected), (0, 1))
        attempt = self.state().attempts(self.plan.runs[0].run_id)[0]
        self.assertEqual(attempt['status'], 'invalid')
        folder = self.results / PHONE.key / summary.session_id
        paths = [folder / (attempt['attemptID'] + '.check.json'),
                 self.state().path, folder / 'session.log']
        for path in paths:
            with self.subTest(artifact=path.name):
                text = path.read_text()
                self.assertNotIn(str(self.root), text)
                self.assertNotIn(str(self.root.resolve()), text)
        self.assertEqual(attempt['reasons'], ['attempt files could not be read'])

    def test_interrupt_during_timeout_termination_preserves_timeout_verdict(self):
        with patch.object(self.devices, 'terminate', side_effect=[KeyboardInterrupt(), None]):
            summary = self.run_session(['hang'])
        self.assertEqual((summary.rejected, summary.stop_reason), (1, 'interrupted'))
        attempt = self.state().attempts(self.plan.runs[0].run_id)[0]
        self.assertEqual((attempt['status'], attempt['accepted']), ('timeout', False))
        folder = self.results / PHONE.key / summary.session_id
        record = json.loads((folder / 'session.log').read_text())
        self.assertEqual(record['status'], 'timeout')
        self.assertTrue(self.caffeine.stopped)
        self.assertIn('end', self.metadata(summary))

    def test_crash_copy_failure_keeps_the_proven_crash_status(self):
        self.devices.crash_copy_error = True
        summary = self.run_session(['crash'])
        self.assertEqual(self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'crashed')
        self.assertIsNotNone(summary.stop_reason)

    def test_crash_source_provenance_scrubs_identities_learned_from_the_report(self):
        self.devices.crash_source = 'SyncBench-FICTIONAL-INCIDENT.ips'
        summary = self.run_session(['crash', 'complete'])
        folder = self.results / PHONE.key / summary.session_id
        for path in folder.rglob('*'):
            if path.is_file():
                self.assertNotIn('FICTIONAL-INCIDENT', path.read_text())

    def test_locked_phone_stops_and_next_session_resumes(self):
        first = self.run_session(['complete', 'locked'])
        second = self.run_session(['complete'])
        self.assertEqual((first.accepted, first.stop_reason), (1, 'phone locked'))
        self.assertEqual((second.accepted, second.stop_reason), (1, None))
        self.assertNotEqual(first.session_id, second.session_id)
        self.assertEqual([r['runID'] for r in self.devices.requests], [r.run_id for r in self.plan.runs])

    def test_new_code_hash_starts_a_new_state(self):
        self.run_session(['complete', 'complete'])
        self.info['codeHash'] = 'b' * 64
        summary = self.run_session(['complete', 'complete'])
        self.assertEqual(summary.accepted, 2)
        self.assertEqual(len(list((self.results / 'state').glob('*.json'))), 2)

    def test_launch_failure_is_recorded_and_stops_the_session(self):
        summary = self.run_session(['launch-failed'])
        self.assertEqual((summary.rejected, summary.stop_reason), (1, 'launch failed'))
        self.assertEqual(self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'launchFailed')
        self.assertTrue(self.caffeine.stopped)

    def test_three_failures_in_a_row_stop_the_session(self):
        self.plan = replace(self.plan, runs=(self.plan.runs[0], replace(self.plan.runs[0], run_id='second'),
                                          replace(self.plan.runs[0], run_id='third'), replace(self.plan.runs[0], run_id='fourth')))
        summary = self.run_session(['crash', 'crash', 'crash', 'complete'])
        self.assertEqual((summary.rejected, summary.stop_reason), (3, '3 failures in a row'))
        self.assertEqual(len(self.devices.requests), 3)

    def test_failed_copy_and_poll_are_recorded_and_cleanup_runs(self):
        for failure, expected in [('copy_error', 'copyFailed'), ('poll_error', 'deviceFailed')]:
            with self.subTest(failure=failure):
                setattr(self.devices, failure, True)
                self.devices.wait_error = failure == 'poll_error'
                summary = self.run_session(['hang' if failure == 'poll_error' else 'complete'])
                attempts = self.state().attempts(self.plan.runs[0].run_id)
                self.assertEqual(attempts[-1]['status'], expected)
                self.assertIsNotNone(summary.stop_reason)
                self.assertTrue(self.caffeine.stopped)
                setattr(self.devices, failure, False)

    def test_wait_failure_uses_only_remaining_deadline_and_timeout_survives_copy_errors(self):
        self.devices.wait_error = True
        self.devices.wait_elapsed = 280
        self.devices.copy_error = True
        summary = self.run_session(['hang'])
        self.assertEqual(self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'timeout')
        self.assertEqual(self.clock.sleeps, [10, 20])
        self.assertEqual(self.devices.terminated, [321])
        self.assertEqual(summary.rejected, 1)

    def test_max_attempts_are_respected_across_sessions(self):
        self.plan = replace(self.plan, max_attempts=1)
        self.run_session(['crash', 'complete'])
        summary = self.run_session(['complete'])
        self.assertEqual(summary.accepted, 0)
        self.assertEqual(len(self.devices.requests), 2)
        self.assertEqual(self.state().pending_runs(), [])

    def test_preflight_or_target_mismatch_never_installs(self):
        with self.assertRaisesRegex(SessionError, 'unlocked'):
            self.run_session(inspect_environment=lambda *args, **kw: [DoctorFinding('unlocked', False, 'unlock phone')])
        self.info['target'] = 'ios18'
        with self.assertRaisesRegex(SessionError, 'target'):
            self.run_session()
        self.assertEqual(self.devices.installed, [])
        self.assertFalse(self.results.exists())

    def test_install_failure_still_finishes_metadata_and_caffeinate(self):
        self.devices.install_error = True
        summary = self.run_session()
        self.assertEqual(summary.stop_reason, 'install failed')
        self.assertIn('end', self.metadata(summary))
        self.assertTrue(self.caffeine.stopped)
        self.assertNotIn('private install', (self.results / PHONE.key / summary.session_id / 'session.json').read_text())

    def test_cli_runs_reports_status_and_saves_calibration_from_accepted_attempt(self):
        import bench
        (self.root / 'plans').mkdir()
        (self.root / 'plans/calibration.json').write_bytes((PLANS / 'calibration.json').read_bytes())
        (self.root / 'local.json').write_text(json.dumps({
            'teamID': CONFIG.team_id, 'bundleID': CONFIG.bundle_id,
            'phones': {'fixture': {'udid': PHONE.udid, 'model': PHONE.model}},
        }))
        def session(plan, phone, config, results, devices, info):
            return run_session(plan, phone, config, results, devices, info,
                               sleep=self.clock.sleep, now=self.clock.now, log=lambda line: None,
                               monotonic=self.clock.monotonic, inspect_environment=lambda *a, **k: [],
                               caffeinate=self.caffeine,
                               command=lambda *a: self.fail('unexpected external command'))
        output = StringIO()
        with patch('bench.REPOSITORY', self.root), patch('bench.latest_build', return_value=self.info), \
             patch('runner.sessions.latest_build', return_value=self.info), \
             patch('bench.DeviceControl', return_value=self.devices), patch('bench.run_session', side_effect=session), \
             redirect_stdout(output):
            self.devices.outcomes.extend(['crash', 'complete'])
            self.assertEqual(bench.main(['run', '--phone', 'fixture', '--plan', str(PLANS / 'smoke-base-comparison.json')]), 1)
            self.assertEqual(bench.main(['status', '--plan', str(PLANS / 'smoke-base-comparison.json')]), 0)
            self.assertIn('accepted 1, rejected 1', output.getvalue())
            self.assertEqual(bench.main(['calibrate', '--phone', 'fixture']), 0)
            calibration = json.loads((self.results / 'fixture/calibration.json').read_text())
            self.assertEqual(calibration['coreMap']['performance'], [0, 1])
            self.assertEqual(calibration['phone']['cpuCount'], 6)
            self.assertTrue(calibration['attemptID'].startswith('calibration.calibration.1.attempt1.'))
            # A later calibrate invocation reuses the accepted file from run state.
            self.assertEqual(bench.main(['calibrate', '--phone', 'fixture']), 0)
            self.assertEqual(len(self.devices.requests), 3)

    def test_status_report_counts_current_build_without_old_hash_progress(self):
        self.run_session(['crash', 'complete'])
        with patch('runner.sessions.latest_build', return_value=self.info):
            report = status_report(self.plan, PHONE.key, self.results)
        for phrase in ('accepted 1', 'rejected 1', 'refused 0', 'pending 1'):
            self.assertIn(phrase, report)
        with patch('runner.sessions.latest_build', return_value=dict(self.info, codeHash='b' * 64)):
            report = status_report(self.plan, PHONE.key, self.results)
        self.assertIn('accepted 0', report)
        self.assertIn('pending 2', report)
