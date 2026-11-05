from __future__ import annotations

import base64
from copy import deepcopy
from datetime import datetime, timezone
import json
from pathlib import Path
import tempfile
import unittest

from runner.plans import (
    PlanError, encode_request, load_plan, make_attempt_id, make_request,
    make_run_id, make_run_seed,
)

PLANS = Path(__file__).resolve().parents[2] / "plans"
SMOKE_PLAN = PLANS / "smoke-base-comparison.json"


class PlanTests(unittest.TestCase):
    def load_document(self, document):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "plan.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            return load_plan(path)

    def test_run_id_and_seed(self):
        run_id = make_run_id("smoke-base-comparison", "one-thread", 1)
        self.assertEqual(run_id, "smoke-base-comparison.one-thread.1")
        self.assertEqual(make_run_seed(20261105, run_id), 184828474630059)
        self.assertEqual(
            make_attempt_id(run_id, 1, datetime(2026, 11, 5, tzinfo=timezone.utc), "abcd"),
            "smoke-base-comparison.one-thread.1.attempt1.20261105T000000Z.abcd",
        )

    def test_request_keys_and_encoding(self):
        run = load_plan(SMOKE_PLAN).runs[0]
        attempt_id = make_attempt_id(
            run.run_id, 1, datetime(2026, 11, 5, tzinfo=timezone.utc), "abcd"
        )
        request = make_request(run, attempt_id, attempt=1)
        self.assertEqual(set(request), {
            "schema", "runID", "attemptID", "attempt", "experiment", "variant",
            "seed", "smoke", "mechanisms", "operations", "tunables",
        })
        encoded = base64.b64decode(encode_request(request)).decode("utf-8")
        self.assertEqual(json.loads(encoded), request)
        self.assertEqual(encoded, json.dumps(request, sort_keys=True, separators=(",", ":")))
        request["tunables"]["threads"] = 64
        self.assertNotEqual(run.tunables["threads"], 64)

    def test_smoke_plan_order_is_stable(self):
        for name in ("smoke-base-comparison.json", "smoke-base-comparison-ios18.json"):
            with self.subTest(name=name):
                plan = load_plan(PLANS / name)
                self.assertEqual(plan.runs, load_plan(PLANS / name).runs)
                self.assertEqual(len(plan.runs), 2)
                self.assertEqual({run.variant for run in plan.runs}, {"oneThread", "twoThreads"})
        document = json.loads(SMOKE_PLAN.read_text())
        document["seed"] = 0
        document["runs"] = document["runs"][:1]
        document["runs"][0]["repeats"] = 3
        # Random(0) shuffles positions 1, 2, 3 into 1, 3, 2 on both supported Pythons.
        self.assertEqual(
            [run.run_id for run in self.load_document(document).runs],
            ["smoke-base-comparison.one-thread.1", "smoke-base-comparison.one-thread.3",
             "smoke-base-comparison.one-thread.2"],
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

    def test_acceptance_plans_cover_all_four_thread_counts(self):
        for name in ("acceptance-base-comparison.json", "acceptance-base-comparison-ios18.json"):
            plan = load_plan(PLANS / name)
            self.assertTrue(plan.smoke)
            self.assertEqual({run.variant: run.tunables["threads"] for run in plan.runs}, {
                "oneThread": 1, "twoThreads": 2, "sixThreads": 6, "twelveThreads": 12,
            })
            for run in plan.runs:
                if plan.build_target == "ios18":
                    self.assertEqual(set(run.mechanisms), {
                        "mutex", "atomic", "atomicRelaxed", "managedAtomic", "managedAtomicRelaxed",
                    })
                else:
                    self.assertEqual(len(run.mechanisms), 20 if run.variant == "oneThread" else 19)
                    self.assertEqual(
                        "unsynchronized" in run.mechanisms, run.variant == "oneThread"
                    )

    def test_calibration_launches_once_with_200_samples_per_measurement(self):
        plan = load_plan(PLANS / "calibration.json")
        self.assertEqual(len(plan.runs), 1)
        request = make_request(plan.runs[0], "calibration-attempt", 1)
        self.assertEqual(request["tunables"]["repeats"], 200)
        self.assertEqual(
            (request["experiment"], request["variant"], request["mechanisms"], request["operations"]),
            ("calibration", "default", [], []),
        )

    def test_repeats_expand_in_file_order_with_distinct_seeds(self):
        document = json.loads(SMOKE_PLAN.read_text())
        document["runs"] = document["runs"][:1]
        document["runs"][0]["repeats"] = 2
        document["shuffle"] = False
        plan = self.load_document(document)
        self.assertEqual(
            [run.run_id for run in plan.runs],
            ["smoke-base-comparison.one-thread.1", "smoke-base-comparison.one-thread.2"],
        )
        self.assertNotEqual(plan.runs[0].seed, plan.runs[1].seed)

    def test_invalid_plans_name_the_key(self):
        document = json.loads(SMOKE_PLAN.read_text())
        cases = [
            ("buildTarget", lambda value: value.pop("buildTarget")),
            ("buildTarget", lambda value: value.update(buildTarget="ios17")),
            ("repeats", lambda value: value["runs"][0].update(repeats=0)),
            ("name", lambda value: value["runs"][1].update(name=value["runs"][0]["name"])),
            ("simulation", lambda value: (
                value.update(smoke=False, iosBuild="24A1"),
                value["runs"][0].update(simulation="crash"),
            )),
            ("iosBuild", lambda value: value.update(smoke=False)),
            ("schema", lambda value: value.update(schema=True)),
            ("seed", lambda value: value.update(seed=2 ** 53)),
            ("threads", lambda value: value["runs"][0]["tunables"].update(threads=65)),
            ("operationsPerBatch", lambda value: value["runs"][0]["tunables"].update(
                operationsPerBatch={"default": 5}
            )),
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

    def test_ids_reject_traversal_and_overlong_attempts(self):
        for name in ("../escape", "..", "/absolute", "bad/name", ""):
            with self.subTest(name=name), self.assertRaises(PlanError):
                make_run_id(name, "entry", 1)
        with self.assertRaises(PlanError):
            make_attempt_id("a" * 128, 1, datetime.now(timezone.utc), "abcd")
        with self.assertRaises(PlanError):
            make_request(load_plan(SMOKE_PLAN).runs[0], "../escape", 1)
