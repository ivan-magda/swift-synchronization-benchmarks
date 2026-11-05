"""Validate the published bytes, schema and work of one benchmark attempt."""
from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional

from runner.expected_attempt import ExpectedAttempt, expected_attempt


@dataclass
class AttemptVerdict:
    status: str
    accepted: bool
    reason_code: Optional[str]
    reasons: List[str]


class _Invalid(ValueError):
    pass


def _require(condition: bool, reason: str) -> None:
    if not condition:
        raise _Invalid(reason)


def _string(value: Any, name: str) -> None:
    _require(isinstance(value, str), name + " must be a string")


def _integer(value: Any, name: str) -> None:
    _require(type(value) is int, name + " must be an integer")


def _unsigned(value: Any, name: str) -> None:
    _integer(value, name)
    _require(value >= 0, name + " must be nonnegative")


def _uint64(value: Any, name: str) -> None:
    _unsigned(value, name)
    _require(value < 2 ** 64, name + " exceeds UInt64")


def _uint32(value: Any, name: str) -> None:
    _unsigned(value, name)
    _require(value < 2 ** 32, name + " exceeds UInt32")


def _boolean(value: Any, name: str) -> None:
    _require(type(value) is bool, name + " must be a boolean")


def _object(value: Any, name: str) -> None:
    _require(isinstance(value, dict), name + " must be an object")


def _enum(*choices: str) -> Callable[[Any, str], None]:
    def validate(value: Any, name: str) -> None:
        _string(value, name)
        _require(value in choices, name + " has an unknown value")
    return validate


def _array(validator: Callable[[Any, str], None]) -> Callable[[Any, str], None]:
    def validate(value: Any, name: str) -> None:
        _require(isinstance(value, list), name + " must be an array")
        for index, item in enumerate(value):
            validator(item, f"{name}[{index}]")
    return validate


def _fields(value: Any, name: str, required: Dict[str, Callable],
            optional: Optional[Dict[str, Callable]] = None) -> None:
    _object(value, name)
    for key, validate in required.items():
        _require(key in value, name + "." + key + " is missing")
        validate(value[key], name + "." + key)
    for key, validate in (optional or {}).items():
        if key in value:
            validate(value[key], name + "." + key)


_THERMAL = _enum("nominal", "fair", "serious", "critical")
_QOS = _enum("userInteractive", "userInitiated", "default", "utility", "background")
_CPUS = _array(_integer)


def _conditions(value: Any, name: str) -> None:
    _fields(value, name, {
        "thermalState": _THERMAL, "lowPowerMode": _boolean,
        "batteryState": _enum("unknown", "unplugged", "charging", "full"),
        "batteryLevelPermille": _integer, "screenBrightnessPermille": _integer,
        "debuggerAttached": _boolean,
        "applicationState": _enum("active", "inactive", "background"),
        "environment": _object, "ticks": _uint64, "wallClock": _string,
    })
    for key, item in value["environment"].items():
        _string(item, name + ".environment." + key)


def _build(value: Any, name: str) -> None:
    _fields(value, name, {
        "buildID": _string, "commit": _string, "dirty": _boolean,
        "target": _enum("ios26", "ios18"), "minimumOS": _string,
        "configuration": _enum("Release", "Debug"),
    })


def _performance_level(value: Any, name: str) -> None:
    _fields(value, name, {
        "index": _integer, "name": _string, "logicalCPUCount": _integer,
        "physicalCPUCount": _integer, "l1DataCacheBytes": _integer,
        "l2CacheBytes": _integer, "cpusPerL2": _integer,
    })


def _phone(value: Any, name: str) -> None:
    _fields(value, name, {
        "machine": _string, "osVersion": _string, "osBuild": _string,
        "cpuCount": _integer, "activeCPUCount": _integer,
        "performanceLevels": _array(_performance_level), "cacheLineBytes": _integer,
        "memoryBytes": _uint64, "timebaseNumerator": _uint32,
        "timebaseDenominator": _uint32, "mainThreadQoSClass": _uint32,
    }, {"mutexDefaultPolicy": _string, "ulockAdaptiveSpinMicroseconds": _integer})


def _check(value: Any, name: str) -> None:
    _fields(value, name, {"name": _string, "passed": _boolean, "detail": _string},
            {"block": _unsigned, "violations": _unsigned})


def _thermal_change(value: Any, name: str) -> None:
    _fields(value, name, {"ticks": _uint64, "thermalState": _THERMAL})


def _validate_line(line: Any, number: int) -> None:
    name = f"line {number}"
    _fields(line, name, {"type": _enum("run", "reference", "block", "batch", "samples", "end")})
    kind = line["type"]
    if kind == "run":
        _fields(line, name, {"schema": _unsigned, "request": _object, "build": _build,
                             "phone": _phone, "conditions": _conditions})
        _require(line["schema"] == 1, name + ".schema must be 1")
    elif kind == "reference":
        _fields(line, name, {"when": _enum("start", "end"), "iterations": _unsigned,
                             "start": _uint64, "end": _uint64, "cpuReadings": _CPUS})
    elif kind == "block":
        _fields(line, name, {
            "block": _unsigned, "mechanism": _string, "operation": _string,
            "threads": _unsigned, "qos": _QOS, "operationsPerBatch": _unsigned,
            "start": _uint64, "end": _uint64, "voluntaryContextSwitches": _unsigned,
            "involuntaryContextSwitches": _unsigned, "taskContextSwitches": _unsigned,
            "thermalStateAtStart": _THERMAL, "thermalStateAtEnd": _THERMAL,
        })
    elif kind == "batch":
        _fields(line, name, {
            "block": _unsigned, "batch": _unsigned, "thread": _unsigned,
            "warmup": _boolean, "operations": _unsigned,
            "start": _uint64, "end": _uint64, "cpuReadings": _CPUS,
        }, {"executorCPUReadings": _CPUS})
    elif kind == "samples":
        _fields(line, name, {"metric": _string, "unit": _string, "values": _array(_uint64)},
                {"block": _unsigned, "thread": _unsigned,
                 "cpuAtStart": _CPUS, "cpuAtEnd": _CPUS})
        for key in ("cpuAtStart", "cpuAtEnd"):
            if key in line:
                _require(len(line[key]) == len(line["values"]), name + "." + key + " length differs from values")
    else:
        _fields(line, name, {
            "status": _enum("completed", "refused", "failed"), "checks": _array(_check),
            "blockLines": _unsigned, "warmupBatchLines": _unsigned,
            "measuredBatchLines": _unsigned, "conditions": _conditions,
            "thermalChanges": _array(_thermal_change),
        }, {"reasonCode": _string, "reason": _string})


def _json(raw: bytes) -> Any:
    def reject_constant(value: str) -> None:
        raise _Invalid("JSON contains nonfinite value " + value)
    return json.loads(raw.decode("utf-8"), parse_constant=reject_constant)



def _completed_request(request: Dict[str, Any]) -> None:
    """Completed work needs valid tunables; failed invalidRequest files do not."""
    _fields(request, "request", {
        "schema": _unsigned, "runID": _string, "attemptID": _string,
        "attempt": _unsigned, "experiment": _string, "variant": _string,
        "seed": _unsigned, "smoke": _boolean, "mechanisms": _array(_string),
        "operations": _array(_string), "tunables": _object,
    }, {"simulation": _enum("crash", "hang")})
    _fields(request["tunables"], "request.tunables", {
        "threads": _unsigned, "qos": _QOS, "warmupBatches": _unsigned,
        "measuredBatches": _unsigned, "subBatches": _unsigned,
        "operationsPerBatch": _object, "referenceLoopIterations": _unsigned,
    }, {"repeats": _unsigned})
    tunables = request["tunables"]
    _require(request["schema"] == 1 and request["attempt"] >= 1
             and request["seed"] < 2 ** 53, "request schema, attempt or seed is invalid")
    _require(1 <= tunables["threads"] <= 64 and tunables["measuredBatches"] >= 1
             and tunables["subBatches"] >= 1 and tunables["referenceLoopIterations"] >= 1,
             "request tunables are outside the allowed range")
    operations = tunables["operationsPerBatch"]
    _require("default" in operations, "request operationsPerBatch requires default")
    for key, count in operations.items():
        _unsigned(count, "request.operationsPerBatch." + key)
        _require(count >= tunables["subBatches"] and count % tunables["subBatches"] == 0,
                 "request operationsPerBatch must be a positive multiple of subBatches")
    if request["experiment"] == "calibration":
        _require("repeats" in tunables and tunables["repeats"] >= 1,
                 "request calibration repeats must be positive")


def _check_conditions(conditions: Dict[str, Any]) -> None:
    _require(
        conditions["thermalState"] == "nominal"
        and not conditions["debuggerAttached"]
        and not conditions["lowPowerMode"]
        and conditions["batteryState"] in ("charging", "full")
        and conditions["applicationState"] == "active"
        and not conditions["environment"],
        "conditions are unsuitable for a non-smoke run",
    )


def _check_work(lines: List[Dict[str, Any]], request: Dict[str, Any],
                expected: ExpectedAttempt) -> None:
    run, end = lines[0], lines[-1]
    tunables = request["tunables"]
    references = [line for line in lines if line["type"] == "reference"]
    _require(len(references) == 2 and len(lines) >= 4,
             "expected exactly two reference lines")
    _require(lines[1] is references[0] and lines[-2] is references[1]
             and references[0]["when"] == "start" and references[1]["when"] == "end",
             "reference lines must bracket the block groups in start/end order")
    start_ticks = run["conditions"]["ticks"]
    end_ticks = end["conditions"]["ticks"]
    for reference in references:
        _require(reference["iterations"] == tunables["referenceLoopIterations"],
                 "reference iterations differ from request")
        _require(len(reference["cpuReadings"]) == 2, "reference CPU readings require two values")
        _require(start_ticks <= reference["start"] <= reference["end"] <= end_ticks,
                 "reference timestamps are outside run conditions")
    blocks = []
    batches = []
    samples = []
    current_block = None
    in_samples = False
    previous_batch = None
    previous_end = references[0]["end"]
    for line in lines[2:-2]:
        kind = line["type"]
        if kind == "block":
            _require(line["block"] == len(blocks), "block positions must be contiguous and unique")
            _require(previous_end <= line["start"] < line["end"] <= references[1]["start"],
                     "block timestamps must be ordered inside references")
            previous_end = line["end"]
            blocks.append(line)
            current_block = line
            in_samples = False
            previous_batch = None
        elif kind in ("batch", "samples"):
            _require(current_block is not None and line.get("block") == current_block["block"],
                     "batch or samples line is outside its block group")
            if kind == "batch":
                _require(not in_samples, "batch lines must precede samples in a block")
                key = (line["thread"], line["batch"])
                _require(previous_batch is None or previous_batch < key,
                         "batch lines must be unique and ordered by thread and batch")
                previous_batch = key
                _require(current_block["start"] <= line["start"] <= line["end"] <= current_block["end"],
                         "batch timestamps are outside its block")
                batches.append(line)
            else:
                in_samples = True
                samples.append(line)
        else:
            raise _Invalid("unexpected line inside block groups: " + kind)
    _require(len(blocks) == len(expected.blocks)
             and {(block["mechanism"], block["operation"]) for block in blocks} == expected.blocks,
             "block mechanism/operation pairs differ from request")
    calibration = request["experiment"] == "calibration"
    for block in blocks:
        threads = 1 if calibration and block["mechanism"] == "clockSingleThread" else expected.threads
        qos = ("background" if block["mechanism"] == "cpuSpeedBackground" else "userInteractive") if calibration else tunables["qos"]
        _require(block["threads"] == threads and block["qos"] == qos,
                 "block threads or qos differ from request")
        _require(block["operationsPerBatch"] == expected.operations_per_batch[block["mechanism"]],
                 "block operationsPerBatch differs from request")
        block_batches = [line for line in batches if line["block"] == block["block"]]
        total_batches = expected.warmup_batches + expected.measured_batches
        # Uniqueness and order were checked while reading the block group.
        _require(len(block_batches) == threads * total_batches,
                 "missing or extra batch lines")
        for batch in block_batches:
            _require(batch["thread"] < threads and batch["batch"] < total_batches,
                     "batch thread or index differs from request")
            _require(batch["warmup"] == (batch["batch"] < expected.warmup_batches),
                     "batch warmup flag differs from request")
            _require(batch["operations"] == block["operationsPerBatch"],
                     "batch operations differ from block")
            for key in ("cpuReadings", "executorCPUReadings"):
                if key in batch:
                    _require(len(batch[key]) == tunables["subBatches"] + 1,
                             "batch " + key + " length differs from subBatches")
        if calibration:
            block_samples = [line for line in samples if line["block"] == block["block"]]
            _require(len(block_samples) == threads
                     and {line.get("thread") for line in block_samples} == set(range(threads)),
                     "calibration samples must cover each block thread exactly once")
            metric = "clockRead1000" if block["mechanism"].startswith("clock") else "referenceLoop"
            for sample in block_samples:
                _require(sample["metric"] == metric and sample["unit"] == "ticks"
                         and len(sample["values"]) == tunables["repeats"],
                         "calibration samples metric, unit or repeats differ from request")
    if expected.samples_lines is not None:
        _require(len(samples) == expected.samples_lines, "samples line count differs from request")
    warmup = sum(batch["warmup"] for batch in batches)
    _require(end["blockLines"] == len(blocks) and end["warmupBatchLines"] == warmup
             and end["measuredBatchLines"] == len(batches) - warmup,
             "end line counts differ from written work")
    expected_checks = {(name, None) for name in expected.run_checks}
    if expected.check_per_block is not None:
        for block in blocks:
            name = expected.check_per_block
            if request["experiment"] == "baseComparison":
                name += "." + block["operation"]
            expected_checks.add((name, block["block"]))
    checks = end["checks"]
    _require(len(checks) == len(expected_checks)
             and {(check["name"], check.get("block")) for check in checks} == expected_checks,
             "checks are missing, duplicated or assigned to the wrong block")
    _require(all(check["passed"] and check.get("violations", 0) == 0 for check in checks),
             "correctness check failed or has violations")


def check_attempt(result_file: Path, done_file: Optional[Path], request: Dict[str, Any],
                  build_id: str) -> AttemptVerdict:
    if done_file is None or not done_file.exists():
        return AttemptVerdict("incomplete", False, None, ["missing .done marker"])
    try:
        raw = result_file.read_bytes()
        marker = _json(done_file.read_bytes())
        _fields(marker, ".done", {"attemptID": _string, "file": _string,
                                  "bytes": _unsigned, "sha256": _string})
        _require(marker["attemptID"] == request.get("attemptID"), ".done attemptID differs from request")
        _require(marker["file"] == result_file.name, ".done file name differs from result")
        _require(marker["bytes"] == len(raw), ".done byte size differs from result")
        _require(marker["sha256"] == hashlib.sha256(raw).hexdigest(), ".done hash differs from result")
        _require(raw.endswith(b"\n"), "JSON Lines must end with a newline")
        lines = [_json(line) for line in raw.splitlines()]
        _require(bool(lines), "result is empty")
        for number, line in enumerate(lines, 1):
            _validate_line(line, number)
        _require(lines[0]["type"] == "run" and lines[-1]["type"] == "end",
                 "first line must be run and last line must be end")
        _require(sum(line["type"] == "run" for line in lines) == 1
                 and sum(line["type"] == "end" for line in lines) == 1,
                 "run and end lines must each appear once")
        run, end = lines[0], lines[-1]
        _require(json.dumps(run["request"], sort_keys=True) == json.dumps(request, sort_keys=True),
                 "run request differs from launch request")
        _require(run["build"]["buildID"] == build_id, "run build ID differs from expected build")
        if end["status"] in ("refused", "failed"):
            return AttemptVerdict(end["status"], False, end.get("reasonCode"),
                                  [end.get("reason", end["status"])])
        _completed_request(request)
        expected = expected_attempt(request, run["phone"]["cpuCount"])
        _check_work(lines, request, expected)
        if not request["smoke"]:
            _check_conditions(run["conditions"])
            _check_conditions(end["conditions"])
        return AttemptVerdict("completed", True, None, [])
    except (OSError, ValueError, UnicodeError, KeyError) as error:
        return AttemptVerdict("invalid", False, None, [str(error)])
