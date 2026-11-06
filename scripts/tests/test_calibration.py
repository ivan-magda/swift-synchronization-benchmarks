from __future__ import annotations

import json
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path

from runner.calibration import (
    CalibrationError,
    derive_core_map,
    derive_display,
    derive_holder_work,
    load_phone_calibration,
    resolve_tunables,
)
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

    def test_display_uses_callback_gaps_and_phone_timebase(self):
        # 200,000 ticks at 125/3 ns per tick is 8.333... ms.
        # Absolute timestamps must be differenced before taking the median.
        self.lines[0]['phone']['timebaseNumerator'] = 125
        self.lines[0]['phone']['timebaseDenominator'] = 3
        for line in self.lines:
            if line['type'] == 'samples' and line['metric'] == 'displayFrame':
                line['values'] = [10_000_000, 10_200_000, 10_400_000]
        path, _ = write_attempt(self.directory, self.lines)
        self.assertEqual(
            derive_display(path),
            {
                'medianFrameTicks': 200_000,
                'medianFrameMilliseconds': 8.33,
                'framesMeasured': 3,
            },
        )

    def test_display_requires_positive_intervals_and_timebase(self):
        for values, numerator, denominator in (
            ([100], 125, 3),
            ([100, 100, 200], 125, 3),
            ([200, 100, 300], 125, 3),
            ([100, 200, 300], 0, 3),
            ([100, 200, 300], 125, 0),
        ):
            with self.subTest(
                values=values, numerator=numerator, denominator=denominator
            ):
                lines = deepcopy(self.lines)
                lines[0]['request']['tunables']['repeats'] = len(values)
                lines[0]['phone'].update(
                    timebaseNumerator=numerator, timebaseDenominator=denominator
                )
                for line in lines:
                    if line['type'] == 'samples':
                        for field in ('values', 'cpuAtStart', 'cpuAtEnd'):
                            if field in line:
                                line[field] = line[field][: len(values)]
                        if line['metric'] == 'displayFrame':
                            line['values'] = values
                path, _ = write_attempt(self.directory, lines)
                with self.assertRaises(CalibrationError):
                    derive_display(path)

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


class HolderWorkTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def derive(self, values, starts, ends):
        # Timebase 125/3, 100,000 measured iterations; CPUs 4 and 5 are faster.
        plan = load_plan(Path(__file__).resolve().parents[2] / 'plans/calibration.json')
        request = make_request(plan.runs[0], 'holder-work-fixture', 1)
        request['tunables']['repeats'] = len(values)
        lines = make_attempt_lines(request, 'fixture-build')
        for line in lines:
            if line['type'] != 'samples':
                continue
            if line['metric'] == 'referenceLoop':
                line['values'] = [200 if line['thread'] < 4 else 100] * len(values)
            elif line['metric'] == 'holderWork':
                line.update(values=values, cpuAtStart=starts, cpuAtEnd=ends)
        path, _ = write_attempt(self.directory, lines)
        return derive_holder_work(path, derive_core_map(path))

    def test_holder_work_uses_only_samples_on_one_performance_cpu(self):
        # 5 ms = 120,000 ticks; 120,000 x 100,000 / 2,400. The efficiency-CPU sample (1)
        # and the migrated sample (9) would move the median to 2,300.
        self.assertEqual(
            self.derive([2400, 2300, 2500, 1, 9], [4, 5, 4, 0, 4], [4, 5, 4, 0, 5]),
            {
                'holderWorkIterations': 5_000_000,
                'targetMilliseconds': 5,
                'iterationsMeasured': 100_000,
                'medianTicks': 2400,
                'samplesUsed': 3,
            },
        )

    def test_fewer_than_half_usable_samples_are_rejected(self):
        with self.assertRaises(CalibrationError):
            self.derive([2400, 2400, 1, 9, 7], [4, 5, 0, 4, 1], [4, 5, 0, 5, 1])


class PhoneCalibrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.results = Path(self.temporary.name) / 'results'
        self.tunables = {
            'threads': 1,
            'priorityInversion': {
                'holderWorkIterations': 'fromCalibration',
                'trials': 3,
            },
        }

    def test_missing_phone_calibration_is_none(self):
        self.assertIsNone(load_phone_calibration(self.results, 'fixture'))

    def test_saved_phone_calibration_is_loaded(self):
        (self.results / 'fixture').mkdir(parents=True)
        (self.results / 'fixture/calibration.json').write_text(
            json.dumps({'attemptID': 'calibration-fixture'})
        )
        self.assertEqual(
            load_phone_calibration(self.results, 'fixture'),
            {'attemptID': 'calibration-fixture'},
        )

    def test_from_calibration_is_replaced_in_a_copy(self):
        (self.results / 'fixture').mkdir(parents=True)
        (self.results / 'fixture/calibration.json').write_text(
            json.dumps({'priorityInversion': {'holderWorkIterations': 5_000_000}})
        )
        calibration = load_phone_calibration(self.results, 'fixture')
        resolved = resolve_tunables(self.tunables, calibration)
        self.assertEqual(
            resolved['priorityInversion']['holderWorkIterations'], 5_000_000
        )
        self.assertEqual(resolved['priorityInversion']['trials'], 3)
        self.assertEqual(
            self.tunables['priorityInversion']['holderWorkIterations'],
            'fromCalibration',
        )

    def test_tunables_without_from_calibration_need_no_calibration(self):
        tunables = {'threads': 1, 'priorityInversion': {'holderWorkIterations': 7}}
        self.assertEqual(resolve_tunables(tunables, None), tunables)
        self.assertEqual(resolve_tunables({'threads': 1}, None), {'threads': 1})

    def test_unresolvable_from_calibration_names_the_phone_file(self):
        for calibration in (
            None,
            {'attemptID': 'calibration-fixture'},
            {'priorityInversion': {'holderWorkIterations': 0}},
        ):
            with (
                self.subTest(calibration=calibration),
                self.assertRaisesRegex(CalibrationError, 'calibration.json'),
            ):
                resolve_tunables(self.tunables, calibration)
