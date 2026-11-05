from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import re
from typing import Dict

REPOSITORY = Path(__file__).resolve().parents[2]


class ConfigError(ValueError):
    """Invalid local configuration; messages contain keys, never private values."""


@dataclass(frozen=True)
class Phone:
    key: str
    udid: str
    model: str


@dataclass(frozen=True)
class LocalConfig:
    team_id: str
    bundle_id: str
    phones: Dict[str, Phone]


def _text(document: dict, key: str, prefix: str = "") -> str:
    value = document.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(prefix + key + " must be a nonempty string")
    return value


def load_local_config(path: Path) -> LocalConfig:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError):
        raise ConfigError("local config could not be read") from None
    except ValueError:
        raise ConfigError("local config must be valid JSON") from None
    if not isinstance(document, dict):
        raise ConfigError("local config must be an object")

    team_id = _text(document, "teamID")
    bundle_id = _text(document, "bundleID")
    entries = document.get("phones")
    if not isinstance(entries, dict) or not entries:
        raise ConfigError("phones must be a nonempty object")
    phones = {}
    for key, entry in entries.items():
        if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}", key):
            raise ConfigError("phones key must be a safe identifier")
        if not isinstance(entry, dict):
            raise ConfigError("phones entry must be an object")
        phones[key] = Phone(
            key,
            _text(entry, "udid", "phones."),
            _text(entry, "model", "phones."),
        )
    return LocalConfig(team_id, bundle_id, phones)
