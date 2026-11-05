from __future__ import annotations

from collections import deque
from contextlib import redirect_stdout
from dataclasses import replace
from io import StringIO
import json
import signal
import subprocess
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, call, patch

from runner.config import LocalConfig, Phone
from runner.doctor import DoctorFinding
from runner.plans import load_plan
from runner.run_state import RunState, state_path
from runner.sessions import SessionError, run_session, status_report
from runner.trace_recorder import TraceRecorder

from tests.fake_device import FakeCaffeinate, FakeClock, FakeDevice, FakeRecorder

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
        self.info = dict(
            buildID='fixture-build',
            codeHash='a' * 64,
            dirty=True,
            target='ios26',
            app='build/artifacts/fixture/SyncBench.app',
        )
        self.plan = load_plan(PLANS / 'smoke-base-comparison.json')
        self.clock = FakeClock()
        self.caffeine = FakeCaffeinate()
        self.devices = FakeDevice(self.root / 'device', [], clock=self.clock)
        self.messages = []

    def run_session(self, outcomes=(), **kwargs):
        self.devices.outcomes.extend(outcomes)
        options = dict(
            sleep=self.clock.sleep,
            now=self.clock.now,
            monotonic=self.clock.monotonic,
            log=self.messages.append,
            inspect_environment=lambda *args, **kw: [],
            command=lambda *args: self.fail('unexpected external command'),
            caffeinate=self.caffeine,
        )
        options.update(kwargs)
        return run_session(
            self.plan, PHONE, CONFIG, self.results, self.devices, self.info, **options
        )

    def state(self):
        return RunState.load_or_create(
            state_path(
                self.results, self.plan, PHONE.key, self.info['codeHash'],
                dirty=self.info['dirty'],
            ),
            self.plan,
        )

    def metadata(self, summary):
        return json.loads(
            (self.results / PHONE.key / summary.session_id / 'session.json').read_text()
        )

    def test_all_runs_accepted_and_logged(self):
        summary = self.run_session(['complete', 'complete'])
        self.assertEqual(
            (
                summary.accepted,
                summary.rejected,
                summary.refused,
                summary.stop_reason,
            ),
            (2, 0, 0, None),
        )
        folder = self.results / PHONE.key / summary.session_id
        records = [
            json.loads(line)
            for line in (folder / 'session.log').read_text().splitlines()
        ]
        self.assertEqual(
            [item['status'] for item in records], ['completed', 'completed']
        )
        self.assertEqual([item['attempt'] for item in records], [1, 1])
        self.assertEqual(self.state().pending_runs(), [])
        self.assertTrue(
            all(
                json.loads(path.read_text())['accepted']
                for path in folder.glob('*.check.json')
            )
        )
        metadata = self.metadata(summary)
        self.assertTrue(metadata['dev'])
        self.assertEqual(
            (metadata['phone'], metadata['model'], metadata['osBuild']),
            ('fixture', 'iPhoneFixture', 'FIXTURE-BUILD'),
        )
        self.assertIn('end', metadata)
        self.assertEqual(self.devices.installed, [self.app.resolve()])
        self.assertEqual(self.caffeine.arguments[:3], ['caffeinate', '-i', '-w'])
        self.assertTrue(self.caffeine.stopped)
        self.assertEqual(self.clock.sleeps, [10, 2, 2])
        self.assertEqual(
            {r['variant'] for r in self.devices.requests}, {'oneThread', 'twoThreads'}
        )

    def traced_run(self):
        self.plan = replace(
            self.plan,
            traced=True,
            runs=(replace(self.plan.runs[0], traced=True),),
        )

    def test_trace_covers_launch_and_exit_before_copy_and_records_relative_path(self):
        self.traced_run()
        recorder = FakeRecorder(self.devices.events, self.clock, start_elapsed=45)
        summary = self.run_session(['complete'], recorder_factory=lambda: recorder)
        self.assertEqual(summary.accepted, 1)
        self.assertEqual(
            self.devices.events,
            ['trace start', 'launch', 'await exit', 'trace stop', 'copy', 'copy'],
        )
        attempt = self.state().attempts(self.plan.runs[0].run_id)[0]
        trace_file = 'traces/' + attempt['attemptID'] + '.trace'
        folder = self.results / PHONE.key / summary.session_id
        self.assertEqual(recorder.started, (PHONE.udid, folder / trace_file, 360))
        self.assertTrue((folder / 'traces').is_dir())
        self.assertTrue(attempt['traced'])
        self.assertEqual(attempt['traceFile'], trace_file)
        self.assertEqual(json.loads((folder / 'session.log').read_text()), attempt)
        self.assertTrue(self.devices.requests[0]['traced'])
        # A slow trace startup must not consume any of the app's 300-second budget.
        self.assertEqual(self.devices.launch_timeouts, [300])
        self.assertEqual(self.devices.wait_timeouts, [300])

    def test_trace_stops_after_timeout_termination_and_before_copy(self):
        self.traced_run()
        recorder = FakeRecorder(self.devices.events, self.clock)
        summary = self.run_session(['hang'], recorder_factory=lambda: recorder)
        self.assertEqual((summary.accepted, summary.rejected), (0, 1))
        self.assertEqual(
            self.devices.events,
            [
                'trace start', 'launch', 'await exit', 'terminate',
                'trace stop', 'copy', 'copy',
            ],
        )
        self.assertEqual(
            self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'timeout'
        )

    def test_trace_start_failure_cleans_up_and_never_launches(self):
        self.traced_run()
        recorder = FakeRecorder(
            self.devices.events,
            self.clock,
            start_error=SessionError('System Trace did not start within 60 seconds'),
        )
        with self.assertRaisesRegex(SessionError, 'System Trace did not start'):
            self.run_session(['complete'], recorder_factory=lambda: recorder)
        self.assertEqual(self.devices.events, ['trace start', 'trace stop'])
        self.assertTrue(self.caffeine.stopped)
        self.assertEqual(self.state().attempts(self.plan.runs[0].run_id), [])
        metadata_path = next(self.results.glob('fixture/*/session.json'))
        metadata = json.loads(metadata_path.read_text())
        self.assertEqual(metadata['summary']['stop_reason'], 'System Trace failed')

    def test_untraced_runs_create_no_recorder_or_trace_metadata(self):
        def unexpected_recorder():
            self.fail('untraced attempt created a recorder')

        summary = self.run_session(
            ['complete', 'complete'], recorder_factory=unexpected_recorder
        )
        self.assertEqual(summary.accepted, 2)
        folder = self.results / PHONE.key / summary.session_id
        self.assertFalse((folder / 'traces').exists())
        for run in self.plan.runs:
            attempt = self.state().attempts(run.run_id)[0]
            self.assertNotIn('traced', attempt)
            self.assertNotIn('traceFile', attempt)

    def test_trace_stops_on_launch_failure_and_interrupted_wait(self):
        self.traced_run()
        for outcome, interrupted, expected_events, status in [
            (
                'launch-failed', False,
                ['trace start', 'launch', 'trace stop'], 'launchFailed',
            ),
            (
                'hang', True,
                ['trace start', 'launch', 'await exit', 'terminate', 'trace stop'],
                'interrupted',
            ),
        ]:
            with self.subTest(outcome=outcome):
                self.devices.events.clear()
                self.devices.interrupt_wait = interrupted
                recorder = FakeRecorder(self.devices.events, self.clock)
                summary = self.run_session([outcome], recorder_factory=lambda: recorder)
                self.assertEqual(self.devices.events, expected_events)
                self.assertEqual(summary.rejected, 1)
                attempt = self.state().attempts(self.plan.runs[0].run_id)[-1]
                self.assertEqual(attempt['status'], status)

    def test_thermal_retry_uses_a_new_recorder_and_trace_path_per_attempt(self):
        self.traced_run()
        recorders = []

        def new_recorder():
            recorder = FakeRecorder(self.devices.events, self.clock)
            recorders.append(recorder)
            return recorder

        summary = self.run_session(
            ['refuse-thermal', 'complete'], recorder_factory=new_recorder
        )
        self.assertEqual((summary.refused, summary.accepted), (1, 1))
        self.assertEqual(len(recorders), 2)
        self.assertTrue(all(recorder.stopped for recorder in recorders))
        self.assertNotEqual(recorders[0].started[1], recorders[1].started[1])
        attempts = self.state().attempts(self.plan.runs[0].run_id)
        self.assertEqual([item['traced'] for item in attempts], [True, True])

    def test_thermal_refusal_retries_with_a_new_attempt_id(self):
        summary = self.run_session(['refuse-thermal', 'complete', 'complete'])
        first = self.plan.runs[0].run_id
        attempts = self.state().attempts(first)
        self.assertEqual(
            [(a['attempt'], a['status']) for a in attempts],
            [(1, 'refused'), (2, 'completed')],
        )
        self.assertNotEqual(attempts[0]['attemptID'], attempts[1]['attemptID'])
        self.assertIn(300, self.clock.sleeps)
        self.assertEqual((summary.accepted, summary.refused), (2, 1))

    def test_thermal_retries_used_up_stop_the_session(self):
        self.plan = replace(self.plan, max_thermal_retries=1)
        summary = self.run_session(['refuse-thermal', 'refuse-thermal'])
        self.assertEqual((summary.refused, summary.stop_reason), (2, 'thermal'))
        self.assertEqual(len(self.state().attempts(self.plan.runs[0].run_id)), 2)
        # A new session receives a fresh allowance without losing refusal history.
        resumed = self.run_session(['complete', 'complete'])
        self.assertEqual((resumed.accepted, resumed.stop_reason), (2, None))
        self.assertEqual(len(self.devices.requests), 4)
        attempts = self.state().attempts(self.plan.runs[0].run_id)
        self.assertEqual(
            [(a['attempt'], a['status']) for a in attempts],
            [(1, 'refused'), (2, 'refused'), (3, 'completed')],
        )
        self.assertEqual(len({a['attemptID'] for a in attempts}), 3)
        self.assertEqual(self.state().pending_runs(), [])

    def test_each_thermal_session_remains_bounded_after_exhaustion(self):
        self.plan = replace(self.plan, max_thermal_retries=1)
        for total_attempts in (2, 4):
            summary = self.run_session(['refuse-thermal', 'refuse-thermal'])
            self.assertEqual((summary.refused, summary.stop_reason), (2, 'thermal'))
            self.assertEqual(len(self.devices.requests), total_attempts)
        self.assertEqual(
            [a['attempt'] for a in self.state().attempts(self.plan.runs[0].run_id)],
            [1, 2, 3, 4],
        )

    def test_other_refusal_stops_the_session(self):
        summary = self.run_session(['refuse-battery'])
        self.assertEqual(
            (summary.refused, summary.stop_reason), (1, 'refused: battery')
        )
        self.assertEqual(len(self.state().pending_runs()), 2)

    def test_crash_report_is_copied_without_modifying_its_bytes(self):
        # Decode/re-encode or redaction must not alter a report copied from the phone.
        raw = b'{"incident_id":"FICTIONAL-INCIDENT"}\r\n{"frames":[]}\n\xff'

        def copy_crash(udid, source, destination):
            destination.write_bytes(raw)
            return True

        with patch.object(self.devices, 'copy_crash_log', side_effect=copy_crash):
            summary = self.run_session(['crash', 'complete'])
        self.assertEqual((summary.accepted, summary.rejected), (1, 1))
        folder = self.results / PHONE.key / summary.session_id / 'crash'
        copies = list(folder.rglob('*.ips'))
        self.assertEqual(len(copies), 1)
        self.assertEqual(copies[0].read_bytes(), raw)
        self.assertEqual(copies[0].name, self.devices.crash_source)
        self.assertEqual(self.devices.crash_bounds, [self.clock.now()])
        self.assertEqual(list(folder.rglob('*.provenance.json')), [])
        self.assertFalse((self.root / 'build/private').exists())

    def test_crash_report_published_after_two_polls_is_copied(self):
        self.plan = replace(self.plan, runs=self.plan.runs[:1])
        self.devices.crash_results = deque([[], [], [self.devices.crash_source]])
        summary = self.run_session(['crash'])
        folder = self.results / PHONE.key / summary.session_id
        self.assertEqual(len(list((folder / 'crash').rglob('*.ips'))), 1)
        self.assertEqual(self.clock.sleeps, [10, 5, 5, 2])
        self.assertEqual(self.devices.crash_timeouts, [30, 25, 20])
        self.assertTrue(
            all(bound == self.clock.now() for bound in self.devices.crash_bounds)
        )
        self.assertEqual((summary.rejected, summary.stop_reason), (1, None))
        self.assertEqual(
            self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'crashed'
        )

    def test_absent_crash_report_expires_grace_and_records_reason(self):
        self.plan = replace(self.plan, runs=self.plan.runs[:1])
        self.devices.crash_results = deque([[]])
        summary = self.run_session(['crash'])
        attempt = self.state().attempts(self.plan.runs[0].run_id)[0]
        self.assertEqual((attempt['status'], attempt['accepted']), ('crashed', False))
        self.assertIn(
            'no matching crash report appeared within 30 seconds', attempt['reasons']
        )
        self.assertEqual(self.clock.sleeps, [10, 5, 5, 5, 5, 5, 5, 2])
        folder = self.results / PHONE.key / summary.session_id
        self.assertFalse((folder / 'crash').exists())
        record = json.loads((folder / 'session.log').read_text())
        self.assertIn(
            'no matching crash report appeared within 30 seconds', record['reasons']
        )
        self.assertTrue(self.caffeine.stopped)

    def test_crash_grace_includes_listing_command_time(self):
        self.plan = replace(self.plan, runs=self.plan.runs[:1])
        self.devices.crash_results = deque([[]])
        self.devices.crash_query_elapsed = 30
        summary = self.run_session(['crash'])
        attempt = self.state().attempts(self.plan.runs[0].run_id)[0]
        self.assertIn(
            'no matching crash report appeared within 30 seconds', attempt['reasons']
        )
        self.assertEqual(self.clock.seconds, 42)
        self.assertEqual(self.clock.sleeps, [10, 2])
        self.assertEqual(self.devices.crash_timeouts, [30])

    def test_hang_is_terminated_as_timeout_even_with_a_done_file(self):
        self.devices.wait_elapsed = 300
        summary = self.run_session(['complete', 'complete'])
        self.assertEqual((summary.rejected, summary.accepted), (2, 0))
        self.assertEqual(self.devices.terminated, [321, 321])
        self.assertTrue(
            all(
                a['status'] == 'timeout'
                for r in self.plan.runs
                for a in self.state().attempts(r.run_id)
            )
        )
        self.assertFalse(
            list((self.results / PHONE.key / summary.session_id).glob('*.check.json'))
        )

    def test_launch_consumes_the_deadline_even_with_completed_files(self):
        self.plan = replace(self.plan, runs=self.plan.runs[:1])
        self.devices.launch_elapsed = 300
        summary = self.run_session(['complete'])
        self.assertEqual((summary.accepted, summary.rejected), (0, 1))
        self.assertEqual(self.devices.terminated, [321])
        self.assertEqual(self.devices.wait_timeouts, [])
        self.assertEqual(self.devices.launch_timeouts, [300])
        self.assertEqual(
            self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'timeout'
        )

    def test_expired_launch_command_discovers_and_terminates_started_process(self):
        self.plan = replace(self.plan, runs=self.plan.runs[:1])
        self.devices.launch_elapsed = 300
        self.devices.launch_error = True
        summary = self.run_session(['hang'])
        self.assertEqual(self.devices.terminated, [321])
        self.assertEqual((summary.accepted, summary.rejected), (0, 1))
        self.assertEqual(
            self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'timeout'
        )

    def test_slow_launch_leaves_only_remaining_time_to_wait(self):
        self.plan = replace(self.plan, runs=self.plan.runs[:1])
        self.devices.launch_elapsed = 280
        summary = self.run_session(['hang'])
        self.assertEqual(self.devices.wait_timeouts, [20])
        self.assertEqual(self.devices.launch_timeouts, [300])
        self.assertEqual(self.devices.terminated, [321])
        self.assertEqual((summary.accepted, summary.rejected), (0, 1))
        self.assertEqual(self.clock.seconds, 312)

    def test_wait_fallback_detects_exit_and_hang_without_resetting_the_deadline(self):
        self.devices.wait_error = True
        summary = self.run_session(['complete', 'hang'])
        self.assertEqual((summary.accepted, summary.rejected), (1, 1))
        self.assertEqual(self.devices.terminated, [321])
        self.assertEqual(
            self.state().attempts(self.plan.runs[1].run_id)[0]['status'], 'timeout'
        )
        self.assertEqual(self.clock.seconds, 314)

    def test_interrupt_keeps_attempt_and_terminates_the_inflight_process(self):
        self.devices.interrupt_wait = True
        summary = self.run_session(['hang'])
        self.assertEqual((summary.rejected, summary.stop_reason), (1, 'interrupted'))
        self.assertEqual(
            self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'interrupted'
        )
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
        paths = [
            folder / (attempt['attemptID'] + '.check.json'),
            self.state().path,
            folder / 'session.log',
        ]
        for path in paths:
            with self.subTest(artifact=path.name):
                text = path.read_text()
                self.assertNotIn(str(self.root), text)
                self.assertNotIn(str(self.root.resolve()), text)
        self.assertEqual(attempt['reasons'], ['attempt files could not be read'])

    def test_interrupt_during_timeout_termination_preserves_timeout_verdict(self):
        with patch.object(
            self.devices, 'terminate', side_effect=[KeyboardInterrupt(), None]
        ):
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
        self.assertEqual(
            self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'crashed'
        )
        self.assertIsNotNone(summary.stop_reason)


    def test_locked_phone_stops_and_next_session_resumes(self):
        first = self.run_session(['complete', 'locked'])
        second = self.run_session(['complete'])
        self.assertEqual((first.accepted, first.stop_reason), (1, 'phone locked'))
        self.assertEqual((second.accepted, second.stop_reason), (1, None))
        self.assertNotEqual(first.session_id, second.session_id)
        self.assertEqual(
            [r['runID'] for r in self.devices.requests],
            [r.run_id for r in self.plan.runs],
        )

    def test_new_code_hash_starts_a_new_state(self):
        self.run_session(['complete', 'complete'])
        self.info['codeHash'] = 'b' * 64
        summary = self.run_session(['complete', 'complete'])
        self.assertEqual(summary.accepted, 2)
        self.assertEqual(len(list((self.results / 'state').glob('*.json'))), 2)

    def test_dirty_acceptance_does_not_satisfy_clean_runs_with_the_same_hash(self):
        self.plan = replace(
            self.plan,
            smoke=False,
            runs=tuple(replace(run, smoke=False) for run in self.plan.runs),
        )
        dirty = self.run_session(['complete', 'complete'])
        dirty_state = self.state()
        dirty_bytes = dirty_state.path.read_bytes()
        self.assertEqual(dirty.accepted, 2)
        self.info['dirty'] = False
        self.info['buildID'] = 'fixture-clean-build'
        self.devices.build_id = 'fixture-clean-build'
        clean = self.run_session(['complete', 'complete'])
        self.assertEqual((clean.accepted, clean.stop_reason), (2, None))
        self.assertEqual(len(self.devices.requests), 4)
        self.assertNotEqual(self.state().path, dirty_state.path)
        self.assertEqual(dirty_state.path.read_bytes(), dirty_bytes)
        attempts = self.state().attempts(self.plan.runs[0].run_id)
        self.assertEqual(
            [(a['buildID'], a['dev']) for a in attempts],
            [('fixture-clean-build', False)],
        )
        resumed = self.run_session()
        self.assertEqual((resumed.accepted, resumed.stop_reason), (0, None))
        self.assertEqual(len(self.devices.requests), 4)

    def test_legacy_state_is_retained_without_crediting_unknown_eligibility(self):
        legacy_path = self.results / 'state' / (
            f'{self.plan.name}--{PHONE.key}--{self.plan.sha256[:8]}--aaaaaaaa.json'
        )
        legacy = RunState.load_or_create(legacy_path, self.plan)
        for run in self.plan.runs:
            legacy.record_attempt(run.run_id, {'accepted': True})
        previous = legacy_path.read_bytes()
        self.info['dirty'] = False
        summary = self.run_session(['complete', 'complete'])
        self.assertEqual(summary.accepted, 2)
        self.assertEqual(len(self.devices.requests), 2)
        self.assertEqual(legacy_path.read_bytes(), previous)
        self.assertNotEqual(self.state().path, legacy_path)

    def test_launch_failure_is_recorded_and_stops_the_session(self):
        summary = self.run_session(['launch-failed'])
        self.assertEqual((summary.rejected, summary.stop_reason), (1, 'launch failed'))
        self.assertEqual(
            self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'launchFailed'
        )
        self.assertTrue(self.caffeine.stopped)

    def test_three_failures_in_a_row_stop_the_session(self):
        self.plan = replace(
            self.plan,
            runs=(
                self.plan.runs[0],
                replace(self.plan.runs[0], run_id='second'),
                replace(self.plan.runs[0], run_id='third'),
                replace(self.plan.runs[0], run_id='fourth'),
            ),
        )
        summary = self.run_session(['crash', 'crash', 'crash', 'complete'])
        self.assertEqual(
            (summary.rejected, summary.stop_reason), (3, '3 failures in a row')
        )
        self.assertEqual(len(self.devices.requests), 3)

    def test_failed_copy_and_poll_are_recorded_and_cleanup_runs(self):
        for failure, expected in [
            ('copy_error', 'copyFailed'),
            ('poll_error', 'deviceFailed'),
        ]:
            with self.subTest(failure=failure):
                setattr(self.devices, failure, True)
                self.devices.wait_error = failure == 'poll_error'
                summary = self.run_session(
                    ['hang' if failure == 'poll_error' else 'complete']
                )
                attempts = self.state().attempts(self.plan.runs[0].run_id)
                self.assertEqual(attempts[-1]['status'], expected)
                self.assertIsNotNone(summary.stop_reason)
                self.assertTrue(self.caffeine.stopped)
                setattr(self.devices, failure, False)

    def test_wait_failure_uses_only_remaining_deadline_and_timeout_survives_copy_errors(
        self,
    ):
        self.devices.wait_error = True
        self.devices.wait_elapsed = 280
        self.devices.copy_error = True
        summary = self.run_session(['hang'])
        self.assertEqual(
            self.state().attempts(self.plan.runs[0].run_id)[0]['status'], 'timeout'
        )
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
            self.run_session(
                inspect_environment=lambda *args, **kw: [
                    DoctorFinding('unlocked', False, 'unlock phone')
                ]
            )
        self.info['target'] = 'ios18'
        with self.assertRaisesRegex(SessionError, 'target'):
            self.run_session()
        self.assertEqual(self.devices.installed, [])
        self.assertFalse(self.results.exists())

    def use_holder_work_from_calibration(self):
        run = self.plan.runs[0]
        tunables = dict(
            run.tunables,
            priorityInversion={
                'holderWorkIterations': 'fromCalibration',
                'loadQoS': 'userInitiated',
                'loadMilliseconds': 40,
                'mainDelayMicroseconds': 1000,
                'pauseMilliseconds': 5,
                'warmupTrials': 1,
                'trials': 3,
            },
        )
        self.plan = replace(self.plan, runs=(replace(run, tunables=tunables),))

    def write_phone_calibration(self, document):
        (self.results / PHONE.key).mkdir(parents=True, exist_ok=True)
        (self.results / PHONE.key / 'calibration.json').write_text(
            json.dumps(document)
        )

    def test_from_calibration_without_phone_work_size_stops_before_install(self):
        self.use_holder_work_from_calibration()
        with self.assertRaisesRegex(SessionError, 'results/fixture/calibration.json'):
            self.run_session()
        self.write_phone_calibration({'attemptID': 'calibration-fixture'})
        with self.assertRaisesRegex(SessionError, 'results/fixture/calibration.json'):
            self.run_session()
        self.assertEqual(self.devices.installed, [])
        self.assertEqual(self.devices.requests, [])

    def test_from_calibration_launches_the_phone_work_size(self):
        self.use_holder_work_from_calibration()
        self.write_phone_calibration(
            {
                'attemptID': 'calibration-fixture',
                'priorityInversion': {'holderWorkIterations': 5_000_000},
            }
        )
        summary = self.run_session(['complete'])
        self.assertEqual(
            [r['tunables']['priorityInversion']['holderWorkIterations']
             for r in self.devices.requests],
            [5_000_000],
        )
        self.assertEqual(
            self.metadata(summary)['calibrationAttemptID'], 'calibration-fixture'
        )
        self.assertEqual(
            self.plan.runs[0].tunables['priorityInversion']['holderWorkIterations'],
            'fromCalibration',
        )

    def test_session_without_from_calibration_records_no_calibration(self):
        summary = self.run_session(['complete', 'complete'])
        self.assertNotIn('calibrationAttemptID', self.metadata(summary))

    def test_install_failure_still_finishes_metadata_and_caffeinate(self):
        self.devices.install_error = True
        summary = self.run_session()
        self.assertEqual(summary.stop_reason, 'install failed')
        self.assertIn('end', self.metadata(summary))
        self.assertTrue(self.caffeine.stopped)
        self.assertNotIn(
            'private install',
            (
                self.results / PHONE.key / summary.session_id / 'session.json'
            ).read_text(),
        )

    def test_cli_runs_reports_status_and_saves_calibration_from_accepted_attempt(self):
        import bench

        (self.root / 'plans').mkdir()
        (self.root / 'plans/calibration.json').write_bytes(
            (PLANS / 'calibration.json').read_bytes()
        )
        (self.root / 'local.json').write_text(
            json.dumps(
                {
                    'teamID': CONFIG.team_id,
                    'bundleID': CONFIG.bundle_id,
                    'phones': {'fixture': {'udid': PHONE.udid, 'model': PHONE.model}},
                }
            )
        )

        def session(plan, phone, config, results, devices, info):
            return run_session(
                plan,
                phone,
                config,
                results,
                devices,
                info,
                sleep=self.clock.sleep,
                now=self.clock.now,
                log=lambda line: None,
                monotonic=self.clock.monotonic,
                inspect_environment=lambda *a, **k: [],
                caffeinate=self.caffeine,
                command=lambda *a: self.fail('unexpected external command'),
            )

        output = StringIO()
        with (
            patch('bench.REPOSITORY', self.root),
            patch('bench.latest_build', return_value=self.info),
            patch('runner.sessions.latest_build', return_value=self.info),
            patch('bench.DeviceControl', return_value=self.devices),
            patch('bench.run_session', side_effect=session),
            redirect_stdout(output),
        ):
            self.devices.outcomes.extend(['crash', 'complete'])
            self.assertEqual(
                bench.main(
                    [
                        'run',
                        '--phone',
                        'fixture',
                        '--plan',
                        str(PLANS / 'smoke-base-comparison.json'),
                    ]
                ),
                1,
            )
            self.assertEqual(
                bench.main(
                    ['status', '--plan', str(PLANS / 'smoke-base-comparison.json')]
                ),
                0,
            )
            self.assertIn('accepted 1, rejected 1', output.getvalue())
            self.assertEqual(bench.main(['calibrate', '--phone', 'fixture']), 0)
            calibration = json.loads(
                (self.results / 'fixture/calibration.json').read_text()
            )
            self.assertEqual(calibration['coreMap']['performance'], [0, 1])
            self.assertEqual(calibration['phone']['cpuCount'], 6)
            # Synthetic holderWork samples take 3 ticks on CPU 0; 5 ms is 120,000 ticks.
            self.assertEqual(
                calibration['priorityInversion'],
                {
                    'holderWorkIterations': 4_000_000_000,
                    'targetMilliseconds': 5,
                    'iterationsMeasured': 100_000,
                    'medianTicks': 3,
                    'samplesUsed': 200,
                },
            )
            self.assertTrue(
                calibration['attemptID'].startswith(
                    'calibration.calibration.1.attempt1.'
                )
            )

            # A later calibrate invocation reuses the accepted file from run state.
            self.assertEqual(bench.main(['calibrate', '--phone', 'fixture']), 0)
            self.assertEqual(len(self.devices.requests), 3)

    def test_status_report_counts_current_build_without_old_hash_progress(self):
        self.run_session(['crash', 'complete'])
        with patch('runner.sessions.latest_build', return_value=self.info):
            report = status_report(self.plan, PHONE.key, self.results)
        for phrase in ('accepted 1', 'rejected 1', 'refused 0', 'pending 1'):
            self.assertIn(phrase, report)
        with patch(
            'runner.sessions.latest_build',
            return_value=dict(self.info, dirty=False),
        ):
            report = status_report(self.plan, PHONE.key, self.results)
        self.assertIn('accepted 0', report)
        self.assertIn('rejected 0', report)
        self.assertIn('pending 2', report)
        with patch(
            'runner.sessions.latest_build',
            return_value=dict(self.info, codeHash='b' * 64),
        ):
            report = status_report(self.plan, PHONE.key, self.results)
        self.assertIn('accepted 0', report)
        self.assertIn('pending 2', report)


class TraceRecorderTests(unittest.TestCase):
    # Separate startup, graceful shutdown, forced shutdown and partial-start cleanup
    # cases guard independent process interleavings rather than duplicating wiring.
    def setUp(self):
        self.listener = Mock(returncode=0)
        self.listener.poll.return_value = 0
        self.listener.wait.return_value = 0
        self.process = Mock()
        self.process.poll.return_value = None
        self.process.wait.return_value = 0
        self.spawn = Mock(side_effect=[self.listener, self.process])
        self.effects = Mock()
        self.effects.attach_mock(self.spawn, 'spawn')
        self.effects.attach_mock(self.listener, 'listener')
        self.effects.attach_mock(self.process, 'process')
        self.recorder = TraceRecorder(popen=self.spawn)

    def test_start_listens_before_recording_and_waits_for_ready_before_returning(self):
        self.recorder.start(
            'FICTIONAL-DEVICE', Path('results/fixture/attempt.trace'), 360
        )
        notification = self.spawn.call_args_list[0].args[0][2]
        self.assertRegex(notification, r'^dev\.syncbench\.trace\.[0-9a-f]{8}$')
        self.assertEqual(self.effects.mock_calls[:3], [
            call.spawn(['notifyutil', '-1', notification]),
            call.spawn([
                'xcrun', 'xctrace', 'record', '--template', 'System Trace',
                '--device', 'FICTIONAL-DEVICE', '--all-processes',
                '--time-limit', '360s', '--output', 'results/fixture/attempt.trace',
                '--notify-tracing-started', notification, '--no-prompt',
            ]),
            call.listener.wait(timeout=60),
        ])
        self.recorder.stop()
        self.assertEqual(self.effects.mock_calls[3:], [
            call.process.poll(), call.process.send_signal(signal.SIGINT),
            call.process.wait(timeout=300), call.listener.poll(),
        ])

    def test_stop_kills_and_reaps_recorder_only_after_grace_period_expires(self):
        self.process.wait.side_effect = [subprocess.TimeoutExpired('xctrace', 300), 0]
        self.recorder.start('FICTIONAL-DEVICE', Path('results/attempt.trace'), 360)
        self.effects.reset_mock()
        self.recorder.stop()
        self.assertEqual(self.effects.mock_calls, [
            call.process.poll(), call.process.send_signal(signal.SIGINT),
            call.process.wait(timeout=300), call.process.kill(),
            call.process.wait(timeout=5), call.listener.poll(),
        ])

    def test_missing_start_notification_stops_both_processes_before_raising(self):
        self.listener.poll.return_value = None
        self.listener.wait.side_effect = [
            subprocess.TimeoutExpired('notifyutil', 60), 0,
        ]
        with self.assertRaisesRegex(
            SessionError, 'System Trace did not start within 60 seconds'
        ):
            self.recorder.start('FICTIONAL-DEVICE', Path('results/attempt.trace'), 360)
        self.process.send_signal.assert_called_once_with(signal.SIGINT)
        self.process.wait.assert_called_once_with(timeout=300)
        self.listener.terminate.assert_called_once_with()
        self.assertEqual(
            self.listener.wait.call_args_list, [call(timeout=60), call(timeout=5)]
        )

    def test_partial_start_and_failed_listener_clean_up_before_raising(self):
        for failure in ('spawn', 'notification'):
            with self.subTest(failure=failure):
                self.setUp()
                if failure == 'spawn':
                    self.spawn.side_effect = [self.listener, OSError('private path')]
                    self.listener.poll.return_value = None
                else:
                    self.listener.returncode = 1
                with self.assertRaises(SessionError):
                    self.recorder.start(
                        'FICTIONAL-DEVICE', Path('results/attempt.trace'), 360
                    )
                if failure == 'spawn':
                    self.listener.terminate.assert_called_once_with()
                    self.process.send_signal.assert_not_called()
                else:
                    self.process.send_signal.assert_called_once_with(signal.SIGINT)

    def test_interrupted_flush_still_reaps_recorder_and_stubborn_listener(self):
        self.process.wait.side_effect = [KeyboardInterrupt(), 0]
        self.listener.poll.return_value = None
        self.listener.wait.side_effect = [
            0, subprocess.TimeoutExpired('notifyutil', 5), 0,
        ]
        self.recorder.start('FICTIONAL-DEVICE', Path('results/attempt.trace'), 360)
        self.effects.reset_mock()
        with self.assertRaises(KeyboardInterrupt):
            self.recorder.stop()
        self.assertEqual(self.effects.mock_calls, [
            call.process.poll(), call.process.send_signal(signal.SIGINT),
            call.process.wait(timeout=300), call.process.kill(),
            call.process.wait(timeout=5), call.listener.poll(),
            call.listener.terminate(), call.listener.wait(timeout=5),
            call.listener.kill(), call.listener.wait(timeout=5),
        ])
        self.effects.reset_mock()
        self.recorder.stop()
        self.assertEqual(self.effects.mock_calls, [])

    def test_already_exited_recorder_is_not_interrupted(self):
        self.recorder.start('FICTIONAL-DEVICE', Path('results/attempt.trace'), 360)
        self.process.poll.return_value = 0
        self.recorder.stop()
        self.process.send_signal.assert_not_called()
        self.process.kill.assert_not_called()

    def test_interrupted_listener_cleanup_still_kills_and_reaps_listener(self):
        self.listener.poll.return_value = None
        self.listener.wait.side_effect = [0, KeyboardInterrupt(), 0]
        self.recorder.start('FICTIONAL-DEVICE', Path('results/attempt.trace'), 360)
        with self.assertRaises(KeyboardInterrupt):
            self.recorder.stop()
        self.listener.kill.assert_called_once_with()
        self.assertEqual(self.listener.wait.call_args_list, [
            call(timeout=60), call(timeout=5), call(timeout=5),
        ])
