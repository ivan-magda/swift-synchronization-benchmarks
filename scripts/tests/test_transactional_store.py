from __future__ import annotations

from copy import deepcopy
from pathlib import Path
import tempfile
import unittest

from runner.attempt_check import check_attempt
from runner.expected_attempt import ExpectedSamples, expected_attempt
from runner.plans import load_plan
from tests.synthetic_attempts import (
    make_attempt_lines,
    transactional_store_request,
    write_attempt,
)


class TransactionalStoreTests(unittest.TestCase):
    def test_exact_measured_read_and_write_samples_for_every_worker(self):
        expected = expected_attempt(transactional_store_request(), cpu_count=6)
        self.assertEqual(len(expected.blocks), 26)
        for block in expected.blocks.values():
            self.assertEqual((block.threads, block.batch_lines), (6, 18))
            self.assertEqual(block.check, "transactionalStore." + block.operation)
            reads = (
                ("hundredReadsTime", 98)
                if block.operation == "singleRecord"
                else ("readTime", 9800)
            )
            self.assertEqual(
                block.samples,
                (
                    ExpectedSamples(reads[0], "ticks", True, 6, reads[1], False),
                    ExpectedSamples("writeTime", "ticks", True, 6, 200, False),
                ),
            )

    def test_checker_rejects_each_missing_metric_and_warmup_samples(self):
        request = transactional_store_request()
        lines = make_attempt_lines(request, "test")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            result, marker = write_attempt(path, lines)
            self.assertTrue(check_attempt(result, marker, request, "test").accepted)
            for metric in ("hundredReadsTime", "readTime", "writeTime"):
                for extra in (False, True):
                    with self.subTest(metric=metric, extra=extra):
                        broken = deepcopy(lines)
                        sample = next(
                            line for line in broken if line.get("metric") == metric
                        )
                        if extra:
                            sample["values"].append(3)
                        else:
                            sample["values"].pop()
                        result, marker = write_attempt(path, broken)
                        self.assertFalse(
                            check_attempt(result, marker, request, "test").accepted
                        )

    def test_rejects_incomplete_write_ratio_and_unsupported_rows(self):
        for field, value in (
            ("variant", "elsewhere"),
            ("mechanisms", ["atomic"]),
            ("operations", ["read"]),
            ("threads", 4),
            ("operationsPerBatch", {"default": 4999}),
        ):
            with self.subTest(field=field):
                request = transactional_store_request()
                target = (
                    request["tunables"]
                    if field in ("threads", "operationsPerBatch")
                    else request
                )
                target[field] = value
                with self.assertRaises(ValueError):
                    expected_attempt(request, cpu_count=6)

    def test_acceptance_plan_carries_both_transaction_sizes(self):
        path = (
            Path(__file__).resolve().parents[2]
            / "plans/acceptance-transactional-store.json"
        )
        plan = load_plan(path)
        self.assertEqual(len(plan.runs), 1)
        run = plan.runs[0]
        self.assertEqual(run.experiment, "transactionalStore")
        self.assertEqual(run.operations, ("singleRecord", "twentyRecords"))
        self.assertEqual(len(run.mechanisms), 13)
        self.assertEqual(run.tunables["threads"], 6)
