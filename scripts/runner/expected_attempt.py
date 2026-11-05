from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, FrozenSet, Tuple


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


# Calibration blocks: mechanism, thread count (None means every CPU), QoS, sample metric.
_CALIBRATION_BLOCKS = (
    ("clockSingleThread", 1, "userInteractive", "clockRead1000", False),
    ("clockAllCPUs", None, "userInteractive", "clockRead1000", False),
    ("cpuSpeedUserInteractive", None, "userInteractive", "referenceLoop", True),
    ("cpuSpeedBackground", None, "background", "referenceLoop", True),
)


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
    else:
        raise ValueError("request.experiment is not supported by the attempt checker")
    return ExpectedAttempt(
        blocks, warmup, measured, tunables["subBatches"], frozenset()
    )
