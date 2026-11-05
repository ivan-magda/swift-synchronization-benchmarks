#!/usr/bin/env python3
from __future__ import annotations

import argparse
from typing import Optional, Sequence


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
    check.add_argument("file", nargs="?")
    parser.parse_args(arguments)
    print("not implemented")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
