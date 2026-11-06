from __future__ import annotations

import base64
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest

from runner.plans import (
    PlanError,
    encode_request,
    load_plan,
    make_attempt_id,
    make_request,
    make_run_id,
    make_run_seed,
)

PLANS = Path(__file__).resolve().parents[2] / "plans"
SMOKE_PLAN = PLANS / "smoke-base-comparison.json"


class PlanTests(unittest.TestCase):
    def load_document(self, document):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plan.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            return load_plan(path)

    def test_every_plan_in_plans_loads(self):
        paths = sorted(PLANS.glob("*.json"))
        # A glob alone would pass before the phase 2 plans exist.
        self.assertTrue(
            {
                "acceptance-async-code.json",
                "acceptance-hot-flag.json",
                "acceptance-request-registry.json",
                "acceptance-hot-flag-ios18.json",
                "acceptance-priority-inversion.json",
                "traced-async-code.json",
                "traced-priority-inversion.json",
            }.issubset({path.name for path in paths})
        )
        for path in paths:
            with self.subTest(plan=path.name):
                load_plan(path)

    def test_request_registry_group_rejects_each_bad_minimum(self):
        for field, value in (
            ("inFlightPerThread", 0), ("workIterations", 0),
            ("pauseMicroseconds", -1), ("cancelAllEvery", 0), ("sampleEvery", 0), ("sampleEvery", 1), ("sampleEvery", 3),
        ):
            with self.subTest(field=field):
                document = json.loads(SMOKE_PLAN.read_text())
                group = dict(inFlightPerThread=1, workIterations=1,
                             pauseMicroseconds=0, cancelAllEvery=1, sampleEvery=2)
                group[field] = value
                document["runs"][0]["tunables"]["requestRegistry"] = group
                with self.assertRaisesRegex(PlanError, "requestRegistry." + field):
                    self.load_document(document)

    def test_run_id_and_seed(self):
        run_id = make_run_id("smoke-base-comparison", "one-thread", 1)
        self.assertEqual(run_id, "smoke-base-comparison.one-thread.1")
        self.assertEqual(make_run_seed(20261105, run_id), 184828474630059)
        self.assertEqual(
            make_attempt_id(
                run_id, 1, datetime(2026, 11, 5, tzinfo=timezone.utc), "abcd"
            ),
            "smoke-base-comparison.one-thread.1.attempt1.20261105T000000Z.abcd",
        )

    def test_request_keys_and_encoding(self):
        run = load_plan(SMOKE_PLAN).runs[0]
        attempt_id = make_attempt_id(
            run.run_id, 1, datetime(2026, 11, 5, tzinfo=timezone.utc), "abcd"
        )
        request = make_request(run, attempt_id, attempt=1)
        self.assertEqual(
            set(request),
            {
                "schema",
                "runID",
                "attemptID",
                "attempt",
                "experiment",
                "variant",
                "seed",
                "smoke",
                "mechanisms",
                "operations",
                "tunables",
            },
        )
        encoded = base64.b64decode(encode_request(request)).decode("utf-8")
        self.assertEqual(json.loads(encoded), request)
        request["tunables"]["threads"] = 64
        self.assertNotEqual(run.tunables["threads"], 64)

    def test_smoke_plan_order_is_stable(self):
        for name in ("smoke-base-comparison.json", "smoke-base-comparison-ios18.json"):
            with self.subTest(name=name):
                plan = load_plan(PLANS / name)
                self.assertEqual(plan.runs, load_plan(PLANS / name).runs)
                self.assertEqual(len(plan.runs), 2)
                self.assertEqual(
                    {run.variant for run in plan.runs}, {"oneThread", "twoThreads"}
                )
        document = json.loads(SMOKE_PLAN.read_text())
        document["seed"] = 0
        document["runs"] = document["runs"][:1]
        document["runs"][0]["repeats"] = 3

        expanded = self.load_document(document)
        self.assertEqual(len({run.seed for run in expanded.runs}), 3)
        document["shuffle"] = False
        self.assertEqual(
            [run.run_id for run in self.load_document(document).runs],
            ["smoke-base-comparison.one-thread.1", "smoke-base-comparison.one-thread.2", "smoke-base-comparison.one-thread.3"],
        )
        document["shuffle"] = True

        # Random(0) shuffles positions 1, 2, 3 into 1, 3, 2 on both supported Pythons.
        self.assertEqual(
            [run.run_id for run in self.load_document(document).runs],
            [
                "smoke-base-comparison.one-thread.1",
                "smoke-base-comparison.one-thread.3",
                "smoke-base-comparison.one-thread.2",
            ],
        )

    def test_unshuffled_plan_keeps_file_order_and_simulation(self):
        plan = load_plan(PLANS / "crash-and-hang.json")
        self.assertEqual(
            [run.run_id for run in plan.runs],
            ["crash-and-hang.crash.1", "crash-and-hang.hang.1"],
        )
        self.assertEqual(
            [make_request(run, "safe-attempt", 1)["simulation"] for run in plan.runs],
            ["crash", "hang"],
        )


    def test_calibration_launches_once_with_200_samples_per_measurement(self):
        plan = load_plan(PLANS / "calibration.json")
        self.assertEqual(len(plan.runs), 1)
        request = make_request(plan.runs[0], "calibration-attempt", 1)
        self.assertEqual(request["tunables"]["repeats"], 200)
        self.assertEqual(
            (
                request["experiment"],
                request["variant"],
                request["mechanisms"],
                request["operations"],
            ),
            ("calibration", "default", [], []),
        )


    def test_invalid_plans_name_the_key(self):
        document = json.loads(SMOKE_PLAN.read_text())
        cases = [
            ("buildTarget", lambda value: value.pop("buildTarget")),
            ("buildTarget", lambda value: value.update(buildTarget="ios17")),
            ("repeats", lambda value: value["runs"][0].update(repeats=0)),
            (
                "name",
                lambda value: value["runs"][1].update(name=value["runs"][0]["name"]),
            ),
            (
                "simulation",
                lambda value: (
                    value.update(smoke=False, iosBuilds={"phone": "24A1"}),
                    value["runs"][0].update(simulation="crash"),
                ),
            ),
            ("iosBuilds", lambda value: value.update(smoke=False)),
            ("iosBuilds", lambda value: value.update(smoke=False, iosBuilds={})),
            ("iosBuilds", lambda value: value.update(iosBuilds={"phone": "bad/build"})),
            ("iosBuilds", lambda value: value.update(iosBuilds=["24A1"])),
            ("iosBuild was replaced by iosBuilds", lambda value: value.update(iosBuild="24A1")),
            (
                "callsPerTask",
                lambda value: value["runs"][0]["tunables"].update(
                    asyncCode={"callsPerTask": 0, "warmupCallsPerTask": 0}
                ),
            ),
            (
                "warmupCallsPerTask",
                lambda value: value["runs"][0]["tunables"].update(
                    asyncCode={"callsPerTask": 1, "warmupCallsPerTask": -1}
                ),
            ),
            ("schema", lambda value: value.update(schema=True)),
            ("seed", lambda value: value.update(seed=2**53)),
            (
                "threads",
                lambda value: value["runs"][0]["tunables"].update(threads=65),
            ),
            (
                "operationsPerBatch",
                lambda value: value["runs"][0]["tunables"].update(
                    operationsPerBatch={"default": 5}
                ),
            ),
            ("qos", lambda value: value["runs"][0]["tunables"].update(qos="urgent")),
            ("maxAttempts", lambda value: value.update(maxAttempts=0)),
            ("smoke", lambda value: value.update(smoke="yes")),
            ("runs", lambda value: value.update(runs=[])),
        ]
        for key, mutate in cases:
            with self.subTest(key=key):
                invalid = deepcopy(document)
                mutate(invalid)
                with self.assertRaisesRegex(PlanError, key):
                    self.load_document(invalid)

    def test_priority_inversion_tunables(self):
        document = json.loads(SMOKE_PLAN.read_text())
        valid = {
            "holderWorkIterations": "fromCalibration",
            "loadQoS": "userInteractive",
            "loadMilliseconds": 5,
            "mainDelayMicroseconds": 0,
            "pauseMilliseconds": 0,
            "warmupTrials": 0,
            "trials": 1,
        }
        document["shuffle"] = False
        document["runs"][0]["tunables"]["priorityInversion"] = valid
        plan = self.load_document(document)
        self.assertEqual(
            plan.runs[0].tunables["priorityInversion"]["holderWorkIterations"],
            "fromCalibration",
        )
        valid["holderWorkIterations"] = 1000
        self.load_document(document)

        cases = (
            ("holderWorkIterations", 0),
            ("holderWorkIterations", "later"),
            ("holderWorkIterations", True),
            ("loadQoS", "urgent"),
            ("loadMilliseconds", 0),
            ("mainDelayMicroseconds", -1),
            ("pauseMilliseconds", -1),
            ("warmupTrials", -1),
            ("trials", 0),
        )
        for key, value in cases:
            with self.subTest(key=key, value=value):
                invalid = deepcopy(document)
                invalid["runs"][0]["tunables"]["priorityInversion"][key] = value
                with self.assertRaisesRegex(PlanError, key):
                    self.load_document(invalid)

    def test_ios_builds_and_traced_are_loaded(self):
        document = json.loads(SMOKE_PLAN.read_text())
        document.update(smoke=False, iosBuilds={"phone-a": "24A1", "phone-b": "24B2"})
        plan = self.load_document(document)
        self.assertEqual(plan.ios_builds, {"phone-a": "24A1", "phone-b": "24B2"})
        self.assertFalse(plan.traced)

    def test_missing_ios_builds_defaults_to_empty_in_smoke_plans_only(self):
        document = json.loads(SMOKE_PLAN.read_text())
        document.pop("iosBuilds")
        self.assertEqual(self.load_document(document).ios_builds, {})
        document["smoke"] = False
        with self.assertRaisesRegex(PlanError, "iosBuilds"):
            self.load_document(document)

    def test_traced_is_copied_into_requests_only_when_true(self):
        document = json.loads(SMOKE_PLAN.read_text())
        untraced = self.load_document(document)
        self.assertNotIn("traced", make_request(untraced.runs[0], "attempt-id", 1))

        document["traced"] = False
        untraced = self.load_document(document)
        self.assertNotIn("traced", make_request(untraced.runs[0], "attempt-id", 1))

        document["traced"] = True
        traced = self.load_document(document)
        self.assertTrue(traced.traced)
        self.assertIs(make_request(traced.runs[0], "attempt-id", 1)["traced"], True)

        document["traced"] = "yes"
        with self.assertRaisesRegex(PlanError, "traced"):
            self.load_document(document)

    def test_ids_reject_traversal_and_overlong_attempts(self):
        for name in ("../escape", "..", "/absolute", "bad/name", ""):
            with self.subTest(name=name), self.assertRaises(PlanError):
                make_run_id(name, "entry", 1)
        with self.assertRaises(PlanError):
            make_attempt_id("a" * 128, 1, datetime.now(timezone.utc), "abcd")
        with self.assertRaises(PlanError):
            make_request(load_plan(SMOKE_PLAN).runs[0], "../escape", 1)
