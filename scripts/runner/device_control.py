from __future__ import annotations

from dataclasses import asdict, dataclass
import json
from pathlib import Path
import tempfile
from typing import Any, Dict, List

from runner.processes import CommandRunner


@dataclass(frozen=True)
class DeviceInfo:
    udid: str
    model: str
    os_version: str
    os_build: str
    developer_mode: bool
    available: bool


class DeviceControlError(Exception):
    """Names the devicectl command and the file that keeps its raw output."""


class DeviceControl:
    """Runs devicectl; scratch_folder must be ignored private storage outside results."""

    def __init__(self, run_command: CommandRunner, scratch_folder: Path):
        self.run_command = run_command
        self.scratch_folder = scratch_folder

    def _query(self, command: List[str]) -> Dict[str, Any]:
        self.scratch_folder.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=self.scratch_folder, suffix='.json', delete=False) as output:
            path = Path(output.name)
        arguments = ['xcrun', 'devicectl'] + command + ['--json-output', str(path)]
        result = self.run_command(arguments, 60)
        diagnostic = path.with_suffix('.diagnostic.json')
        diagnostic.write_text(json.dumps(asdict(result), sort_keys=True, indent=2) + '\n', encoding='utf-8')
        # Diagnostics are private; only the safe command name and basename are exposed.
        label = 'list devices' if command[0] == 'list' else 'device info lockState'
        message = 'devicectl ' + label + ' failed; private diagnostic ' + diagnostic.name
        if result.return_code:
            raise DeviceControlError(message)
        try:
            document = json.loads(path.read_text(encoding='utf-8'))
            if document.get('info', {}).get('outcome') != 'success':
                raise ValueError()
            payload = document['result']
            if not isinstance(payload, dict):
                raise ValueError()
            return payload
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            raise DeviceControlError(message) from None

    def list_devices(self) -> List[DeviceInfo]:
        payload = self._query(['list', 'devices'])
        try:
            entries = payload['devices']
            if not isinstance(entries, list):
                raise TypeError()
            devices = []
            for entry in entries:
                hardware = entry.get('hardwareProperties', {})
                state = entry.get('deviceProperties', {})
                connection = entry.get('connectionProperties', {})
                udid = hardware.get('udid', entry.get('identifier', ''))
                available = False
                # A disconnected tunnel is lazy: paired wired phones can still answer.
                # A successful lock query confirms availability even when the phone is locked.
                if connection.get('pairingState') == 'paired':
                    try:
                        self.is_unlocked(udid)
                        available = True
                    except DeviceControlError:
                        pass
                devices.append(DeviceInfo(
                    udid, hardware.get('productType', ''), state.get('osVersionNumber', ''),
                    state.get('osBuildUpdate', ''), state.get('developerModeStatus') == 'enabled', available,
                ))
            return devices
        except (TypeError, KeyError, AttributeError):
            raise DeviceControlError('devicectl list devices returned invalid device records; see private scratch JSON') from None

    def is_unlocked(self, udid: str) -> bool:
        payload = self._query(['device', 'info', 'lockState', '--device', udid])
        # Missing or malformed lock-state fields must never count as unlocked.
        return payload.get('passcodeRequired') is False and payload.get('unlockedSinceBoot') is True
