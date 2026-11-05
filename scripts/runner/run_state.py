from __future__ import annotations

from copy import deepcopy
import json
import os
from pathlib import Path
import re
import tempfile
from typing import Any, Dict, List

from runner.plans import Plan, PlannedRun


class StateError(ValueError):
    """Invalid state must be repaired explicitly instead of losing progress."""


def state_path(results: Path, plan: Plan, phone_key: str, code_hash: str) -> Path:
    for key, value in (("name", plan.name), ("phone key", phone_key)):
        if not isinstance(value, str) or not re.fullmatch(
            r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}", value
        ):
            raise StateError(key + " must be a safe identifier")
    for key, value in (("plan hash", plan.sha256), ("code hash", code_hash)):
        if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
            raise StateError(key + " must be a SHA-256 hash")
    return results / "state" / f"{plan.name}--{phone_key}--{plan.sha256[:8]}--{code_hash[:8]}.json"


class RunState:
    """Progress for one plan, saved atomically after each recorded attempt."""

    def __init__(self, path: Path, plan: Plan, runs: Dict[str, List[Dict[str, Any]]]):
        self.path = path
        self.plan = plan
        self._runs = runs

    @classmethod
    def load_or_create(cls, path: Path, plan: Plan) -> RunState:
        try:
            raw = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return cls(path, plan, {run.run_id: [] for run in plan.runs})
        try:
            document = json.loads(raw)
        except (ValueError, UnicodeError):
            raise StateError("state must be valid JSON") from None
        if (
            not isinstance(document, dict)
            or type(document.get("schema")) is not int
            or document["schema"] != 1
        ):
            raise StateError("state schema must be 1")
        if document.get("planName") != plan.name or document.get("planSHA256") != plan.sha256:
            raise StateError("state planName and planSHA256 must match the plan")
        runs = document.get("runs")
        if not isinstance(runs, dict) or set(runs) != {run.run_id for run in plan.runs}:
            raise StateError("state runs must match the plan")
        for attempts in runs.values():
            if not isinstance(attempts, list):
                raise StateError("state attempts must be arrays")
            for attempt in attempts:
                cls._validate_attempt(attempt)
        return cls(path, plan, runs)

    @staticmethod
    def _validate_attempt(attempt: Any) -> None:
        if not isinstance(attempt, dict) or type(attempt.get("accepted")) is not bool:
            raise StateError("attempt accepted must be a boolean")

    def pending_runs(self) -> List[PlannedRun]:
        pending = []
        for run in self.plan.runs:
            attempts = self._runs[run.run_id]
            accepted = any(attempt["accepted"] for attempt in attempts)
            counted = sum(
                not (
                    attempt.get("status") == "refused"
                    and attempt.get("reasonCode") == "thermal"
                )
                for attempt in attempts
            )
            if not accepted and counted < self.plan.max_attempts:
                pending.append(run)
        return pending

    def record_attempt(self, run_id: str, attempt: Dict[str, Any]) -> None:
        if run_id not in self._runs:
            raise StateError("runID is not in the plan")
        self._validate_attempt(attempt)
        self._runs[run_id].append(deepcopy(attempt))
        try:
            self.save()
        except Exception:
            self._runs[run_id].pop()
            raise

    def attempts(self, run_id: str) -> List[Dict[str, Any]]:
        if run_id not in self._runs:
            raise StateError("runID is not in the plan")
        return deepcopy(self._runs[run_id])

    def save(self) -> None:
        document = {
            "schema": 1, "planName": self.plan.name,
            "planSHA256": self.plan.sha256, "runs": self._runs,
        }
        encoded = json.dumps(document, sort_keys=True, indent=2, allow_nan=False) + "\n"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w", encoding="utf-8", dir=self.path.parent,
                prefix=self.path.name + ".", suffix=".tmp", delete=False,
            ) as output:
                temporary = Path(output.name)
                output.write(encoded)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()
