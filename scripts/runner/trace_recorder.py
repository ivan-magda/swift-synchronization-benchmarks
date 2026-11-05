"""Bounded System Trace recording around one device attempt."""

from __future__ import annotations

from pathlib import Path
import secrets
import signal
import subprocess
from typing import Optional, Sequence


class SessionError(ValueError):
    """A session could not safely start or continue."""


def _popen(arguments: Sequence[str]):
    return subprocess.Popen(
        arguments, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )


def _wait(process, timeout_seconds: int) -> bool:
    try:
        process.wait(timeout=timeout_seconds)
        return True
    except subprocess.TimeoutExpired:
        return False


def _kill_and_reap(process, wait) -> None:
    process.kill()
    if not wait(process, timeout_seconds=5):
        raise SessionError('System Trace process did not exit after being killed')


class TraceRecorder:
    """Records a System Trace of every process on one phone around one attempt."""

    def __init__(self, popen=_popen, wait=_wait):
        self.popen = popen
        self.wait = wait
        self.listener: Optional[subprocess.Popen] = None
        self.process: Optional[subprocess.Popen] = None

    def start(self, udid: str, output: Path, time_limit_seconds: int) -> None:
        name = 'dev.syncbench.trace.' + secrets.token_hex(4)
        try:
            # Listen first, so the notification cannot be missed.
            self.listener = self.popen(['notifyutil', '-1', name])
            self.process = self.popen([
                'xcrun', 'xctrace', 'record',
                '--template', 'System Trace',
                '--device', udid,
                '--all-processes',
                '--time-limit', f'{time_limit_seconds}s',
                '--output', str(output),
                '--notify-tracing-started', name,
                '--no-prompt',
            ])
            if not self.wait(self.listener, timeout_seconds=60):
                raise SessionError('System Trace did not start within 60 seconds')
            if self.listener.returncode != 0:
                raise SessionError('System Trace start notification failed')
        except OSError:
            self.stop()
            raise SessionError('System Trace could not start') from None
        except BaseException:
            self.stop()
            raise

    def stop(self) -> None:
        # Clear ownership first: a session's finally may repeat startup cleanup.
        process = self.process
        listener = self.listener
        self.process = None
        self.listener = None
        try:
            if process is not None and process.poll() is None:
                try:
                    # SIGINT lets xctrace finish the file before it exits.
                    try:
                        process.send_signal(signal.SIGINT)
                    except ProcessLookupError:
                        pass
                    exited = self.wait(process, timeout_seconds=300)
                except BaseException:
                    _kill_and_reap(process, self.wait)
                    raise
                if not exited:
                    _kill_and_reap(process, self.wait)
        finally:
            if listener is not None and listener.poll() is None:
                try:
                    try:
                        listener.terminate()
                    except ProcessLookupError:
                        pass
                    exited = self.wait(listener, timeout_seconds=5)
                except BaseException:
                    _kill_and_reap(listener, self.wait)
                    raise
                if not exited:
                    _kill_and_reap(listener, self.wait)
