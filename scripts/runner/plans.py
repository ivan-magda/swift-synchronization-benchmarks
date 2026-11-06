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
    traced: bool


@dataclass(frozen=True)
class Plan:
    name: str
    build_target: str
    smoke: bool
    ios_builds: Dict[str, str]  # phone key -> installed iOS build
    traced: bool
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


_QOS_NAMES = ("userInteractive", "userInitiated", "default", "utility", "background")


def _ios_builds(value: Any, smoke: bool) -> Dict[str, str]:
    if not isinstance(value, dict):
        raise PlanError("iosBuilds must be an object of phone key to iOS build")
    for phone_key, build in value.items():
        _identifier(phone_key, "iosBuilds")
        _identifier(build, "iosBuilds")
    if not smoke and not value:
        raise PlanError("iosBuilds is required outside smoke plans")
    return dict(value)


def _object(value: Any, key: str) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise PlanError(key + " must be an object")
    return value


def _async_code_tunables(value: Any) -> None:
    value = _object(value, "tunables.asyncCode")
    _integer(value.get("callsPerTask"), "tunables.asyncCode.callsPerTask", 1)
    _integer(value.get("warmupCallsPerTask"), "tunables.asyncCode.warmupCallsPerTask")


def _priority_inversion_tunables(value: Any) -> None:
    value = _object(value, "tunables.priorityInversion")
    prefix = "tunables.priorityInversion."
    iterations = value.get("holderWorkIterations")
    # The session replaces "fromCalibration" with a number before it launches the app.
    if iterations != "fromCalibration":
        _integer(iterations, prefix + "holderWorkIterations", 1)
    if value.get("loadQoS") not in _QOS_NAMES:
        raise PlanError(prefix + "loadQoS is invalid")
    _integer(value.get("loadMilliseconds"), prefix + "loadMilliseconds", 1)
    _integer(value.get("mainDelayMicroseconds"), prefix + "mainDelayMicroseconds")
    _integer(value.get("pauseMilliseconds"), prefix + "pauseMilliseconds")
    _integer(value.get("warmupTrials"), prefix + "warmupTrials")
    _integer(value.get("trials"), prefix + "trials", 1)


def _request_registry_tunables(value: Any) -> None:
    value = _object(value, "tunables.requestRegistry")
    prefix = "tunables.requestRegistry."
    for field in ("inFlightPerThread", "workIterations", "cancelAllEvery"):
        _integer(value.get(field), prefix + field, 1)
    _integer(value.get("pauseMicroseconds"), prefix + "pauseMicroseconds", 0, 2**32 - 1)
    sample_every = _integer(value.get("sampleEvery"), prefix + "sampleEvery", 2)
    if sample_every % 2:
        raise PlanError(prefix + "sampleEvery must be even")


def _main_thread_cache_tunables(value: Any) -> None:
    value = _object(value, "tunables.mainThreadCache")
    prefix = "tunables.mainThreadCache."
    _integer(value.get("warmupFrames"), prefix + "warmupFrames")
    _integer(value.get("frames"), prefix + "frames", 1)
    _integer(
        value.get("scrollPointsPerSecond"), prefix + "scrollPointsPerSecond", 1, 20000
    )
    _integer(value.get("decodeIterations"), prefix + "decodeIterations", 1)
    _integer(
        value.get("writeIntervalMicroseconds"),
        prefix + "writeIntervalMicroseconds",
        0,
        2**32 - 1,
    )


def _tunables(value: Any) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise PlanError("tunables must be an object")
    _integer(value.get("threads"), "tunables.threads", 1, 64)
    if value.get("qos") not in _QOS_NAMES:
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
    if "asyncCode" in value:
        _async_code_tunables(value["asyncCode"])
    if "priorityInversion" in value:
        _priority_inversion_tunables(value["priorityInversion"])
    if "requestRegistry" in value:
        _request_registry_tunables(value["requestRegistry"])
    if "mainThreadCache" in value:
        _main_thread_cache_tunables(value["mainThreadCache"])
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
    if "iosBuild" in document:
        raise PlanError("iosBuild was replaced by iosBuilds (phone key → iOS build)")
    ios_builds = _ios_builds(document.get("iosBuilds", {}), smoke)
    traced = _boolean(document.get("traced", False), "traced")
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
        time_limit = _integer(entry.get("timeLimitSeconds"), "runs.timeLimitSeconds", 1)
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
                    traced,
                )
            )
    if shuffle:
        random.Random(seed).shuffle(runs)
    return Plan(
        name,
        build_target,
        smoke,
        ios_builds,
        traced,
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
    if run.traced:
        request["traced"] = True
    return request


def encode_request(request: Dict[str, Any]) -> str:
    encoded = json.dumps(
        request, sort_keys=True, separators=(",", ":"), allow_nan=False
    )
    return base64.b64encode(encoded.encode("utf-8")).decode("ascii")
