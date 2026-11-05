"""Outcome of one experiment 8B trial, shared by the file check and the analysis."""

from __future__ import annotations

from typing import Any, Dict


def classify_trial(line: Dict[str, Any]) -> str:
    """Valid: the main thread arrived while the holder held the lock and the load ran.
    Censored: such an arrival, but the main thread got the lock after the load stopped.
    Invalid: everything else."""
    arrived_during_hold = (
        line["holderAcquire"] < line["mainArrival"] < line["holderRelease"]
    )
    if not arrived_during_hold or line["mainArrival"] >= line["loadStop"]:
        return "invalid"
    if line["mainAcquire"] > line["loadStop"]:
        return "censored"
    return "valid"
