from __future__ import annotations

import json
import unittest
from copy import deepcopy

from runner.expected_attempt import ExpectedSamples, expected_attempt

from tests.synthetic_attempts import GOLDEN


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


if __name__ == "__main__":
    unittest.main()
