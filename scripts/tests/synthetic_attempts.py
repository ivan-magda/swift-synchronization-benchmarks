"""Small, deterministic result documents for exercising the file contract."""

from __future__ import annotations

import hashlib
import json
from copy import deepcopy
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from runner.expected_attempt import ASYNC_CODE_ROWS, MANY_TASKS

GOLDEN = (
    Path(__file__).resolve().parents[2] / "Tests/Fixtures/golden-base-comparison.jsonl"
)


MAIN_THREAD_CPU_OPERATIONS = ("fromMainActor", "toMainActor", "callFromMainActor")
CALLER_PATHS_MECHANISMS = ["actor", "mutex", "osAllocatedUnfairLock", "nsLock", "mainActor"]
CALLER_PATHS_OPERATIONS = [
    "onActor",
    "fromBackgroundTask",
    "fromManyTasks",
    "fromMainActor",
    "toMainActor",
]


def async_code_request(variant, mechanisms, operations, calls_per_task=3):
    """An experiment 7 request built on the golden one: two warm-up and two measured batches."""
    request = deepcopy(json.loads(GOLDEN.read_text().splitlines()[0])["request"])
    request.update(
        experiment="asyncCode",
        variant=variant,
        mechanisms=list(mechanisms),
        operations=list(operations),
    )
    tunables = request["tunables"]
    tunables.update(warmupBatches=2, measuredBatches=2)
    tunables["asyncCode"] = {
        "callsPerTask": calls_per_task,
        "warmupCallsPerTask": 1,
    }
    if variant == "batching":
        # Every sub-batch holds whole groups of 100 operations.
        tunables["operationsPerBatch"] = {"default": 200}
    return request


def hot_flag_request():
    """All 17 flags, plain and grouped reads, with 1,000 operations per batch."""
    request = deepcopy(json.loads(GOLDEN.read_text().splitlines()[0])["request"])
    request.update(
        experiment="hotFlag",
        variant="default",
        mechanisms=[
            "mutex", "osAllocatedUnfairLock", "osAllocatedUnfairLockAdaptiveSpin",
            "osUnfairLock", "nsLock", "nsRecursiveLock", "pthreadMutex",
            "pthreadReadWriteLock", "serialQueue", "barrierQueueSyncWrite",
            "barrierQueueAsyncWrite", "dispatchSemaphore", "objcSync", "atomic",
            "managedAtomic", "atomicRelaxed", "managedAtomicRelaxed",
        ],
        operations=["read", "readGroups"],
    )
    request["tunables"]["operationsPerBatch"] = {"default": 1000}
    return request


def priority_inversion_request():
    """Two reference mechanisms and both holder priorities, with one warm-up trial."""
    request = deepcopy(json.loads(GOLDEN.read_text().splitlines()[0])["request"])
    request.update(
        experiment="priorityInversion",
        variant="default",
        mechanisms=["osUnfairLock", "dispatchSemaphore"],
        operations=["utilityHolder", "backgroundHolder"],
    )
    request["tunables"]["threads"] = 1
    request["tunables"]["priorityInversion"] = {
        "holderWorkIterations": 1000,
        "loadQoS": "userInteractive",
        "loadMilliseconds": 5,
        "mainDelayMicroseconds": 1000,
        "pauseMilliseconds": 0,
        "warmupTrials": 1,
        "trials": 2,
    }
    return request


def trial_line(block, number, warmup=False, **replacement):
    """A valid trial inside the block: the holder holds the lock, the load runs."""
    start = block["start"]
    line = {
        "type": "trial",
        "block": block["block"],
        "trial": number,
        "warmup": warmup,
        "holderQoS": block["qos"],
        "loadStart": start + 1,
        "holderAcquire": start + 2,
        "mainArrival": start + 3,
        "holderRelease": start + 4,
        "mainAcquire": start + 5,
        "loadStop": start + 6,
        "holderCPUReadings": [1, 1],
        "mainCPU": 0,
        "holderResultCorrect": True,
        "mainObservedTrial": number,
        "outcome": "valid",
    }
    line.update(replacement)
    return line


def make_attempt_lines(
    request: Dict[str, Any],
    build_id: str,
    status: str = "completed",
    reason_code: Optional[str] = None,
    cpu_count: int = 6,
) -> List[Dict[str, Any]]:
    """Expand the reviewed golden envelopes with deterministic fictional timings."""
    golden = [json.loads(line) for line in GOLDEN.read_text().splitlines()]
    run = deepcopy(golden[0])
    run["request"] = deepcopy(request)
    run["build"]["buildID"] = build_id
    run["phone"]["cpuCount"] = cpu_count
    end = deepcopy(golden[-1])
    end.update(
        status=status, checks=[], blockLines=0, warmupBatchLines=0, measuredBatchLines=0
    )
    if reason_code is not None:
        end["reasonCode"] = reason_code
    if status != "completed":
        return [run, end]

    tunables = request["tunables"]
    start_reference = deepcopy(golden[1])
    start_reference["iterations"] = tunables["referenceLoopIterations"]
    lines = [run, start_reference]
    calibration = request["experiment"] == "calibration"
    async_code = request["experiment"] == "asyncCode"
    hot_flag = request["experiment"] == "hotFlag"
    priority_inversion = request["experiment"] == "priorityInversion"

    # These are the six measurements specified by Calibration, independently of the checker.
    if calibration:
        measurements = [
            ("clockSingleThread", "", 1, "userInteractive", "clockRead1000"),
            ("clockAllCPUs", "", cpu_count, "userInteractive", "clockRead1000"),
            (
                "cpuSpeedUserInteractive",
                "",
                cpu_count,
                "userInteractive",
                "referenceLoop",
            ),
            ("cpuSpeedBackground", "", cpu_count, "background", "referenceLoop"),
            ("holderWorkSingleThread", "", 1, "userInteractive", "holderWork"),
            ("displayFrames", "", 1, "userInteractive", "displayFrame"),
        ]
    elif async_code:
        # The requested pairs that the table allows, mechanisms first, as the app orders them.
        rows = ASYNC_CODE_ROWS[request["variant"]]
        measurements = [
            (
                mechanism,
                operation,
                MANY_TASKS if operation == "fromManyTasks" else 1,
                tunables["qos"],
                None,
            )
            for mechanism in request["mechanisms"]
            for operation in request["operations"]
            if mechanism in rows.get(operation, ())
        ]
    elif priority_inversion:
        measurements = [
            (
                mechanism,
                operation,
                1,
                {"utilityHolder": "utility", "backgroundHolder": "background"}[operation],
                None,
            )
            for mechanism in request["mechanisms"]
            for operation in request["operations"]
        ]
    else:
        measurements = [
            (mechanism, operation, tunables["threads"], tunables["qos"], None)
            for mechanism in request["mechanisms"]
            for operation in request["operations"]
        ]
    tick = 130
    for position, (mechanism, operation, threads, qos, metric) in enumerate(
        measurements
    ):
        operations = tunables["operationsPerBatch"].get(
            mechanism, tunables["operationsPerBatch"]["default"]
        )
        block = deepcopy(golden[2])
        block.update(
            block=position,
            mechanism=mechanism,
            operation=operation,
            threads=threads,
            qos=qos,
            operationsPerBatch=operations,
            start=tick,
        )
        lines.append(block)
        tick += 10
        for thread in range(threads):
            if priority_inversion:
                trials = tunables["priorityInversion"]
                for number in range(trials["warmupTrials"] + trials["trials"]):
                    trial = trial_line(
                        block, number, warmup=number < trials["warmupTrials"]
                    )
                    # Give every trial a distinct, ordered interval inside the block.
                    for field in (
                        "loadStart", "loadStop", "holderAcquire", "holderRelease",
                        "mainArrival", "mainAcquire",
                    ):
                        trial[field] += number * 10
                    lines.append(trial)
                    tick += 10
            elif calibration:
                count = tunables["repeats"]
                sample = dict(
                    type="samples",
                    block=position,
                    thread=thread,
                    metric=metric,
                    unit="ticks",
                    values=[3] * count,
                )
                if metric == "displayFrame":
                    sample["values"] = [
                        10_000_000 + frame * 200_000 for frame in range(count)
                    ]
                if metric in ("referenceLoop", "holderWork"):
                    sample.update(
                        cpuAtStart=[thread] * count, cpuAtEnd=[thread] * count
                    )
                lines.append(sample)
            elif async_code and operation == "fromManyTasks":
                # No batch lines: one callTime line per task.
                lines.append(
                    dict(
                        type="samples",
                        block=position,
                        thread=thread,
                        metric="callTime",
                        unit="ticks",
                        values=[3] * request["tunables"]["asyncCode"]["callsPerTask"],
                    )
                )
            else:
                # Only actor and main-actor rows read the executor's CPU, except onActor.
                reads_executor = (
                    async_code and mechanism in ("actor", "mainActor") and operation != "onActor"
                )
                for batch in range(
                    tunables["warmupBatches"] + tunables["measuredBatches"]
                ):
                    warmup = batch < tunables["warmupBatches"]
                    lines.append(
                        dict(
                            type="batch",
                            block=position,
                            thread=thread,
                            batch=batch,
                            warmup=warmup,
                            operations=operations,
                            start=tick,
                            end=tick + 5,
                            cpuReadings=[thread] * (tunables["subBatches"] + 1),
                        )
                    )
                    if reads_executor:
                        lines[-1]["executorCPUReadings"] = [thread] * (
                            tunables["subBatches"] + 1
                        )
                    tick += 10
                    end["warmupBatchLines" if warmup else "measuredBatchLines"] += 1
        if async_code and operation in MAIN_THREAD_CPU_OPERATIONS:
            for metric in ("mainThreadCPUAtBatchStart", "mainThreadCPUAtBatchEnd"):
                lines.append(
                    dict(
                        type="samples",
                        block=position,
                        metric=metric,
                        unit="microseconds",
                        values=[500] * (tunables["warmupBatches"] + tunables["measuredBatches"]),
                    )
                )
        if hot_flag and operation == "readGroups":
            lines.append(dict(
                type="samples", block=position, thread=0,
                metric="readGroupTime", unit="ticks",
                values=[3] * (tunables["measuredBatches"] * (operations // 100)),
            ))
        block["end"] = tick
        tick += 10
        if calibration:
            check_name = "calibration.samples"
        elif priority_inversion:
            check_name = "priorityInversion." + operation
        elif hot_flag:
            check_name = "hotFlag." + operation
        elif async_code:
            check_name = "asyncCode." + operation
        else:
            check_name = "baseComparison." + operation
        end["checks"].append(
            dict(
                name=check_name,
                block=position,
                passed=True,
                detail="Synthetic completed work",
            )
        )
    end["blockLines"] = len(measurements)
    reference = deepcopy(golden[-2])
    reference.update(
        iterations=tunables["referenceLoopIterations"], start=tick, end=tick + 10
    )
    end["conditions"]["ticks"] = tick + 20
    return lines + [reference, end]


def write_attempt(directory: Path, lines: List[Dict[str, Any]]) -> Tuple[Path, Path]:
    """Write exact JSONL bytes and their publication marker, including mutated files."""
    attempt_id = lines[0]["request"]["attemptID"]
    result = directory / (attempt_id + ".jsonl")
    marker = result.with_suffix(".done")
    raw = (
        "\n".join(
            json.dumps(line, sort_keys=True, separators=(",", ":")) for line in lines
        )
        + "\n"
    ).encode("utf-8")
    result.write_bytes(raw)
    marker.write_text(
        json.dumps(
            dict(
                attemptID=attempt_id,
                file=result.name,
                bytes=len(raw),
                sha256=hashlib.sha256(raw).hexdigest(),
            ),
            sort_keys=True,
        ),
        encoding="utf-8",
    )
    return result, marker
