from __future__ import annotations

from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from runner.plans import load_plan
from runner.run_state import RunState, StateError, state_path

PLANS = Path(__file__).resolve().parents[2] / "plans"


class RunStateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.plan = load_plan(PLANS / "smoke-base-comparison.json")
        self.path = Path(self.directory.name) / "state" / "plan.json"

    def test_pending_runs(self):
        state = RunState.load_or_create(self.path, self.plan)
        first, second = self.plan.runs
        for _ in range(3):
            state.record_attempt(first.run_id, {
                "status": "refused", "reasonCode": "thermal", "accepted": False,
            })
        self.assertEqual(state.pending_runs(), list(self.plan.runs))
        state.record_attempt(first.run_id, {"status": "completed", "accepted": True})
        for _ in range(3):
            state.record_attempt(second.run_id, {"status": "crashed", "accepted": False})
        self.assertEqual(state.pending_runs(), [])

    def test_state_survives_reload_and_attempts_are_not_mutable_aliases(self):
        state = RunState.load_or_create(self.path, self.plan)
        run_id = self.plan.runs[0].run_id
        attempt = {
            "status": "completed", "accepted": True, "files": ["phone/session/attempt.jsonl"],
        }
        state.record_attempt(run_id, attempt)
        attempt["accepted"] = False
        reloaded = RunState.load_or_create(self.path, self.plan)
        self.assertEqual(reloaded.attempts(run_id), [{
            "status": "completed", "accepted": True, "files": ["phone/session/attempt.jsonl"],
        }])
        returned = reloaded.attempts(run_id)
        returned[0]["accepted"] = False
        self.assertEqual(reloaded.pending_runs(), [self.plan.runs[1]])

    def test_corrupt_or_mismatched_state_is_not_reset(self):
        self.path.parent.mkdir()
        for text in ("broken", "{}", "[]"):
            self.path.write_text(text)
            with self.subTest(text=text), self.assertRaises(StateError):
                RunState.load_or_create(self.path, self.plan)
            self.assertEqual(self.path.read_text(), text)
        self.path.unlink()
        state = RunState.load_or_create(self.path, self.plan)
        state.save()
        with self.assertRaises(StateError):
            RunState.load_or_create(self.path, load_plan(PLANS / "crash-and-hang.json"))

    def test_failed_atomic_save_preserves_previous_progress(self):
        state = RunState.load_or_create(self.path, self.plan)
        first, second = self.plan.runs
        state.record_attempt(first.run_id, {"accepted": True})
        previous = self.path.read_bytes()
        # Control the filesystem failure; serialization and temporary writes stay real.
        with patch("runner.run_state.os.replace", side_effect=OSError("disk failure")):
            with self.assertRaises(OSError):
                state.record_attempt(second.run_id, {"accepted": True})
        self.assertEqual(self.path.read_bytes(), previous)
        self.assertEqual(state.pending_runs(), [second])
        self.assertEqual(RunState.load_or_create(self.path, self.plan).pending_runs(), [second])

    def test_state_path_is_safe_and_code_hash_separates_builds(self):
        results = Path(self.directory.name)
        first = state_path(results, self.plan, "phone", "a" * 64)
        self.assertEqual(first.parent, results / "state")
        self.assertTrue(first.name.endswith("--aaaaaaaa.json"))
        self.assertNotEqual(first, state_path(results, self.plan, "phone", "b" * 64))
        for phone, code_hash in (
            ("../escape", "a" * 64), ("..", "a" * 64), ("phone", "../escape"),
        ):
            with self.subTest(phone=phone), self.assertRaises(StateError):
                state_path(results, self.plan, phone, code_hash)

    def test_unknown_run_is_not_silently_recorded(self):
        state = RunState.load_or_create(self.path, self.plan)
        with self.assertRaises(StateError):
            state.record_attempt("unknown", {"accepted": True})
