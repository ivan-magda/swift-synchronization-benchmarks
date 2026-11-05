#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, Sequence

from runner.attempt_check import check_attempt
from runner.builds import BuildError, build as build_app, latest_build
from runner.calibration import CalibrationError, derive_core_map
from runner.config import ConfigError, REPOSITORY, load_local_config
from runner.device_control import DeviceControl, DeviceControlError
from runner.doctor import doctor as inspect_environment
from runner.plans import PlanError, load_plan
from runner.processes import run_command
from runner.run_state import RunState, StateError, state_path
from runner.sessions import SessionError, run_session, status_report


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
    run.add_argument("--plan", type=Path, required=True)

    status = commands.add_parser("status")
    status.add_argument("--plan", type=Path, required=True)

    check = commands.add_parser("check")
    check.add_argument("file", type=Path)
    check.add_argument("--request", type=Path, required=True)
    check.add_argument("--build-id", required=True)

    arguments = parser.parse_args(arguments)

    if arguments.command in ("build", "doctor", "run", "status", "calibrate"):
        try:
            config = load_local_config(REPOSITORY / "local.json")
            results = REPOSITORY / "results"
            if arguments.command == "status":
                plan = load_plan(arguments.plan)
                for phone_key in config.phones:
                    print(status_report(plan, phone_key, results))
                return 0
            if arguments.phone not in config.phones:
                raise ConfigError("phone key is not configured")
            phone = config.phones[arguments.phone]
            now = datetime.now(timezone.utc)

            if arguments.command == "build":
                info = build_app(arguments.target, config, phone, results, run_command, now)
                print(json.dumps(info, sort_keys=True))
                return 0

            path = REPOSITORY / "plans/calibration.json" if arguments.command == "calibrate" else arguments.plan
            plan = load_plan(path) if path is not None else None
            devices = DeviceControl(run_command, REPOSITORY / "build" / "private" / "devices")
            if arguments.command in ("run", "calibrate"):
                info = latest_build(results, plan.build_target)
                if info is None:
                    raise BuildError("build the plan target before starting a session")
                summary = run_session(plan, phone, config, results, devices, info)
                print(json.dumps(asdict(summary), sort_keys=True))
                state = RunState.load_or_create(state_path(results, plan, phone.key, info["codeHash"]), plan)
                accepted = [attempt for run in plan.runs for attempt in state.attempts(run.run_id)
                            if attempt["accepted"]]
                if arguments.command == "calibrate" and accepted:
                    attempt = accepted[-1]
                    files = [name for name in attempt.get("files", []) if name.endswith(".jsonl")]
                    if len(files) != 1:
                        raise CalibrationError("accepted calibration must identify one result file")
                    result = (results / files[0]).resolve()
                    if not result.is_relative_to(results.resolve()):
                        raise CalibrationError("accepted calibration file must be inside results")
                    core_map = derive_core_map(result)
                    with result.open(encoding="utf-8") as source:
                        facts = json.loads(source.readline())["phone"]
                    calibration = dict(coreMap=core_map, attemptID=attempt["attemptID"], phone=facts)
                    (results / phone.key / "calibration.json").write_text(
                        json.dumps(calibration, sort_keys=True, indent=2) + "\n", encoding="utf-8")
                return 0 if len(accepted) == len(plan.runs) and summary.stop_reason is None else 1
            findings = inspect_environment(
                config, phone, plan, results, run_command, devices, now
            )
            print(json.dumps([asdict(item) for item in findings], sort_keys=True))
            return 0 if all(item.ok for item in findings) else 1
        except (BuildError, CalibrationError, ConfigError, DeviceControlError, PlanError,
                SessionError, StateError, OSError) as error:
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
