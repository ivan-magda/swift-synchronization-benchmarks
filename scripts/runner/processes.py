from __future__ import annotations

from dataclasses import dataclass
import subprocess
from typing import Callable, List, Optional, Sequence


@dataclass
class ProcessResult:
    arguments: List[str]
    return_code: int
    stdout: str
    stderr: str


CommandRunner = Callable[[Sequence[str], Optional[float]], ProcessResult]


def run_command(
    arguments: Sequence[str], timeout_seconds: Optional[float] = None
) -> ProcessResult:
    command = list(map(str, arguments))
    try:
        completed = subprocess.run(
            command, capture_output=True, text=True, timeout=timeout_seconds
        )
        return ProcessResult(
            command, completed.returncode, completed.stdout, completed.stderr
        )
    except subprocess.TimeoutExpired as error:

        def text(value):
            return (
                value.decode('utf-8', errors='replace')
                if isinstance(value, bytes)
                else value or ''
            )

        return ProcessResult(command, 124, text(error.stdout), text(error.stderr))
    except OSError:
        # Do not expose arguments or host paths through an exception.
        return ProcessResult(command, 127, '', 'Command could not be started')
