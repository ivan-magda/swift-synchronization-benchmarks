from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import tempfile
import unittest

from runner.attempt_check import check_attempt
from runner.expected_attempt import expected_attempt
from runner.plans import load_plan
from tests.synthetic_attempts import hot_flag_request, make_attempt_lines, write_attempt


def creation_cost_request():
    request = hot_flag_request()
    request.update(
        experiment="creationCost",
        operations=["create", "destroy"],
        mechanisms=[
            "unsynchronized",
            "mutex",
            "osAllocatedUnfairLock",
            "osUnfairLock",
            "nsLock",
            "nsRecursiveLock",
            "pthreadMutex",
            "pthreadReadWriteLock",
            "serialQueue",
            "barrierQueueSyncWrite",
            "dispatchSemaphore",
            "actor",
            "mainActor",
            "atomic",
            "managedAtomic",
        ],
    )
    return request


class CreationCostTests(unittest.TestCase):
    def test_block_level_malloc_samples_include_warmup_and_exclude_destroy(self):
        expected = expected_attempt(creation_cost_request(), cpu_count=6)
        self.assertEqual(len(expected.blocks), 30)
        for block in expected.blocks.values():
            self.assertEqual((block.threads, block.batch_lines), (1, 3))
            self.assertEqual(block.check, "creationCost." + block.operation)
            samples = block.samples
            if block.operation == "destroy":
                self.assertEqual(samples, ())
                continue
            self.assertEqual(
                {sample.metric for sample in samples},
                {
                    "mallocBlocksBeforeCreate",
                    "mallocBlocksAfterCreate",
                    "mallocBlocksAfterDestroy",
                    "mallocBytesBeforeCreate",
                    "mallocBytesAfterCreate",
                    "mallocBytesAfterDestroy",
                },
            )
            for sample in samples:
                self.assertEqual(
                    (
                        sample.per_thread,
                        sample.lines,
                        sample.values_per_line,
                        sample.cpu_readings,
                    ),
                    (False, 1, 3, False),
                )
                self.assertEqual(
                    sample.unit, "blocks" if "Blocks" in sample.metric else "bytes"
                )

    def test_checker_rejects_missing_or_extra_malloc_values(self):
        request = creation_cost_request()
        lines = make_attempt_lines(request, "test")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            result, marker = write_attempt(path, lines)
            self.assertTrue(check_attempt(result, marker, request, "test").accepted)
            samples = [line for line in lines if line.get("type") == "samples"]
            self.assertEqual(len(samples), 90)
            for metric in {line["metric"] for line in samples}:
                for mutation in ("remove", "extra", "thread", "unit"):
                    with self.subTest(metric=metric, mutation=mutation):
                        broken = deepcopy(lines)
                        sample = next(
                            line for line in broken if line.get("metric") == metric
                        )
                        if mutation == "remove":
                            broken.remove(sample)
                        elif mutation == "extra":
                            sample["values"].append(3)
                        elif mutation == "thread":
                            sample["thread"] = 0
                        else:
                            sample["unit"] = "ticks"
                        result, marker = write_attempt(path, broken)
                        self.assertFalse(
                            check_attempt(result, marker, request, "test").accepted
                        )

    def test_rejects_unsupported_selection_or_thread_count(self):
        for field, value in (
            ("variant", "other"),
            ("mechanisms", ["objcSync"]),
            ("mechanisms", ["mutex", "mutex"]),
            ("operations", ["read"]),
            ("threads", 2),
        ):
            with self.subTest(field=field):
                request = creation_cost_request()
                target = request["tunables"] if field == "threads" else request
                target[field] = value
                with self.assertRaises(ValueError):
                    expected_attempt(request, cpu_count=6)

    def test_acceptance_plan_carries_both_object_counts(self):
        plan = load_plan(
            Path(__file__).resolve().parents[2] / "plans/acceptance-creation-cost.json"
        )
        self.assertEqual(
            sorted(run.tunables["operationsPerBatch"]["default"] for run in plan.runs),
            [10000, 100000],
        )
        for run in plan.runs:
            self.assertEqual(run.experiment, "creationCost")
            self.assertEqual(run.operations, ("create", "destroy"))
            self.assertEqual(len(run.mechanisms), 15)
