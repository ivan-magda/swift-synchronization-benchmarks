from __future__ import annotations

import base64
from copy import deepcopy
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import random
import re
from typing import Any, Dict, Optional, Tuple


class PlanError(ValueError):
    """A plan or request contains an invalid field."""


@dataclass(frozen=True)
class PlannedRun:
    run_id: str
    experiment: str
    variant: str
    seed: int
    smoke: bool
    simulation: Optional[str]
    mechanisms: Tuple[str, ...]
    operations: Tuple[str, ...]
    tunables: Dict[str, Any]
    time_limit_seconds: int


@dataclass(frozen=True)
class Plan:
    name: str
    build_target: str
    smoke: bool
    ios_build: Optional[str]
    seed: int
    shuffle: bool
    settle_seconds: int
    pause_seconds: int
    thermal_wait_seconds: int
    max_thermal_retries: int
    max_attempts: int
    runs: Tuple[PlannedRun, ...]
    sha256: str


def _identifier(value: Any, key: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(
        r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}", value
    ):
        raise PlanError(key + " must be a safe identifier of at most 128 characters")
    return value


def _integer(
    value: Any, key: str, minimum: int = 0, maximum: Optional[int] = None
) -> int:
    if (
        type(value) is not int
        or value < minimum
        or (maximum is not None and value > maximum)
    ):
        raise PlanError(key + " must be an integer in the allowed range")
    return value


def _boolean(value: Any, key: str) -> bool:
    if type(value) is not bool:
        raise PlanError(key + " must be a boolean")
    return value


def _strings(value: Any, key: str) -> Tuple[str, ...]:
    if not isinstance(value, list):
        raise PlanError(key + " must be an array")
    values = tuple(_identifier(item, key) for item in value)
    if len(values) != len(set(values)):
        raise PlanError(key + " must contain unique values")
    return values


def _tunables(value: Any) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise PlanError("tunables must be an object")
    _integer(value.get("threads"), "tunables.threads", 1, 64)
    if value.get("qos") not in (
        "userInteractive",
        "userInitiated",
        "default",
        "utility",
        "background",
    ):
        raise PlanError("tunables.qos is invalid")
    _integer(value.get("warmupBatches"), "tunables.warmupBatches")
    _integer(value.get("measuredBatches"), "tunables.measuredBatches", 1)
    sub_batches = _integer(value.get("subBatches"), "tunables.subBatches", 1)
    _integer(
        value.get("referenceLoopIterations"), "tunables.referenceLoopIterations", 1
    )
    operations = value.get("operationsPerBatch")
    if not isinstance(operations, dict) or "default" not in operations:
        raise PlanError("tunables.operationsPerBatch requires default")
    for key, count in operations.items():
        _identifier(key, "tunables.operationsPerBatch")
        _integer(count, "tunables.operationsPerBatch", sub_batches)
        if count % sub_batches:
            raise PlanError(
                "tunables.operationsPerBatch must be a multiple of subBatches"
            )
    if "repeats" in value:
        _integer(value["repeats"], "tunables.repeats", 1)
    return deepcopy(value)


def make_run_id(plan_name: str, entry_name: str, repeat: int) -> str:
    _identifier(plan_name, "name")
    _identifier(entry_name, "runs.name")
    _integer(repeat, "repeats", 1)
    return _identifier(f"{plan_name}.{entry_name}.{repeat}", "runID")


def make_run_seed(plan_seed: int, run_id: str) -> int:
    _integer(plan_seed, "seed", 0, 2**53 - 1)
    _identifier(run_id, "runID")
    return int(
        hashlib.sha256(f"{plan_seed}:{run_id}".encode("utf-8")).hexdigest()[:13], 16
    )


def make_attempt_id(run_id: str, attempt: int, now: datetime, suffix: str) -> str:
    _identifier(run_id, "runID")
    _integer(attempt, "attempt", 1)
    _identifier(suffix, "suffix")
    if now.tzinfo is None or now.utcoffset() is None:
        raise PlanError("now must have a timezone")
    timestamp = now.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return _identifier(f"{run_id}.attempt{attempt}.{timestamp}.{suffix}", "attemptID")


def load_plan(path: Path) -> Plan:
    try:
        raw = path.read_bytes()
        document = json.loads(raw)
    except (OSError, ValueError, UnicodeError):
        raise PlanError("plan must be readable JSON") from None
    if not isinstance(document, dict):
        raise PlanError("plan must be an object")
    _integer(document.get("schema"), "schema", 1, 1)
    name = _identifier(document.get("name"), "name")
    build_target = document.get("buildTarget")
    if build_target not in ("ios26", "ios18"):
        raise PlanError("buildTarget must be ios26 or ios18")
    smoke = _boolean(document.get("smoke"), "smoke")
    ios_build = document.get("iosBuild")
    if ios_build is not None:
        _identifier(ios_build, "iosBuild")
    elif not smoke:
        raise PlanError("iosBuild is required outside smoke plans")
    seed = _integer(document.get("seed"), "seed", 0, 2**53 - 1)
    shuffle = _boolean(document.get("shuffle", True), "shuffle")
    settle = _integer(document.get("settleSeconds"), "settleSeconds")
    pause = _integer(document.get("pauseSeconds"), "pauseSeconds")
    thermal_wait = _integer(
        document.get("thermalWaitSeconds", 300), "thermalWaitSeconds"
    )
    thermal_retries = _integer(
        document.get("maxThermalRetries", 3), "maxThermalRetries"
    )
    max_attempts = _integer(document.get("maxAttempts", 3), "maxAttempts", 1)
    entries = document.get("runs")
    if not isinstance(entries, list) or not entries:
        raise PlanError("runs must be a nonempty array")
    runs = []
    names = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise PlanError("runs entry must be an object")
        entry_name = _identifier(entry.get("name"), "runs.name")
        if entry_name in names:
            raise PlanError("runs.name must be unique")
        names.add(entry_name)
        experiment = _identifier(entry.get("experiment"), "runs.experiment")
        variant = _identifier(entry.get("variant"), "runs.variant")
        repeats = _integer(entry.get("repeats"), "runs.repeats", 1)
        time_limit = _integer(
            entry.get("timeLimitSeconds"), "runs.timeLimitSeconds", 1
        )
        simulation = entry.get("simulation")
        if "simulation" in entry and (not smoke or simulation not in ("crash", "hang")):
            raise PlanError("runs.simulation requires smoke and crash or hang")
        mechanisms = _strings(entry.get("mechanisms"), "runs.mechanisms")
        operations = _strings(entry.get("operations"), "runs.operations")
        tunables = _tunables(entry.get("tunables"))

        for repeat in range(1, repeats + 1):
            run_id = make_run_id(name, entry_name, repeat)
            runs.append(
                PlannedRun(
                    run_id,
                    experiment,
                    variant,
                    make_run_seed(seed, run_id),
                    smoke,
                    simulation,
                    mechanisms,
                    operations,
                    deepcopy(tunables),
                    time_limit,
                )
            )
    if shuffle:
        random.Random(seed).shuffle(runs)
    return Plan(
        name,
        build_target,
        smoke,
        ios_build,
        seed,
        shuffle,
        settle,
        pause,
        thermal_wait,
        thermal_retries,
        max_attempts,
        tuple(runs),
        hashlib.sha256(raw).hexdigest(),
    )


def make_request(run: PlannedRun, attempt_id: str, attempt: int) -> Dict[str, Any]:
    _identifier(attempt_id, "attemptID")
    _integer(attempt, "attempt", 1)
    request = {
        "schema": 1,
        "runID": run.run_id,
        "attemptID": attempt_id,
        "attempt": attempt,
        "experiment": run.experiment,
        "variant": run.variant,
        "seed": run.seed,
        "smoke": run.smoke,
        "mechanisms": list(run.mechanisms),
        "operations": list(run.operations),
        "tunables": deepcopy(run.tunables),
    }
    if run.simulation is not None:
        request["simulation"] = run.simulation
    return request


def encode_request(request: Dict[str, Any]) -> str:
    encoded = json.dumps(
        request, sort_keys=True, separators=(",", ":"), allow_nan=False
    )
    return base64.b64encode(encoded.encode("utf-8")).decode("ascii")
