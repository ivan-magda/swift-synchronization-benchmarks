from __future__ import annotations

import json
import unittest
from copy import deepcopy

import re
from pathlib import Path

from runner.expected_attempt import (
    ASYNC_CODE_ROWS,
    GROUP_SIZE,
    MANY_TASKS,
    ExpectedSamples,
    expected_attempt,
)

from tests.synthetic_attempts import (
    CALLER_PATHS_MECHANISMS,
    CALLER_PATHS_OPERATIONS,
    GOLDEN,
    async_code_request,
)

ASYNC_CODE_SWIFT = (
    Path(__file__).resolve().parents[2] / "Experiments/AsyncCode/AsyncCode.swift"
)


def golden_request():
    """The reviewed golden request: baseComparison, oneThread, mutex x increment."""
    return json.loads(GOLDEN.read_text().splitlines()[0])["request"]


def calibration_request(repeats):
    request = deepcopy(golden_request())
    request.update(
        experiment="calibration", variant="default", mechanisms=[], operations=[]
    )
    request["tunables"]["repeats"] = repeats
    return request


class ExpectedAttemptTests(unittest.TestCase):
    def test_base_comparison_blocks_carry_threads_qos_and_check(self):
        request = golden_request()
        expected = expected_attempt(request, cpu_count=6)
        block = expected.blocks[("mutex", "increment")]
        self.assertEqual(block.threads, 1)
        self.assertEqual(block.qos, "userInitiated")
        self.assertEqual(block.operations_per_batch, 4)
        self.assertEqual(block.batch_lines, 1 * (1 + 2))
        self.assertEqual(block.samples, ())
        self.assertEqual(block.trial_lines, 0)
        self.assertEqual(block.check, "baseComparison.increment")

    def test_calibration_blocks_keep_their_thread_and_sample_rules(self):
        expected = expected_attempt(calibration_request(repeats=200), cpu_count=6)
        single = expected.blocks[("clockSingleThread", "")]
        self.assertEqual(
            (single.threads, single.qos, single.batch_lines), (1, "userInteractive", 0)
        )
        self.assertEqual(
            single.samples,
            (ExpectedSamples("clockRead1000", "ticks", True, 1, 200, False),),
        )
        background = expected.blocks[("cpuSpeedBackground", "")]
        self.assertEqual((background.threads, background.qos), (6, "background"))
        self.assertEqual(
            background.samples,
            (ExpectedSamples("referenceLoop", "ticks", True, 6, 200, True),),
        )
        self.assertEqual(single.check, "calibration.samples")
        holder = expected.blocks[("holderWorkSingleThread", "")]
        self.assertEqual(
            (holder.threads, holder.qos, holder.batch_lines, holder.check),
            (1, "userInteractive", 0, "calibration.samples"),
        )
        self.assertEqual(
            holder.samples,
            (ExpectedSamples("holderWork", "ticks", True, 1, 200, True),),
        )
        self.assertEqual(len(expected.blocks), 6)

    def test_caller_paths_expect_the_fourteen_allowed_blocks(self):
        request = async_code_request(
            "callerPaths", CALLER_PATHS_MECHANISMS, CALLER_PATHS_OPERATIONS
        )
        expected = expected_attempt(request, cpu_count=6)
        self.assertEqual(len(expected.blocks), 14)
        self.assertNotIn(("mainActor", "fromMainActor"), expected.blocks)
        self.assertNotIn(("mutex", "onActor"), expected.blocks)

        many = expected.blocks[("mutex", "fromManyTasks")]
        self.assertEqual(
            (many.threads, many.qos, many.batch_lines, many.check),
            (50, "userInitiated", 0, "asyncCode.fromManyTasks"),
        )
        self.assertEqual(
            many.samples, (ExpectedSamples("callTime", "ticks", True, 50, 3, False),)
        )

        main = expected.blocks[("nsLock", "fromMainActor")]
        self.assertEqual((main.threads, main.batch_lines), (1, 1 * (2 + 2)))
        self.assertEqual(
            main.samples,
            (
                ExpectedSamples(
                    "mainThreadCPUAtBatchStart", "microseconds", False, 1, 4, False
                ),
                ExpectedSamples(
                    "mainThreadCPUAtBatchEnd", "microseconds", False, 1, 4, False
                ),
            ),
        )
        self.assertEqual(
            expected.blocks[("mainActor", "toMainActor")].samples, main.samples
        )
        self.assertEqual(expected.blocks[("actor", "onActor")].samples, ())
        self.assertEqual(
            expected.blocks[("actor", "fromBackgroundTask")].samples, ()
        )
        self.assertEqual((expected.warmup_batches, expected.measured_batches), (2, 2))

    def test_batching_and_isolation_settings_blocks(self):
        batching = expected_attempt(
            async_code_request(
                "batching",
                ["actor", "mutex"],
                ["oneAwaitPerGroup", "awaitPerOperation", "oneLockPerGroup"],
            ),
            cpu_count=6,
        )
        self.assertEqual(
            set(batching.blocks),
            {
                ("actor", "oneAwaitPerGroup"),
                ("actor", "awaitPerOperation"),
                ("mutex", "oneLockPerGroup"),
            },
        )
        self.assertEqual(batching.blocks[("mutex", "oneLockPerGroup")].samples, ())
        self.assertEqual(
            batching.blocks[("mutex", "oneLockPerGroup")].operations_per_batch, 200
        )
        isolation = expected_attempt(
            async_code_request(
                "isolationSettings",
                ["templateDefaults", "swift6Language", "concurrentAttribute"],
                ["callFromMainActor"],
            ),
            cpu_count=6,
        )
        self.assertEqual(len(isolation.blocks), 3)
        block = isolation.blocks[("swift6Language", "callFromMainActor")]
        self.assertEqual(
            (block.threads, block.check), (1, "asyncCode.callFromMainActor")
        )
        self.assertEqual(
            [group.metric for group in block.samples],
            ["mainThreadCPUAtBatchStart", "mainThreadCPUAtBatchEnd"],
        )

    def test_requests_that_no_allowed_pair_serves_raise(self):
        cases = {
            "no allowed pair": ("callerPaths", ["mainActor"], ["fromMainActor"]),
            "mechanism without a pair": (
                "callerPaths",
                ["actor", "mainActor"],
                ["onActor"],
            ),
            "operation without a pair": (
                "callerPaths",
                ["mutex"],
                ["onActor", "fromMainActor"],
            ),
            "unknown variant": ("elsewhere", ["actor"], ["onActor"]),
        }
        for name, (variant, mechanisms, operations) in cases.items():
            with self.subTest(name):
                request = async_code_request(variant, mechanisms, operations)
                with self.assertRaises(ValueError):
                    expected_attempt(request, cpu_count=6)

    def test_batching_values_must_hold_whole_groups_in_every_sub_batch(self):
        request = async_code_request("batching", ["mutex"], ["oneLockPerGroup"])
        request["tunables"]["operationsPerBatch"] = {"default": 2 * GROUP_SIZE + 2}
        with self.assertRaises(ValueError):
            expected_attempt(request, cpu_count=6)

    def test_many_tasks_without_async_code_tunables_raise(self):
        request = async_code_request("callerPaths", ["actor"], ["fromManyTasks"])
        del request["tunables"]["asyncCode"]
        with self.assertRaises(ValueError):
            expected_attempt(request, cpu_count=6)

    def test_table_and_constants_equal_the_swift_ones(self):
        source = ASYNC_CODE_SWIFT.read_text()
        table = re.search(r"static let rows[^=]*= \[(.*?)\n    \]\n", source, re.S)
        parsed = {}
        variant = None
        for line in table.group(1).splitlines():
            variant_match = re.match(r'\s{8}"(\w+)": \[$', line)
            row_match = re.match(r'\s{12}"(\w+)": \[(.*)\],$', line)
            if variant_match:
                variant = variant_match.group(1)
                parsed[variant] = {}
            elif row_match:
                parsed[variant][row_match.group(1)] = re.findall(
                    r'"(\w+)"', row_match.group(2)
                )
        self.assertEqual(parsed, ASYNC_CODE_ROWS)
        self.assertEqual(
            MANY_TASKS, int(re.search(r"manyTasks = (\d+)", source).group(1))
        )
        self.assertEqual(
            GROUP_SIZE, int(re.search(r"groupSize = (\d+)", source).group(1))
        )


if __name__ == "__main__":
    unittest.main()
