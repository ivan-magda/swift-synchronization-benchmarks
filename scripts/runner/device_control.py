from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime
import json
from pathlib import Path
import tempfile
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import unquote, urlparse

from runner.processes import CommandRunner, ProcessResult


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


def _path(value: str) -> str:
    if not isinstance(value, str) or not value:
        raise ValueError()
    return unquote(urlparse(value).path).rstrip('/')


def _pid(value: Any) -> int:
    if type(value) is not int or value <= 0:
        raise ValueError()
    return value


class DeviceControl:
    """Runs devicectl; scratch_folder must be ignored private storage outside results."""

    def __init__(self, run_command: CommandRunner, scratch_folder: Path):
        self.run_command = run_command
        self.scratch_folder = scratch_folder
        self._failure_message = ''
        self._application_paths: Dict[Tuple[str, str], str] = {}

    def _query(
        self,
        command: List[str],
        timeout: float = 60,
        expected_failure: Optional[
            Callable[[ProcessResult, Dict[str, Any]], bool]
        ] = None,
    ) -> Optional[Dict[str, Any]]:
        self.scratch_folder.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            dir=self.scratch_folder, suffix='.json', delete=False
        ) as output:
            path = Path(output.name)
        # Global options must precede '--', otherwise they become app arguments.
        index = command.index('--') if '--' in command else len(command)
        arguments = (
            ['xcrun', 'devicectl']
            + command[:index]
            + ['--json-output', str(path)]
            + command[index:]
        )
        result = self.run_command(arguments, timeout)
        diagnostic = path.with_suffix('.diagnostic.json')
        diagnostic.write_text(
            json.dumps(asdict(result), sort_keys=True, indent=2) + '\n',
            encoding='utf-8',
        )
        label = ' '.join(command[:2] if command[0] == 'list' else command[:3])
        self._failure_message = (
            'devicectl ' + label + ' failed; private diagnostic ' + diagnostic.name
        )
        try:
            document = json.loads(path.read_text(encoding='utf-8'))
            if not isinstance(document, dict):
                raise ValueError()
        except (OSError, ValueError, UnicodeError):
            document = {}
        if result.return_code and expected_failure is not None:
            try:
                if expected_failure(result, document):
                    return None
            except (ValueError, KeyError, TypeError, AttributeError):
                pass
        try:
            if (
                result.return_code
                or document.get('info', {}).get('outcome') != 'success'
            ):
                raise ValueError()
            payload = document['result']
            if not isinstance(payload, dict):
                raise ValueError()
            return payload
        except (ValueError, KeyError, TypeError, AttributeError):
            raise DeviceControlError(self._failure_message) from None

    def list_devices(self) -> List[DeviceInfo]:
        payload = self._query(['list', 'devices'])
        message = self._failure_message
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
                if connection.get('pairingState') == 'paired':
                    try:
                        self.is_unlocked(udid)
                        available = True
                    except DeviceControlError:
                        pass
                devices.append(
                    DeviceInfo(
                        udid,
                        hardware.get('productType', ''),
                        state.get('osVersionNumber', ''),
                        state.get('osBuildUpdate', ''),
                        state.get('developerModeStatus') == 'enabled',
                        available,
                    )
                )
            return devices
        except (TypeError, KeyError, AttributeError):
            raise DeviceControlError(message) from None

    def is_unlocked(self, udid: str) -> bool:
        payload = self._query(['device', 'info', 'lockState', '--device', udid])
        return (
            payload.get('passcodeRequired') is False
            and payload.get('unlockedSinceBoot') is True
        )

    def install(self, udid: str, app: Path) -> None:
        payload = self._query(
            ['device', 'install', 'app', '--device', udid, str(app)]
        )
        try:
            applications = payload['installedApplications']
            if not isinstance(applications, list) or not applications:
                raise ValueError()
            paths = {}
            for application in applications:
                bundle = application['bundleID']
                if not isinstance(bundle, str) or not bundle:
                    raise ValueError()
                paths[(udid, bundle)] = _path(application['installationURL'])
            self._application_paths.update(paths)
        except (ValueError, KeyError, TypeError, AttributeError):
            raise DeviceControlError(self._failure_message) from None

    def launch(
        self, udid: str, bundle_id: str, app_arguments: List[str],
        timeout_seconds: float = 60,
    ) -> int:
        payload = self._query(
            [
                'device',
                'process',
                'launch',
                '--device',
                udid,
                '--terminate-existing',
                bundle_id,
                '--',
            ]
            + app_arguments,
            timeout_seconds,
        )
        try:
            process = payload['process']
            pid = _pid(process['processIdentifier'])
            self._application_paths[(udid, bundle_id)] = str(
                Path(_path(process['executable'])).parent
            )
            return pid
        except (ValueError, KeyError, TypeError, AttributeError):
            raise DeviceControlError(self._failure_message) from None

    def await_termination(
        self, udid: str, pid: int, timeout_seconds: float
    ) -> Tuple[bool, Optional[int]]:
        """Respect the caller deadline, including below devicectl's five-second minimum."""
        if timeout_seconds <= 0:
            raise DeviceControlError(
                'devicectl awaitTermination requires a positive timeout'
            )

        def timed_out(result, document):
            error = document.get('error', {})
            return result.return_code == 124 or (
                result.return_code == 2
                and error.get('domain') == 'ArgumentParserInternal.ExitCode'
                and error.get('code') == 2
                and 'Command timeout of ' in result.stderr
                and 'seconds exceeded.' in result.stderr
            )

        payload = self._query(
            [
                'device',
                'process',
                'awaitTermination',
                '--device',
                udid,
                '--pid',
                str(pid),
                '--timeout',
                str(max(5, timeout_seconds)),
            ],
            timeout_seconds,
            timed_out,
        )
        if payload is None:
            return False, None
        try:
            status = payload['terminationStatus']
            code = status['exitCode']
            if type(code) is not int:
                raise ValueError()
            return True, code
        except (ValueError, KeyError, TypeError):
            raise DeviceControlError(self._failure_message) from None

    def running_pids(
        self, udid: str, bundle_id: str, timeout_seconds: float = 60
    ) -> List[int]:
        """Use the bundle path learned by this instance's install or launch.

        The process listing contains executable URLs, without bundle identifiers.
        Unknown bundles fail rather than guessing by the executable's basename.
        """
        payload = self._query(
            ['device', 'info', 'processes', '--device', udid], timeout_seconds
        )
        try:
            processes = payload['runningProcesses']
            if not isinstance(processes, list):
                raise ValueError()
            application = self._application_paths.get((udid, bundle_id))
            if application is None:
                raise DeviceControlError(
                    self._failure_message + '; install or launch this bundle first'
                )
            pids = []
            for process in processes:
                pid = _pid(process['processIdentifier'])
                if str(Path(_path(process['executable'])).parent) == application:
                    pids.append(pid)
            return pids
        except (ValueError, KeyError, TypeError, AttributeError):
            raise DeviceControlError(self._failure_message) from None

    def terminate(self, udid: str, pid: int) -> None:
        payload = self._query(
            [
                'device',
                'process',
                'terminate',
                '--device',
                udid,
                '--pid',
                str(pid),
                '--kill',
            ]
        )
        try:
            if _pid(payload['process']['processIdentifier']) != pid:
                raise ValueError()
        except (ValueError, KeyError, TypeError):
            raise DeviceControlError(self._failure_message) from None

    def _copy(
        self,
        udid: str,
        domain: str,
        source: str,
        destination: Path,
        bundle_id: Optional[str] = None,
    ) -> bool:
        command = [
            'device', 'copy', 'from', '--device', udid, '--domain-type', domain
        ]
        if bundle_id is not None:
            command += ['--domain-identifier', bundle_id]
        command += ['--source', source, '--destination', str(destination)]

        def missing_file(result, document):
            error = document.get('error', {})
            description = (
                error.get('userInfo', {})
                .get('NSLocalizedDescription', {})
                .get('string')
            )
            return (
                result.return_code == 1
                and error.get('domain') == 'com.apple.dt.CoreDeviceError'
                and error.get('code') == 7000
                and description == 'Failed to retrieve the file node for ' + source
            )

        payload = self._query(command, expected_failure=missing_file)
        if payload is None:
            return False
        try:
            for key in ('source', 'destination', 'domain'):
                if not isinstance(payload[key], str) or not payload[key]:
                    raise ValueError()
            if payload['domain'] != domain:
                raise ValueError()
            return True
        except (ValueError, KeyError, TypeError):
            raise DeviceControlError(self._failure_message) from None

    def copy_from_app(
        self, udid: str, bundle_id: str, source: str, destination: Path
    ) -> bool:
        return self._copy(udid, 'appDataContainer', source, destination, bundle_id)

    def crash_logs(
        self,
        udid: str,
        name_contains: str,
        newer_than: Optional[datetime] = None,
        timeout_seconds: float = 60,
    ) -> List[str]:
        """Return matching files, optionally strictly newer than an aware launch time."""
        payload = self._query(
            [
                'device',
                'info',
                'files',
                '--device',
                udid,
                '--domain-type',
                'systemCrashLogs',
            ],
            timeout_seconds,
        )
        try:
            if newer_than is not None and newer_than.utcoffset() is None:
                raise ValueError()
            files = payload['files']
            if not isinstance(files, list):
                raise ValueError()
            names = []
            for file in files:
                name = file['name']
                source = file['relativePath']
                directory = file['resources']['isDirectory']
                if (
                    not isinstance(name, str)
                    or not isinstance(source, str)
                    or type(directory) is not bool
                ):
                    raise ValueError()
                modified = datetime.fromisoformat(
                    file['metadata']['lastModDate'].replace('Z', '+00:00')
                )
                if modified.utcoffset() is None:
                    raise ValueError()
                if (
                    not directory
                    and name_contains in name
                    and (newer_than is None or modified > newer_than)
                ):
                    names.append(source)
            return names
        except (ValueError, KeyError, TypeError, AttributeError):
            raise DeviceControlError(self._failure_message) from None

    def copy_crash_log(self, udid: str, name: str, destination: Path) -> bool:
        return self._copy(udid, 'systemCrashLogs', name, destination)
