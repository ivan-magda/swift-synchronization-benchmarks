#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Sequence

from runner.attempt_check import check_attempt
from runner.builds import BuildError, build as build_app
from runner.config import ConfigError, REPOSITORY, load_local_config
from runner.device_control import DeviceControl
from runner.doctor import doctor as inspect_environment
from runner.plans import PlanError, load_plan
from runner.processes import run_command


def main(arguments: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Run iPhone synchronization benchmarks")
    commands = parser.add_subparsers(dest="command", required=True)

    doctor = commands.add_parser("doctor")
    doctor.add_argument("--phone", required=True)
    doctor.add_argument("--plan", type=Path)

    build = commands.add_parser("build")
    build.add_argument("--target", choices=("ios26", "ios18"), required=True)
    build.add_argument("--phone", required=True)

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

    if arguments.command in ("build", "doctor"):
        try:
            config = load_local_config(REPOSITORY / "local.json")
            if arguments.phone not in config.phones:
                raise ConfigError("phone key is not configured")

            phone = config.phones[arguments.phone]
            results = REPOSITORY / "results"
            now = datetime.now(timezone.utc)

            if arguments.command == "build":
                info = build_app(arguments.target, config, phone, results, run_command, now)
                print(json.dumps(info, sort_keys=True))
                return 0

            plan = load_plan(arguments.plan) if arguments.plan is not None else None
            devices = DeviceControl(run_command, REPOSITORY / "build" / "private" / "devices")
            findings = inspect_environment(
                config, phone, plan, results, run_command, devices, now
            )
            print(json.dumps([asdict(item) for item in findings], sort_keys=True))
            return 0 if all(item.ok for item in findings) else 1
        except (BuildError, ConfigError, PlanError, OSError) as error:
            # OSError can include private absolute paths; never print it verbatim.
            message = (
                "local artifact could not be read or written"
                if isinstance(error, OSError)
                else str(error)
            )
            print(message)
            return 1

    if arguments.command == "check":
        try:
            request = json.loads(arguments.request.read_text(encoding="utf-8"))
            if not isinstance(request, dict):
                raise ValueError("request must be an object")
        except (OSError, ValueError, UnicodeError) as error:
            parser.error("request: " + str(error))

        verdict = check_attempt(
            arguments.file,
            arguments.file.with_suffix(".done"),
            request,
            arguments.build_id,
        )
        print(json.dumps(asdict(verdict), sort_keys=True))
        return 0 if verdict.accepted else 1

    print("not implemented")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
