from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import tempfile
import unittest

from runner.attempt_check import check_attempt
from runner.expected_attempt import expected_attempt
from runner.plans import load_plan
from tests.synthetic_attempts import hot_flag_request, make_attempt_lines, write_attempt


def cache_request():
    request = hot_flag_request()
    request.update(experiment="mainThreadCache", operations=["scroll"])
    request["mechanisms"] = request["mechanisms"][:13] + ["mainActor"]
    request["tunables"].update(
        threads=2,
        mainThreadCache=dict(
            warmupFrames=10,
            frames=60,
            scrollPointsPerSecond=3000,
            decodeIterations=10,
            writeIntervalMicroseconds=20000,
        ),
    )
    return request


class MainThreadCacheTests(unittest.TestCase):
    def test_variable_read_count_but_exact_frame_count(self):
        request = cache_request()
        expected = expected_attempt(request, 6)
        self.assertEqual(len(expected.blocks), 14)
        lines = make_attempt_lines(request, "test")
        with tempfile.TemporaryDirectory() as directory:
            for count in (1, 17, 83):
                changed = deepcopy(lines)
                for line in changed:
                    if line.get("metric") == "readTime":
                        line["values"] = [3] * count
                result, marker = write_attempt(Path(directory), changed)
                self.assertTrue(check_attempt(result, marker, request, "test").accepted)
            for metric, count in (
                ("readTime", 0),
                ("frameStart", 59),
                ("frameInterval", 61),
            ):
                changed = deepcopy(lines)
                next(line for line in changed if line.get("metric") == metric)[
                    "values"
                ] = [3] * count
                result, marker = write_attempt(Path(directory), changed)
                self.assertFalse(
                    check_attempt(result, marker, request, "test").accepted
                )

    def test_invalid_work_and_rows_are_rejected(self):
        for field, value in (
            ("frames", 0),
            ("warmupFrames", -1),
            ("scrollPointsPerSecond", 20001),
            ("decodeIterations", 0),
            ("writeIntervalMicroseconds", 2**32),
            ("frames", 2**63 - 1),
        ):
            request = cache_request()
            request["tunables"]["mainThreadCache"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                expected_attempt(request, 6)
        for field, value in (
            ("variant", "other"),
            ("operations", ["read"]),
            ("mechanisms", ["actor"]),
            ("mechanisms", ["nsLock", "nsLock"]),
        ):
            request = cache_request()
            request[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                expected_attempt(request, 6)

    def test_plan_has_two_and_four_writers(self):
        path = (
            Path(__file__).resolve().parents[2]
            / "plans/acceptance-main-thread-cache.json"
        )
        plan = load_plan(path)
        self.assertEqual(sorted(run.tunables["threads"] for run in plan.runs), [2, 4])
        for run in plan.runs:
            self.assertEqual(len(run.mechanisms), 14)
            self.assertEqual(run.operations, ("scroll",))
