from __future__ import annotations

import json
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path

from runner.calibration import CalibrationError, derive_core_map
from runner.plans import load_plan, make_request

from tests.synthetic_attempts import make_attempt_lines, write_attempt


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        plan = load_plan(Path(__file__).resolve().parents[2] / 'plans/calibration.json')
        request = make_request(plan.runs[0], 'calibration-fixture', 1)
        request['tunables']['repeats'] = 3
        self.lines = make_attempt_lines(request, 'fixture-build')
        self.lines[0]['phone']['performanceLevels'][0]['logicalCPUCount'] = 2

        for line in self.lines:
            if line['type'] == 'samples' and line['metric'] == 'referenceLoop':
                cpu = line['thread']
                line['values'] = [200, 202, 10000] if cpu < 4 else [100, 102, 10000]

                # Migration outliers must never affect the CPU median.
                line['cpuAtEnd'][-1] = (cpu + 1) % 6

    def derive(self, lines=None):
        path, _ = write_attempt(self.directory, self.lines if lines is None else lines)
        return derive_core_map(path)

    def test_core_map_from_synthetic_calibration(self):
        self.assertEqual(
            self.derive(),
            {
                'performance': [4, 5],
                'efficiency': [0, 1, 2, 3],
                'medianTicksByCPU': {
                    '0': 201,
                    '1': 201,
                    '2': 201,
                    '3': 201,
                    '4': 101,
                    '5': 101,
                },
            },
        )

        # Both QoS blocks contribute; the UI block alone would classify CPUs 4 and 5.
        for line in self.lines:
            if (
                line['type'] == 'samples'
                and line.get('block') == 3
                and line['thread'] == 0
            ):
                line['values'][:2] = [1, 2]
        self.assertEqual(self.derive()['medianTicksByCPU']['0'], 101)

    def test_incomplete_stable_cpu_coverage_or_invalid_counts_are_rejected(self):
        mutations = [
            lambda lines: [
                line.update(cpuAtEnd=[0, 0, 0])
                for line in lines
                if line['type'] == 'samples'
                and line.get('thread') == 5
                and line['metric'] == 'referenceLoop'
            ],
            lambda lines: lines[0]['phone'].update(cpuCount=0),
            lambda lines: lines[0]['phone']['performanceLevels'][0].update(
                logicalCPUCount=0
            ),
            lambda lines: lines[0]['phone']['performanceLevels'][0].update(
                logicalCPUCount=7
            ),
            lambda lines: lines[0]['phone'].update(performanceLevels=[]),
        ]
        for mutate in mutations:
            lines = deepcopy(self.lines)
            mutate(lines)
            with (
                self.subTest(mutation=mutations.index(mutate)),
                self.assertRaises(CalibrationError),
            ):
                self.derive(lines)

    def test_invalid_or_noncalibration_file_does_not_make_a_core_map(self):
        for mutation in (
            lambda lines: lines[-1].update(status='refused'),
            lambda lines: lines[0]['request'].update(experiment='baseComparison'),
            lambda lines: lines[0]['phone']['performanceLevels'][0].update(
                logicalCPUCount=True
            ),
        ):
            lines = deepcopy(self.lines)
            mutation(lines)
            with self.assertRaises(CalibrationError):
                self.derive(lines)
