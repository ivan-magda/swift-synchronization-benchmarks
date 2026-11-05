"""Infer core groups only from complete, stable calibration observations."""

from __future__ import annotations

import json
from pathlib import Path
from statistics import median
from typing import Any, Dict

from runner.attempt_check import check_attempt


class CalibrationError(ValueError):
    """Calibration is invalid or lacks evidence for every expected CPU."""


def derive_core_map(calibration_file: Path) -> Dict[str, Any]:
    """Combine stable referenceLoop samples from both CPU-speed QoS blocks."""
    try:
        lines = [
            json.loads(line)
            for line in calibration_file.read_text(encoding="utf-8").splitlines()
        ]
        run = lines[0]
        request = run["request"]
        if request["experiment"] != "calibration":
            raise ValueError()
        verdict = check_attempt(
            calibration_file,
            calibration_file.with_suffix(".done"),
            request,
            run["build"]["buildID"],
        )
        if not verdict.accepted:
            raise ValueError()

        phone = run["phone"]
        cpu_count = phone["cpuCount"]
        if type(cpu_count) is not int or not 1 <= cpu_count <= 64:
            raise ValueError()
        levels = phone["performanceLevels"]
        if not levels or len({level["index"] for level in levels}) != len(levels):
            raise ValueError()
        counts = [level["logicalCPUCount"] for level in levels]
        if (
            any(type(count) is not int or count <= 0 for count in counts)
            or sum(counts) != cpu_count
        ):
            raise ValueError()
        performance_count = next(
            level["logicalCPUCount"] for level in levels if level["index"] == 0
        )

        samples = {cpu: [] for cpu in range(cpu_count)}
        for line in lines:
            if line["type"] != "samples" or line["metric"] != "referenceLoop":
                continue
            for ticks, start, end in zip(
                line["values"], line["cpuAtStart"], line["cpuAtEnd"]
            ):
                if start != end:
                    continue
                if type(start) is not int or start not in samples or ticks <= 0:
                    raise ValueError()
                samples[start].append(ticks)
        if any(not values for values in samples.values()):
            raise ValueError()

        medians = {cpu: median(values) for cpu, values in samples.items()}
        fastest = sorted(medians, key=lambda cpu: (medians[cpu], cpu))[
            :performance_count
        ]
        return {
            "performance": sorted(fastest),
            "efficiency": sorted(set(samples) - set(fastest)),
            "medianTicksByCPU": {str(cpu): medians[cpu] for cpu in sorted(medians)},
        }
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        IndexError,
        StopIteration,
        UnicodeError,
    ):
        raise CalibrationError(
            "calibration requires valid counts and stable samples for every CPU"
        ) from None
