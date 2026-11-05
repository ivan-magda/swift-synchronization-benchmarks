from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, FrozenSet, Optional, Tuple


@dataclass(frozen=True)
class ExpectedAttempt:
    """Required work, independently derived from the launch request.

    check_per_block is the experiment prefix: baseComparison adds the operation;
    calibration uses the fixed name calibration.samples for every block.
    """

    blocks: FrozenSet[Tuple[str, str]]
    threads: int
    warmup_batches: int
    measured_batches: int
    samples_lines: Optional[int]
    operations_per_batch: Dict[str, int]
    check_per_block: Optional[str]
    run_checks: FrozenSet[str]


def expected_attempt(request: Dict[str, Any], cpu_count: int) -> ExpectedAttempt:
    tunables = request["tunables"]
    if request["experiment"] == "baseComparison":
        blocks = frozenset((mechanism, operation)
                           for mechanism in request["mechanisms"]
                           for operation in request["operations"])
        threads = tunables["threads"]
        warmup = tunables["warmupBatches"]
        measured = tunables["measuredBatches"]
        samples = None
        check = "baseComparison"
    elif request["experiment"] == "calibration":
        blocks = frozenset((mechanism, "") for mechanism in (
            "clockSingleThread", "clockAllCPUs", "cpuSpeedUserInteractive", "cpuSpeedBackground"))
        threads = cpu_count
        warmup = 0
        measured = 0
        samples = 1 + 3 * cpu_count
        check = "calibration.samples"
    else:
        raise ValueError("request.experiment is not supported by the attempt checker")
    operations = tunables["operationsPerBatch"]
    return ExpectedAttempt(
        blocks, threads, warmup, measured, samples,
        {mechanism: operations.get(mechanism, operations["default"])
         for mechanism, _ in blocks}, check, frozenset(),
    )
