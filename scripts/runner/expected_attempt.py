from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, FrozenSet, List, Tuple


@dataclass(frozen=True)
class ExpectedSamples:
    """One group of samples lines that a block must write."""

    metric: str
    unit: str
    per_thread: bool  # one line per thread (with "thread"), or one line for the block (no "thread")
    lines: int
    values_per_line: int
    cpu_readings: bool  # cpuAtStart and cpuAtEnd present


@dataclass(frozen=True)
class ExpectedBlock:
    """Required work of one block, independently derived from the launch request."""

    mechanism: str
    operation: str
    threads: int
    qos: str
    operations_per_batch: int
    batch_lines: int  # 0 when the block writes no batch lines
    samples: Tuple[ExpectedSamples, ...]
    trial_lines: int  # 0 for every experiment except priorityInversion
    check: str  # the one check this block must carry


@dataclass(frozen=True)
class ExpectedAttempt:
    """Required work of the whole attempt, keyed by (mechanism, operation)."""

    blocks: Dict[Tuple[str, str], ExpectedBlock]
    warmup_batches: int
    measured_batches: int
    sub_batches: int
    run_checks: FrozenSet[str]


# Calibration blocks: mechanism, thread count (None means every CPU), QoS,
# sample metric, and whether samples carry cpuAtStart and cpuAtEnd.
_CALIBRATION_BLOCKS = (
    ("clockSingleThread", 1, "userInteractive", "clockRead1000", False),
    ("clockAllCPUs", None, "userInteractive", "clockRead1000", False),
    ("cpuSpeedUserInteractive", None, "userInteractive", "referenceLoop", True),
    ("cpuSpeedBackground", None, "background", "referenceLoop", True),
    # A separate metric keeps the holder work out of the referenceLoop core map.
    ("holderWorkSingleThread", 1, "userInteractive", "holderWork", True),
    ("displayFrames", 1, "userInteractive", "displayFrame", False),
)

# Experiment 7: variant -> operation -> mechanisms measured with it.
# Must equal AsyncCode.rows; AsyncCodeRequest validates this matrix separately
# in Experiments/AsyncCode/AsyncCodeRequest.swift.
ASYNC_CODE_ROWS: Dict[str, Dict[str, List[str]]] = {
    "callerPaths": {
        "onActor": ["actor"],
        "fromBackgroundTask": ["actor", "mutex", "osAllocatedUnfairLock", "nsLock"],
        "fromManyTasks": ["actor", "mutex", "osAllocatedUnfairLock", "nsLock"],
        "fromMainActor": ["actor", "mutex", "osAllocatedUnfairLock", "nsLock"],
        "toMainActor": ["mainActor"],
    },
    "batching": {
        "oneAwaitPerGroup": ["actor"],
        "awaitPerOperation": ["actor"],
        "oneLockPerGroup": ["mutex"],
    },
    "isolationSettings": {
        "callFromMainActor": [
            "templateDefaults",
            "swift6Language",
            "concurrentAttribute",
        ],
    },
}

# Tasks in path "fromManyTasks" (`AsyncCode.manyTasks`).
MANY_TASKS = 50

# Operations per await or per lock in experiment 7B (`AsyncCode.groupSize`).
GROUP_SIZE = 100

# Operations whose blocks also write the main thread's CPU time at each batch edge.
_MAIN_THREAD_CPU_OPERATIONS = ("fromMainActor", "toMainActor", "callFromMainActor")

# Experiment 8B: ContendedLocks.mechanisms is defined in
# Experiments/PriorityInversion/PriorityInversion.swift, beside the trial steps.
PRIORITY_INVERSION_MECHANISMS = frozenset({
    "mutex",
    "osAllocatedUnfairLock",
    "osAllocatedUnfairLockAdaptiveSpin",
    "osUnfairLock",
    "nsLock",
    "nsRecursiveLock",
    "pthreadMutex",
    "pthreadReadWriteLock",
    "serialQueue",
    "barrierQueueSyncWrite",
    "barrierQueueAsyncWrite",
    "dispatchSemaphore",
    "actor",
    "objcSync",
})

HOT_FLAG_MECHANISMS = frozenset({
    "mutex", "osAllocatedUnfairLock", "osAllocatedUnfairLockAdaptiveSpin",
    "osUnfairLock", "nsLock", "nsRecursiveLock", "pthreadMutex",
    "pthreadReadWriteLock", "serialQueue", "barrierQueueSyncWrite",
    "barrierQueueAsyncWrite", "dispatchSemaphore", "objcSync", "atomic",
    "managedAtomic", "atomicRelaxed", "managedAtomicRelaxed",
})


REQUEST_REGISTRY_MECHANISMS = frozenset({
    "mutex", "osAllocatedUnfairLock", "osAllocatedUnfairLockAdaptiveSpin",
    "osUnfairLock", "nsLock", "nsRecursiveLock", "pthreadMutex",
    "serialQueue", "dispatchSemaphore", "objcSync",
})


def _request_registry_blocks(request: Dict[str, Any]) -> Dict[Tuple[str, str], ExpectedBlock]:
    tunables = request["tunables"]
    registry = tunables.get("requestRegistry")
    if registry is None:
        raise ValueError("request.tunables.requestRegistry is required")
    if request["variant"] not in ("normal", "burst"):
        raise ValueError("request.variant must be normal or burst for requestRegistry")
    pause = registry["pauseMicroseconds"]
    if (request["variant"] == "normal" and pause < 1
            or request["variant"] == "burst" and pause != 0):
        raise ValueError("requestRegistry.pauseMicroseconds must match variant")
    if tunables["threads"] not in (4, 8):
        raise ValueError("request.tunables.threads must be 4 or 8 for requestRegistry")
    for field, allowed in (("mechanisms", REQUEST_REGISTRY_MECHANISMS),
                           ("operations", {"addAndRemove"})):
        values = request[field]
        if not values or len(set(values)) != len(values) or not set(values) <= allowed:
            raise ValueError("request." + field + " must be nonempty, unique requestRegistry entries")
    blocks = {}
    for mechanism in request["mechanisms"]:
        counts = tunables["operationsPerBatch"]
        count = counts.get(mechanism, counts["default"])
        sub_count = count // tunables["subBatches"]
        if sub_count % 2:
            raise ValueError("request.tunables.operationsPerBatch must be even per sub-batch")
        for field in ("sampleEvery", "cancelAllEvery"):
            if registry[field] < 1 or sub_count % registry[field]:
                raise ValueError("requestRegistry." + field + " must divide operations per sub-batch")
        if registry["sampleEvery"] % 2:
            raise ValueError("requestRegistry.sampleEvery must be even")
        measured = tunables["measuredBatches"] * count
        threads = tunables["threads"]
        samples = tuple(
            ExpectedSamples(metric, "ticks", per_thread, threads if per_thread else 1,
                            measured // registry[field], False)
            for metric, per_thread, field in (
                ("callStart", True, "sampleEvery"), ("callTime", True, "sampleEvery"),
                ("cancelAllStart", False, "cancelAllEvery"), ("cancelAllTime", False, "cancelAllEvery"),
            )
        )
        blocks[(mechanism, "addAndRemove")] = ExpectedBlock(
            mechanism, "addAndRemove", threads, tunables["qos"], count,
            threads * (tunables["warmupBatches"] + tunables["measuredBatches"]),
            samples, 0, "requestRegistry.addAndRemove",
        )
    return blocks


def _hot_flag_blocks(request: Dict[str, Any]) -> Dict[Tuple[str, str], ExpectedBlock]:
    """One reader with batches and, for readGroups, measured 100-read durations."""
    tunables = request["tunables"]
    if request["variant"] != "default":
        raise ValueError("request.variant must be default for hotFlag")
    if tunables["threads"] != 1:
        raise ValueError("request.tunables.threads must be 1 for hotFlag")
    for field, allowed in (
        ("mechanisms", HOT_FLAG_MECHANISMS),
        ("operations", {"read", "readGroups"}),
    ):
        values = request[field]
        if not values or len(set(values)) != len(values) or not set(values) <= allowed:
            raise ValueError("request." + field + " must be nonempty, unique hotFlag entries")
    blocks = {}
    for mechanism in request["mechanisms"]:
        counts = tunables["operationsPerBatch"]
        count = counts.get(mechanism, counts["default"])
        if "readGroups" in request["operations"] and (
            count % tunables["subBatches"] != 0
            or (count // tunables["subBatches"]) % 100 != 0
        ):
            raise ValueError("request.tunables.operationsPerBatch must hold whole 100-read groups")
        for operation in request["operations"]:
            samples = ()
            if operation == "readGroups":
                samples = (ExpectedSamples(
                    "readGroupTime", "ticks", True, 1,
                    tunables["measuredBatches"] * (count // 100), False,
                ),)
            blocks[(mechanism, operation)] = ExpectedBlock(
                mechanism, operation, 1, tunables["qos"], count,
                tunables["warmupBatches"] + tunables["measuredBatches"],
                samples, 0, "hotFlag." + operation,
            )
    return blocks


TRANSACTIONAL_STORE_MECHANISMS = HOT_FLAG_MECHANISMS - {
    "atomic", "atomicRelaxed", "managedAtomic", "managedAtomicRelaxed",
}


def _transactional_store_blocks(request: Dict[str, Any]) -> Dict[Tuple[str, str], ExpectedBlock]:
    tunables = request["tunables"]
    if request["variant"] != "default":
        raise ValueError("request.variant must be default for transactionalStore")
    if tunables["threads"] != 6:
        raise ValueError("request.tunables.threads must be 6 for transactionalStore")
    for field, allowed in (("mechanisms", TRANSACTIONAL_STORE_MECHANISMS),
                           ("operations", {"singleRecord", "twentyRecords"})):
        values = request[field]
        if not values or len(set(values)) != len(values) or not set(values) <= allowed:
            raise ValueError("request." + field + " must be nonempty, unique transactionalStore entries")
    blocks = {}
    for mechanism in request["mechanisms"]:
        counts = tunables["operationsPerBatch"]
        count = counts.get(mechanism, counts["default"])
        if count % 5000:
            raise ValueError("request.tunables.operationsPerBatch must be a multiple of 5000")
        writes = count // 50
        for operation in request["operations"]:
            metric = "hundredReadsTime" if operation == "singleRecord" else "readTime"
            reads = (count - writes) // (100 if operation == "singleRecord" else 1)
            samples = (
                ExpectedSamples(metric, "ticks", True, 6, tunables["measuredBatches"] * reads, False),
                ExpectedSamples("writeTime", "ticks", True, 6, tunables["measuredBatches"] * writes, False),
            )
            blocks[(mechanism, operation)] = ExpectedBlock(
                mechanism, operation, 6, tunables["qos"], count,
                6 * (tunables["warmupBatches"] + tunables["measuredBatches"]),
                samples, 0, "transactionalStore." + operation,
            )
    return blocks


CREATION_COST_MECHANISMS = frozenset({
    "unsynchronized", "mutex", "osAllocatedUnfairLock", "osUnfairLock", "nsLock",
    "nsRecursiveLock", "pthreadMutex", "pthreadReadWriteLock", "serialQueue",
    "barrierQueueSyncWrite", "dispatchSemaphore", "actor", "mainActor", "atomic", "managedAtomic",
})


def _creation_cost_blocks(request: Dict[str, Any]) -> Dict[Tuple[str, str], ExpectedBlock]:
    tunables = request["tunables"]
    if request["variant"] != "default":
        raise ValueError("request.variant must be default for creationCost")
    if tunables["threads"] != 1:
        raise ValueError("request.tunables.threads must be 1 for creationCost")
    for field, allowed in (("mechanisms", CREATION_COST_MECHANISMS), ("operations", {"create", "destroy"})):
        values = request[field]
        if not values or len(set(values)) != len(values) or not set(values) <= allowed:
            raise ValueError("request." + field + " must be nonempty, unique creationCost entries")
    blocks = {}
    for mechanism in request["mechanisms"]:
        counts = tunables["operationsPerBatch"]
        count = counts.get(mechanism, counts["default"])
        for operation in request["operations"]:
            samples = ()
            if operation == "create":
                samples = tuple(
                    ExpectedSamples("malloc" + kind + edge, unit, False, 1,
                                    tunables["warmupBatches"] + tunables["measuredBatches"], False)
                    for kind, unit in (("Blocks", "blocks"), ("Bytes", "bytes"))
                    for edge in ("BeforeCreate", "AfterCreate", "AfterDestroy")
                )
            blocks[(mechanism, operation)] = ExpectedBlock(
                mechanism, operation, 1, tunables["qos"], count,
                tunables["warmupBatches"] + tunables["measuredBatches"],
                samples, 0, "creationCost." + operation,
            )
    return blocks


HOLDER_QOS = {"utilityHolder": "utility", "backgroundHolder": "background"}


def _priority_inversion_blocks(
    request: Dict[str, Any]
) -> Dict[Tuple[str, str], ExpectedBlock]:
    """The complete mechanism × holder matrix, with no batch or sample lines."""
    tunables = request["tunables"]
    if request["variant"] != "default":
        raise ValueError("request.variant must be default for priorityInversion")
    if tunables["threads"] != 1:
        raise ValueError("request.tunables.threads must be 1 for priorityInversion")
    trials = tunables.get("priorityInversion")
    if trials is None:
        raise ValueError("request.tunables.priorityInversion is required")
    for field, allowed in (
        ("mechanisms", PRIORITY_INVERSION_MECHANISMS),
        ("operations", HOLDER_QOS),
    ):
        values = request[field]
        unique_values = set(values)
        if (
            not values
            or len(unique_values) != len(values)
            or not unique_values <= set(allowed)
        ):
            raise ValueError(
                "request." + field + " must be nonempty, unique priorityInversion entries"
            )
    operations = tunables["operationsPerBatch"]
    return {
        (mechanism, operation): ExpectedBlock(
            mechanism,
            operation,
            1,
            HOLDER_QOS[operation],
            operations.get(mechanism, operations["default"]),
            0,
            (),
            trials["warmupTrials"] + trials["trials"],
            "priorityInversion." + operation,
        )
        for mechanism in request["mechanisms"]
        for operation in request["operations"]
    }


def _async_code_blocks(
    request: Dict[str, Any]
) -> Tuple[Dict[Tuple[str, str], ExpectedBlock], int, int]:
    """The blocks of an experiment 7 request, with its warm-up and measured batch counts."""
    tunables = request["tunables"]
    operations = tunables["operationsPerBatch"]
    warmup = tunables["warmupBatches"]
    measured = tunables["measuredBatches"]
    rows = ASYNC_CODE_ROWS.get(request["variant"])
    if rows is None:
        raise ValueError("request.variant is not supported by asyncCode")
    if request["variant"] == "batching":
        for count in operations.values():
            if (count // tunables["subBatches"]) % GROUP_SIZE != 0:
                raise ValueError(
                    "operationsPerBatch must be a multiple of subBatches x "
                    + str(GROUP_SIZE)
                )

    blocks: Dict[Tuple[str, str], ExpectedBlock] = {}
    for mechanism in request["mechanisms"]:
        for operation in request["operations"]:
            if mechanism not in rows.get(operation, ()):
                continue
            many_tasks = operation == "fromManyTasks"
            threads = MANY_TASKS if many_tasks else 1
            if many_tasks:
                samples = (
                    ExpectedSamples(
                        "callTime",
                        "ticks",
                        True,
                        MANY_TASKS,
                        _many_tasks_tunables(request)["callsPerTask"],
                        False,
                    ),
                )
            elif operation in _MAIN_THREAD_CPU_OPERATIONS:
                samples = tuple(
                    ExpectedSamples(
                        metric, "microseconds", False, 1, warmup + measured, False
                    )
                    for metric in (
                        "mainThreadCPUAtBatchStart",
                        "mainThreadCPUAtBatchEnd",
                    )
                )
            else:
                samples = ()
            blocks[(mechanism, operation)] = ExpectedBlock(
                mechanism,
                operation,
                threads,
                tunables["qos"],
                operations.get(mechanism, operations["default"]),
                0 if many_tasks else threads * (warmup + measured),
                samples,
                0,
                "asyncCode." + operation,
            )

    for mechanism in request["mechanisms"]:
        if not any(key[0] == mechanism for key in blocks):
            raise ValueError("request.mechanisms has an entry without a requested operation")
    for operation in request["operations"]:
        if not any(key[1] == operation for key in blocks):
            raise ValueError("request.operations has an entry without a requested mechanism")
    return blocks, warmup, measured


def _many_tasks_tunables(request: Dict[str, Any]) -> Dict[str, Any]:
    tunables = request["tunables"].get("asyncCode")
    if tunables is None:
        raise ValueError("request.tunables.asyncCode is required for fromManyTasks")
    return tunables


def expected_attempt(request: Dict[str, Any], cpu_count: int) -> ExpectedAttempt:
    tunables = request["tunables"]
    operations = tunables["operationsPerBatch"]
    blocks: Dict[Tuple[str, str], ExpectedBlock] = {}
    if request["experiment"] == "baseComparison":
        warmup = tunables["warmupBatches"]
        measured = tunables["measuredBatches"]
        for mechanism in request["mechanisms"]:
            for operation in request["operations"]:
                blocks[(mechanism, operation)] = ExpectedBlock(
                    mechanism,
                    operation,
                    tunables["threads"],
                    tunables["qos"],
                    operations.get(mechanism, operations["default"]),
                    tunables["threads"] * (warmup + measured),
                    (),
                    0,
                    "baseComparison." + operation,
                )
    elif request["experiment"] == "calibration":
        warmup = 0
        measured = 0
        for mechanism, threads, qos, metric, cpu_readings in _CALIBRATION_BLOCKS:
            threads = cpu_count if threads is None else threads
            blocks[(mechanism, "")] = ExpectedBlock(
                mechanism,
                "",
                threads,
                qos,
                operations.get(mechanism, operations["default"]),
                0,
                (
                    ExpectedSamples(
                        metric,
                        "ticks",
                        True,
                        threads,
                        tunables["repeats"],
                        cpu_readings,
                    ),
                ),
                0,
                "calibration.samples",
            )
    elif request["experiment"] == "requestRegistry":
        blocks = _request_registry_blocks(request)
        warmup = tunables["warmupBatches"]
        measured = tunables["measuredBatches"]
    elif request["experiment"] == "hotFlag":
        blocks = _hot_flag_blocks(request)
        warmup = tunables["warmupBatches"]
        measured = tunables["measuredBatches"]
    elif request["experiment"] == "transactionalStore":
        blocks = _transactional_store_blocks(request)
        warmup = tunables["warmupBatches"]
        measured = tunables["measuredBatches"]
    elif request["experiment"] == "creationCost":
        blocks = _creation_cost_blocks(request)
        warmup = tunables["warmupBatches"]
        measured = tunables["measuredBatches"]
    elif request["experiment"] == "asyncCode":
        blocks, warmup, measured = _async_code_blocks(request)
    elif request["experiment"] == "priorityInversion":
        blocks = _priority_inversion_blocks(request)
        warmup = 0
        measured = 0
    else:
        raise ValueError("request.experiment is not supported by the attempt checker")
    return ExpectedAttempt(
        blocks, warmup, measured, tunables["subBatches"], frozenset()
    )
