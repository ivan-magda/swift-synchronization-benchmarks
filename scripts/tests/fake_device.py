"""Scripted device boundary; real request expansion, result files and checks stay intact."""

from __future__ import annotations

import base64
import json
import shutil
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
from typing import List

from runner.device_control import DeviceControlError, DeviceInfo

from tests.synthetic_attempts import make_attempt_lines, write_attempt


class FakeClock:
    def __init__(self):
        self.seconds = 0.0
        self.sleeps: List[float] = []

    def monotonic(self):
        return self.seconds

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.seconds += seconds

    def now(self):
        return datetime(2026, 11, 5, tzinfo=timezone.utc)


class FakeCaffeinate:
    def __init__(self):
        self.arguments = []
        self.stopped = False

    def __call__(self, arguments):
        self.arguments = list(arguments)
        return self

    def terminate(self):
        self.stopped = True

    def wait(self, timeout=None):
        return 0


class FakeDevice:
    """Script launches and delayed crash listings; expose copied bytes and process effects."""

    def __init__(self, folder: Path, outcomes, build_id='fixture-build', clock=None):
        self.folder = folder
        folder.mkdir(parents=True, exist_ok=True)
        self.outcomes = deque(outcomes)
        self.build_id = build_id
        self.clock = clock or FakeClock()
        self.requests = []
        self.terminated = []
        self.installed = []
        self.copies = []
        self.crash_bounds = []
        self.current = None
        self.wait_error = False
        self.launch_error = False
        self.launch_elapsed = 0
        self.launch_timeouts = []
        self.wait_timeouts = []
        self.wait_elapsed = 0
        self.poll_error = False
        self.copy_error = False
        self.terminate_error = False
        self.install_error = False
        self.crash_copy_error = False
        self.interrupt_wait = False
        self.crash_source = 'SyncBench-fixture.ips'
        self.crash_results = None
        self.crash_timeouts = []
        self.crash_query_elapsed = 0

    def list_devices(self):
        return [
            DeviceInfo(
                'FICTIONAL-DEVICE', 'iPhoneFixture', '26.0', 'FIXTURE-BUILD', True, True
            )
        ]

    def is_unlocked(self, udid):
        if self.outcomes and self.outcomes[0] == 'locked':
            self.outcomes.popleft()
            return False
        return True

    def install(self, udid, app):
        if self.install_error:
            raise DeviceControlError('private install failure')
        self.installed.append(app)

    def launch(self, udid, bundle_id, app_arguments, timeout_seconds=60):
        self.launch_timeouts.append(timeout_seconds)
        self.clock.seconds += self.launch_elapsed
        self.current = self.outcomes.popleft() if self.outcomes else 'complete'
        if self.current == 'launch-failed':
            raise DeviceControlError('private launch failure')

        request = json.loads(
            base64.b64decode(app_arguments[app_arguments.index('--bench-request') + 1])
        )
        self.requests.append(request)

        if self.current not in ('crash', 'hang'):
            status = 'refused' if self.current.startswith('refuse-') else 'completed'
            reason = self.current.split('-', 1)[1] if status == 'refused' else None
            write_attempt(
                self.folder, make_attempt_lines(request, self.build_id, status, reason)
            )
        if self.launch_error:
            raise DeviceControlError('private launch timeout')
        return 321

    def await_termination(self, udid, pid, timeout_seconds):
        self.wait_timeouts.append(timeout_seconds)
        self.clock.seconds += self.wait_elapsed
        if self.interrupt_wait:
            raise KeyboardInterrupt()
        if self.wait_error:
            raise DeviceControlError('private wait failure')
        if self.current == 'hang':
            self.clock.seconds += max(0, timeout_seconds - self.wait_elapsed)
            return False, None
        return True, 0

    def running_pids(self, udid, bundle_id, timeout_seconds=60):
        if self.poll_error:
            raise DeviceControlError('private poll failure')
        return [321] if self.current == 'hang' else []

    def terminate(self, udid, pid):
        self.terminated.append(pid)
        if self.terminate_error:
            raise DeviceControlError('private terminate failure')

    def copy_from_app(self, udid, bundle_id, source, destination):
        self.copies.append(source)
        if self.copy_error:
            raise DeviceControlError('private copy failure')
        source_path = self.folder / Path(source).name
        if not source_path.exists():
            return False
        shutil.copyfile(source_path, destination)
        return True

    def crash_logs(self, udid, name_contains, newer_than=None, timeout_seconds=60):
        self.crash_bounds.append(newer_than)
        self.crash_timeouts.append(timeout_seconds)
        self.clock.seconds += self.crash_query_elapsed
        if self.crash_results is not None:
            if len(self.crash_results) > 1:
                return self.crash_results.popleft()
            return self.crash_results[0]
        return [self.crash_source]

    def copy_crash_log(self, udid, name, destination):
        if self.crash_copy_error:
            raise DeviceControlError('private crash copy failure')
        destination.write_text(
            json.dumps(
                {
                    'procName': 'SyncBench',
                    'incident_id': 'FICTIONAL-INCIDENT',
                    'deviceIdentifier': 'FICTIONAL-DEVICE',
                    'crashReporterKey': 'FICTIONAL-REPORTER',
                    'bundleInfo': {'CFBundleIdentifier': 'example.fixture.bench'},
                    'procPath': '/private/var/containers/FICTIONAL-DEVICE/SyncBench.app/SyncBench',
                    'frames': [{'symbol': 'benchmark', 'imageOffset': 123}],
                }
            )
        )
        return True
