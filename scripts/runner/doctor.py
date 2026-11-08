from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import re
from typing import Any, Dict, List, Optional

from runner.builds import BuildError, FROZEN_SWIFT, FROZEN_XCODE, latest_build
from runner.calibration import (
    CalibrationError,
    load_phone_calibration,
    needs_calibration,
    resolve_tunables,
)
from runner.config import LocalConfig, Phone
from runner.device_control import DeviceControl, DeviceControlError
from runner.plans import Plan
from runner.processes import CommandRunner


@dataclass
class DoctorFinding:
    name: str
    ok: bool
    detail: str


def doctor(
    config: LocalConfig,
    phone: Phone,
    plan: Optional[Plan],
    results: Path,
    run_command: CommandRunner,
    devices: DeviceControl,
    now: datetime,
    *,
    build_info: Optional[Dict[str, Any]] = None,
) -> List[DoctorFinding]:
    findings = []

    def finding(name, ok, detail):
        findings.append(DoctorFinding(name, ok, detail))

    xcode = run_command(['xcodebuild', '-version'], 60)
    version = re.search(r'^Xcode ([\d.]+)$', xcode.stdout, re.MULTILINE)
    build_version = re.search(
        r'^Build version ([A-Za-z0-9]+)$', xcode.stdout, re.MULTILINE
    )
    finding(
        'xcode',
        xcode.return_code == 0
        and version is not None
        and build_version is not None
        and (version[1], build_version[1]) == FROZEN_XCODE,
        'requires Xcode ' + FROZEN_XCODE[0] + ' (' + FROZEN_XCODE[1] + ')',
    )
    swift = run_command(['xcrun', 'swiftc', '--version'], 60)
    parsed_swift = re.search(r'swiftlang-[\d.]+', swift.stdout)
    finding(
        'swift',
        swift.return_code == 0
        and parsed_swift is not None
        and parsed_swift[0] == FROZEN_SWIFT,
        'requires ' + FROZEN_SWIFT,
    )
    generator = run_command(['xcodegen', '--version'], 60)
    finding('xcodegen', generator.return_code == 0, 'XcodeGen must be installed')

    try:
        listed = devices.list_devices()
        device = next((item for item in listed if item.udid == phone.udid), None)
        finding('phone', device is not None, 'configured phone must be listed')
        finding(
            'available',
            device is not None and device.available,
            'configured phone must answer a live device query',
        )
        finding(
            'developer-mode',
            device is not None and device.developer_mode,
            'Developer Mode must be enabled',
        )
        if plan is not None and (not plan.smoke or phone.key in plan.ios_builds):
            finding(
                'ios-build',
                device is not None
                and device.os_build == plan.ios_builds.get(phone.key),
                'phone iOS build must match plan iosBuilds for the phone key',
            )
    except DeviceControlError as error:
        finding('phone', False, str(error))

    try:
        finding(
            'unlocked',
            devices.is_unlocked(phone.udid),
            'requires passcodeRequired=false and unlockedSinceBoot=true',
        )
    except DeviceControlError as error:
        finding('unlocked', False, str(error))

    if plan is not None and any(
        needs_calibration(run.tunables) for run in plan.runs
    ):
        try:
            calibration = load_phone_calibration(results, phone.key)
            for run in plan.runs:
                resolve_tunables(run.tunables, calibration)
            calibrated = True
        except CalibrationError:
            calibrated = False
        finding(
            'calibration',
            calibrated,
            'results/'
            + phone.key
            + '/calibration.json must contain priorityInversion for '
            'holderWorkIterations fromCalibration; run bench.py calibrate',
        )

    target = plan.build_target if plan else 'ios26'
    try:
        info = (
            build_info if build_info is not None else latest_build(results, target)
        )
        finding('build', info is not None, 'local build for ' + target + ' must exist')
        # Profile expiry is metadata only. Ivan disabled this preflight gate;
        # iOS installation/launch remains responsible for signature validity.
    except (BuildError, ValueError, KeyError, TypeError):
        finding('build', False, 'build metadata is invalid')
    return findings
