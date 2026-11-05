#!/usr/bin/env python3
from __future__ import annotations

import argparse
from dataclasses import asdict
import json
from pathlib import Path
from typing import Optional, Sequence

from runner.attempt_check import check_attempt


def main(arguments: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Run iPhone synchronization benchmarks")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("doctor")
    build = commands.add_parser("build")
    build.add_argument("--target", choices=("ios26", "ios18"), required=True)
    calibrate = commands.add_parser("calibrate")
    calibrate.add_argument("--phone", required=True)
    run = commands.add_parser("run")
    run.add_argument("--phone", required=True)
    run.add_argument("--plan", required=True)
    status = commands.add_parser("status")
    status.add_argument("--plan", required=True)
    check = commands.add_parser("check")
    check.add_argument("file", type=Path)
    check.add_argument("--request", type=Path, required=True)
    check.add_argument("--build-id", required=True)
    arguments = parser.parse_args(arguments)
    if arguments.command == "check":
        try:
            request = json.loads(arguments.request.read_text(encoding="utf-8"))
            if not isinstance(request, dict):
                raise ValueError("request must be an object")
        except (OSError, ValueError, UnicodeError) as error:
            parser.error("request: " + str(error))
        verdict = check_attempt(
            arguments.file, arguments.file.with_suffix(".done"), request, arguments.build_id)
        print(json.dumps(asdict(verdict), sort_keys=True))
        return 0 if verdict.accepted else 1
    print("not implemented")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
