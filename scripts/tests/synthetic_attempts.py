"""Small, deterministic result documents for exercising the file contract."""

from __future__ import annotations

import hashlib
import json
from copy import deepcopy
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

GOLDEN = (
    Path(__file__).resolve().parents[2] / "Tests/Fixtures/golden-base-comparison.jsonl"
)


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

    # These are the five measurements specified by Calibration, independently of the checker.
    measurements = (
        [
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
        ]
        if calibration
        else [
            (mechanism, operation, tunables["threads"], tunables["qos"], None)
            for mechanism in request["mechanisms"]
            for operation in request["operations"]
        ]
    )
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
            if calibration:
                count = tunables["repeats"]
                sample = dict(
                    type="samples",
                    block=position,
                    thread=thread,
                    metric=metric,
                    unit="ticks",
                    values=[3] * count,
                )
                if metric in ("referenceLoop", "holderWork"):
                    sample.update(
                        cpuAtStart=[thread] * count, cpuAtEnd=[thread] * count
                    )
                lines.append(sample)
            else:
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
                    tick += 10
                    end["warmupBatchLines" if warmup else "measuredBatchLines"] += 1
        block["end"] = tick
        tick += 10
        end["checks"].append(
            dict(
                name="calibration.samples"
                if calibration
                else "baseComparison." + operation,
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
