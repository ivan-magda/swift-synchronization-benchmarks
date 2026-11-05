"""Infer core groups and the holder work size only from accepted calibration."""

from __future__ import annotations

from copy import deepcopy
import json
from pathlib import Path
from statistics import median
from typing import Any, Dict, List, Optional, Tuple

from runner.attempt_check import check_attempt

TARGET_MILLISECONDS = 5

_READ_ERRORS = (
    OSError,
    ValueError,
    KeyError,
    TypeError,
    IndexError,
    StopIteration,
    UnicodeError,
)


class CalibrationError(ValueError):
    """Calibration is invalid or lacks evidence for every expected CPU."""


def read_accepted_calibration(calibration_file: Path) -> List[Dict[str, Any]]:
    """Return the lines of a calibration attempt that the attempt checker accepts."""
    try:
        lines = [
            json.loads(line)
            for line in calibration_file.read_text(encoding="utf-8").splitlines()
        ]
        run = run_line(lines)
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
        return lines
    except _READ_ERRORS:
        raise CalibrationError(
            "calibration file must be an accepted calibration attempt"
        ) from None


def run_line(lines: List[Dict[str, Any]]) -> Dict[str, Any]:
    return lines[0]


def holder_work_samples(lines: List[Dict[str, Any]]) -> List[Tuple[int, int, int]]:
    """Every holderWork sample as (ticks, cpuAtStart, cpuAtEnd)."""
    return [
        sample
        for line in lines
        if line["type"] == "samples" and line["metric"] == "holderWork"
        for sample in zip(line["values"], line["cpuAtStart"], line["cpuAtEnd"])
    ]


def derive_core_map(calibration_file: Path) -> Dict[str, Any]:
    """Combine stable referenceLoop samples from both CPU-speed QoS blocks."""
    lines = read_accepted_calibration(calibration_file)
    try:
        phone = run_line(lines)["phone"]
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
    except _READ_ERRORS:
        raise CalibrationError(
            "calibration requires valid counts and stable samples for every CPU"
        ) from None


def derive_holder_work(
    calibration_file: Path, core_map: Dict[str, Any]
) -> Dict[str, Any]:
    """Size the priority-inversion holder work for about 5 ms on a performance CPU."""
    lines = read_accepted_calibration(calibration_file)
    run = run_line(lines)
    phone = run["phone"]
    samples = holder_work_samples(lines)
    performance = set(core_map["performance"])
    usable = [
        ticks for ticks, start, end in samples if start == end and start in performance
    ]
    if not usable or len(usable) * 2 < len(samples):
        raise CalibrationError(
            "fewer than half of the holderWork samples ran on one performance CPU"
        )
    median_ticks = int(median(usable))
    if median_ticks <= 0 or min(
        phone["timebaseNumerator"], phone["timebaseDenominator"]
    ) <= 0:
        raise CalibrationError("holderWork median and timebase must be positive")
    target_ticks = (
        TARGET_MILLISECONDS * 1_000_000 * phone["timebaseDenominator"]
    ) // phone["timebaseNumerator"]
    iterations_measured = run["request"]["tunables"]["referenceLoopIterations"]
    return {
        "holderWorkIterations": round(
            target_ticks * iterations_measured / median_ticks
        ),
        "targetMilliseconds": TARGET_MILLISECONDS,
        "iterationsMeasured": iterations_measured,
        "medianTicks": median_ticks,
        "samplesUsed": len(usable),
    }


def load_phone_calibration(results: Path, phone_key: str) -> Optional[Dict[str, Any]]:
    """Read results/<phone>/calibration.json, or None when the phone has none."""
    path = results / phone_key / "calibration.json"
    if not path.exists():
        return None
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, UnicodeError):
        raise CalibrationError(
            "results/" + phone_key + "/calibration.json must be readable JSON"
        ) from None
    if not isinstance(document, dict):
        raise CalibrationError(
            "results/" + phone_key + "/calibration.json must be an object"
        )
    return document


def needs_calibration(tunables: Dict[str, Any]) -> bool:
    holder_work = tunables.get("priorityInversion", {}).get("holderWorkIterations")
    return holder_work == "fromCalibration"


def resolve_tunables(
    tunables: Dict[str, Any], calibration: Optional[Dict[str, Any]]
) -> Dict[str, Any]:
    """Return a copy with "fromCalibration" replaced by the phone's holder work size."""
    resolved = deepcopy(tunables)
    if not needs_calibration(resolved):
        return resolved
    try:
        iterations = calibration["priorityInversion"]["holderWorkIterations"]
    except (KeyError, TypeError):
        iterations = None
    if type(iterations) is not int or iterations < 1:
        raise CalibrationError(
            "holderWorkIterations is fromCalibration, but the phone's calibration.json "
            "has no priorityInversion work size; run bench.py calibrate"
        )
    resolved["priorityInversion"]["holderWorkIterations"] = iterations
    return resolved
