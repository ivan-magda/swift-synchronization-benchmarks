from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path

from dataclasses import replace
from unittest import mock

from runner.attempt_check import check_attempt
from runner.expected_attempt import expected_attempt

from tests.synthetic_attempts import (
    CALLER_PATHS_MECHANISMS,
    CALLER_PATHS_OPERATIONS,
    GOLDEN,
    async_code_request,
    hot_flag_request,
    request_registry_request,
    make_attempt_lines,
    priority_inversion_request,
    trial_line,
    write_attempt,
)

GOLDEN_LINES = [json.loads(line) for line in GOLDEN.read_text().splitlines()]
REQUEST = GOLDEN_LINES[0]["request"]
BUILD_ID = GOLDEN_LINES[0]["build"]["buildID"]


def with_trials(lines, count, warmup_trials):
    """Append trial lines to the end of every block group."""
    result = []
    current = None
    for index, line in enumerate(lines):
        result.append(line)
        if line["type"] == "block":
            current = line
        following = lines[index + 1]["type"] if index + 1 < len(lines) else None
        if current is not None and following in ("block", "reference"):
            result.extend(
                trial_line(current, number, warmup=number < warmup_trials)
                for number in range(count)
            )
            current = None
    return result


class AttemptCheckTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)

    def verdict(self, lines, request=None, expected_os_build=None):
        result, done = write_attempt(self.path, lines)
        return check_attempt(
            result,
            done,
            REQUEST if request is None else request,
            BUILD_ID,
            expected_os_build,
        )

    def assert_invalid(self, lines, request=None, reason=None, expected_os_build=None):
        verdict = self.verdict(lines, request, expected_os_build)
        self.assertEqual((verdict.status, verdict.accepted), ("invalid", False))
        self.assertTrue(verdict.reasons)
        if reason:
            self.assertIn(reason, " ".join(verdict.reasons))

    def test_request_registry_attempt_requires_each_sample_group(self):
        for variant in ("normal", "burst"):
            request = request_registry_request(variant)
            lines = make_attempt_lines(request, BUILD_ID)
            self.assertTrue(self.verdict(lines, request).accepted)
            for metric in ("callStart", "callTime", "cancelAllStart", "cancelAllTime"):
                with self.subTest(variant=variant, metric=metric):
                    broken = deepcopy(lines)
                    sample = next(line for line in broken if line.get("metric") == metric)
                    sample["values"].pop()
                    self.assert_invalid(broken, request)
            broken_request = deepcopy(request)
            broken_request["tunables"]["requestRegistry"]["workIterations"] = 0
            self.assert_invalid(make_attempt_lines(broken_request, BUILD_ID), broken_request)

    def test_golden_file_is_accepted(self):
        result, marker = write_attempt(self.path, GOLDEN_LINES)
        result.write_bytes(GOLDEN.read_bytes())

        # The writer fixture itself, rather than reserialized Python output, is the contract.
        document = json.loads(marker.read_text())
        document.update(
            bytes=len(result.read_bytes()),
            sha256=hashlib.sha256(result.read_bytes()).hexdigest(),
        )
        marker.write_text(json.dumps(document))
        self.assertEqual(
            check_attempt(result, marker, REQUEST, BUILD_ID).accepted, True
        )

    def test_missing_done_is_incomplete(self):
        result, marker = write_attempt(self.path, GOLDEN_LINES)
        marker.unlink()
        for done in (None, marker):
            verdict = check_attempt(result, done, REQUEST, BUILD_ID)
            self.assertEqual((verdict.status, verdict.accepted), ("incomplete", False))

    def test_done_mismatches_are_invalid(self):
        for key, value in (
            ("sha256", "0" * 64),
            ("attemptID", "another-attempt"),
            ("bytes", 1),
            ("file", "another.jsonl"),
        ):
            with self.subTest(key=key):
                result, marker = write_attempt(self.path, GOLDEN_LINES)
                document = json.loads(marker.read_text())
                document[key] = value
                marker.write_text(json.dumps(document))
                self.assertEqual(
                    check_attempt(result, marker, REQUEST, BUILD_ID).status, "invalid"
                )


    def test_wrong_identity_or_incomplete_work_is_rejected(self):
        # Each mutation would otherwise allow incomparable or incomplete measurements.
        cases = (
            ("build", lambda lines: lines[0]["build"].update(buildID="other-build")),
            ("seed", lambda lines: lines[0]["request"].update(seed=8)),
            ("missing batch", lambda lines: lines.pop(4)),
            ("duplicate batch", lambda lines: lines.__setitem__(5, deepcopy(lines[4]))),
            ("operations", lambda lines: lines[4].update(operations=5)),
            ("missing checks", lambda lines: lines[-1].update(checks=[])),
            ("missing end", lambda lines: lines.pop()),
        )
        for name, mutate in cases:
            with self.subTest(case=name):
                lines = deepcopy(GOLDEN_LINES)
                mutate(lines)
                self.assert_invalid(lines)

    def test_phone_ios_build_must_match_the_plan(self):
        os_build = GOLDEN_LINES[0]["phone"]["osBuild"]
        self.assertTrue(self.verdict(GOLDEN_LINES, expected_os_build=os_build).accepted)
        self.assertTrue(self.verdict(GOLDEN_LINES).accepted)
        self.assert_invalid(
            GOLDEN_LINES,
            reason="phone iOS build differs from the plan",
            expected_os_build=os_build + "-other",
        )

    def test_trial_line_in_a_block_that_expects_none_is_invalid(self):
        lines = deepcopy(GOLDEN_LINES)
        last_batch = max(
            index for index, line in enumerate(lines) if line["type"] == "batch"
        )
        block = next(line for line in lines if line["type"] == "block")
        lines.insert(last_batch + 1, trial_line(block, 0, warmup=False))
        self.assert_invalid(lines)

    def test_substituted_block_is_invalid(self):
        request = deepcopy(REQUEST)
        request["mechanisms"] = ["mutex", "nsLock"]
        lines = make_attempt_lines(request, BUILD_ID)
        blocks = [line for line in lines if line["type"] == "block"]
        blocks[1]["mechanism"] = "mutex"
        self.assert_invalid(lines, request)


    def test_check_failures_and_wrong_ownership_are_invalid(self):
        for replacement in (
            {"violations": 1},
            {"passed": False},
            {"block": 1},
            {"name": "baseComparison.read"},
        ):
            with self.subTest(replacement=replacement):
                lines = deepcopy(GOLDEN_LINES)
                lines[-1]["checks"][0].update(replacement)
                self.assert_invalid(lines)

    def test_thermal_refusal_and_failed_run_are_classified(self):
        for status, reason in (
            ("refused", "thermal"),
            ("failed", "check"),
            ("failed", "invalidRequest"),
        ):
            with self.subTest(status=status, reason=reason):
                verdict = self.verdict(
                    make_attempt_lines(REQUEST, BUILD_ID, status, reason)
                )
                self.assertEqual(
                    (verdict.status, verdict.accepted, verdict.reason_code),
                    (status, False, reason),
                )


    def test_bad_conditions_rejected_outside_smoke(self):
        request = deepcopy(REQUEST)
        request["smoke"] = False
        for endpoint in (0, -1):
            for key, value in (
                ("thermalState", "fair"),
                ("applicationState", "background"),
                ("debuggerAttached", True),
                ("lowPowerMode", True),
                ("batteryState", "unplugged"),
                ("environment", {"PTHREAD_MUTEX_POLICY": "firstfit"}),
            ):
                with self.subTest(endpoint=endpoint, key=key):
                    lines = make_attempt_lines(request, BUILD_ID)
                    lines[endpoint]["conditions"][key] = value
                    self.assert_invalid(lines, request, "conditions")

    def test_unavailable_hardware_facts_are_still_valid(self):
        # PhoneFacts uses -1 when signed hardware count/size queries are unavailable.
        lines = deepcopy(GOLDEN_LINES)
        lines[0]["phone"]["cacheLineBytes"] = -1
        lines[0]["phone"]["performanceLevels"][0]["l1DataCacheBytes"] = -1
        self.assertTrue(self.verdict(lines).accepted)


    def test_nonobject_and_broken_json_lines_are_invalid(self):
        for value in (None, [], 1, "run"):
            with self.subTest(value=value):
                lines = deepcopy(GOLDEN_LINES)
                lines[1] = value
                self.assert_invalid(lines)

        for raw in (b"{broken JSON}\n", b"\n", b'{"type":"run","schema":NaN}\n'):
            with self.subTest(raw=raw):
                result, done = write_attempt(self.path, GOLDEN_LINES)
                result.write_bytes(raw)
                marker = json.loads(done.read_text())
                marker.update(bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest())
                done.write_text(json.dumps(marker))
                self.assertEqual(
                    check_attempt(result, done, REQUEST, BUILD_ID).status, "invalid"
                )

    def test_smoke_allows_unfavorable_conditions(self):
        lines = deepcopy(GOLDEN_LINES)
        lines[-1]["conditions"]["thermalState"] = "fair"
        self.assertTrue(self.verdict(lines).accepted)

    def test_line_grouping_reference_and_block_positions(self):
        def swap(lines, first, second):
            lines[first], lines[second] = lines[second], lines[first]

        mutations = [
            lambda lines: swap(lines, 1, 2),
            lambda lines: swap(lines, 4, 5),
            lambda lines: lines[-2].update(when="start"),
            lambda lines: lines[2].update(block=2),
            lambda lines: lines.insert(2, deepcopy(lines[0])),
            lambda lines: lines.insert(-1, {"type": "mystery"}),
            lambda lines: lines[-1].update(status="timeout"),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutations.index(mutate)):
                lines = deepcopy(GOLDEN_LINES)
                mutate(lines)
                self.assert_invalid(lines)

    def test_timestamp_containment_and_cpu_lengths(self):
        mutations = [
            (2, {"end": 130}),
            (4, {"start": 129}),
            (4, {"end": 201}),
            (4, {"end": 159}),
            (4, {"end": 160}),  # Equality is a zero-duration batch.
            (1, {"start": 99}),
            (-2, {"end": 231}),
            (4, {"cpuReadings": [0, 0]}),
            (1, {"cpuReadings": [0]}),
            (4, {"executorCPUReadings": [0]}),
        ]
        for index, replacement in mutations:
            with self.subTest(index=index, replacement=replacement):
                lines = deepcopy(GOLDEN_LINES)
                lines[index].update(replacement)
                self.assert_invalid(lines)


    def test_calibration_counts(self):
        request = deepcopy(REQUEST)
        request.update(
            experiment="calibration", variant="default", mechanisms=[], operations=[]
        )
        request["tunables"]["repeats"] = 3
        lines = make_attempt_lines(request, BUILD_ID, cpu_count=2)
        # Five blocks and 2 + 3*2 = 8 sample lines, each with three raw values.
        self.assertTrue(self.verdict(lines, request).accepted)
        samples = [
            index for index, line in enumerate(lines) if line["type"] == "samples"
        ]
        mutations = [
            lambda broken: broken.pop(samples[0]),
            lambda broken: broken[samples[1]].update(block=0),
            lambda broken: broken[samples[2]].update(thread=0),
            lambda broken: broken[samples[0]].update(metric="referenceLoop"),
            lambda broken: broken[samples[0]].update(values=[3, 3]),
            lambda broken: broken[samples[-1]].update(cpuAtEnd=[0]),
            lambda broken: broken[-1]["checks"].pop(),
            lambda broken: broken[-1]["checks"][1].update(block=0),
            lambda broken: broken[-1]["checks"][0].pop("block"),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutations.index(mutate)):
                broken = deepcopy(lines)
                mutate(broken)
                self.assert_invalid(broken, request)

    def test_multithread_batches_and_mechanism_specific_counts(self):
        request = deepcopy(REQUEST)
        request.update(
            variant="twoThreads",
            mechanisms=["mutex", "nsLock"],
            operations=["read", "increment"],
        )
        request["tunables"].update(
            threads=2, operationsPerBatch={"default": 4, "nsLock": 8}
        )
        lines = make_attempt_lines(request, BUILD_ID)
        self.assertTrue(self.verdict(lines, request).accepted)
        for key, value in (("thread", 2), ("batch", 3), ("warmup", False)):
            with self.subTest(key=key):
                broken = deepcopy(lines)
                broken[3][key] = value
                self.assert_invalid(broken, request)

    def test_check_cli_prints_verdict_and_returns_failure_for_rejection(self):
        result, marker = write_attempt(self.path, GOLDEN_LINES)
        request_path = self.path / "request.json"
        request_path.write_text(json.dumps(REQUEST))
        command = [
            sys.executable,
            str(Path(__file__).resolve().parents[1] / "bench.py"),
            "check",
            str(result),
            "--request",
            str(request_path),
            "--build-id",
            BUILD_ID,
        ]
        accepted = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertTrue(json.loads(accepted.stdout)["accepted"])

        marker.unlink()
        rejected = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(rejected.returncode, 1, rejected.stderr)
        self.assertEqual(json.loads(rejected.stdout)["status"], "incomplete")

    def caller_paths(self):
        return async_code_request(
            "callerPaths", CALLER_PATHS_MECHANISMS, CALLER_PATHS_OPERATIONS
        )

    def first_sample(self, lines, metric, operation):
        """Index of the first samples line of a metric inside the blocks of an operation."""
        blocks = {
            line["block"]
            for line in lines
            if line["type"] == "block" and line["operation"] == operation
        }
        return next(
            index
            for index, line in enumerate(lines)
            if line["type"] == "samples"
            and line["metric"] == metric
            and line["block"] in blocks
        )

    def accepted_lines(self, request):
        lines = make_attempt_lines(request, BUILD_ID)
        self.assertTrue(self.verdict(lines, request).accepted)
        return lines

    def test_hot_flag_attempt_requires_its_read_group_samples(self):
        request = hot_flag_request()
        lines = self.accepted_lines(request)
        self.assertEqual(sum(line["type"] == "block" for line in lines), 34)
        lines.pop(self.first_sample(lines, "readGroupTime", "readGroups"))
        self.assert_invalid(lines, request)

    def test_caller_paths_acceptance_request_is_accepted_with_fourteen_blocks(self):
        request = self.caller_paths()
        self.assertEqual(
            len(request["mechanisms"]) * len(request["operations"]), 25
        )
        lines = self.accepted_lines(request)
        self.assertEqual(sum(line["type"] == "block" for line in lines), 14)
        many_tasks = [
            line
            for line in lines
            if line["type"] == "samples" and line["metric"] == "callTime"
        ]
        # Four mechanisms, 50 tasks each.
        self.assertEqual(len(many_tasks), 4 * 50)

    def test_batching_and_isolation_settings_attempts_are_accepted(self):
        for variant, mechanisms, operations in (
            (
                "batching",
                ["actor", "mutex"],
                ["oneAwaitPerGroup", "awaitPerOperation", "oneLockPerGroup"],
            ),
            (
                "isolationSettings",
                ["templateDefaults", "swift6Language", "concurrentAttribute"],
                ["callFromMainActor"],
            ),
        ):
            with self.subTest(variant):
                self.accepted_lines(async_code_request(variant, mechanisms, operations))

    def test_malformed_async_code_files_are_invalid(self):
        request = self.caller_paths()
        lines = self.accepted_lines(request)

        def drop_call_time_line(copy):
            copy.pop(self.first_sample(copy, "callTime", "fromManyTasks"))

        def drop_call_time_value(copy):
            copy[self.first_sample(copy, "callTime", "fromManyTasks")]["values"].pop()

        def drop_main_thread_end_line(copy):
            copy.pop(
                self.first_sample(copy, "mainThreadCPUAtBatchEnd", "fromMainActor")
            )

        def add_batch_line_to_many_tasks(copy):
            block = next(
                line
                for line in copy
                if line["type"] == "block" and line["operation"] == "fromManyTasks"
            )
            batch = next(line for line in copy if line["type"] == "batch")
            extra = deepcopy(batch)
            extra.update(
                block=block["block"], start=block["start"], end=block["start"] + 1
            )
            copy.insert(copy.index(block) + 1, extra)

        def add_thread_to_main_thread_line(copy):
            copy[
                self.first_sample(copy, "mainThreadCPUAtBatchStart", "toMainActor")
            ]["thread"] = 0

        for name, mutate in {
            "49 tasks": drop_call_time_line,
            "one value too few": drop_call_time_value,
            "end line removed": drop_main_thread_end_line,
            "batch line in fromManyTasks": add_batch_line_to_many_tasks,
            "thread on a block line": add_thread_to_main_thread_line,
        }.items():
            with self.subTest(name):
                copy = deepcopy(lines)
                mutate(copy)
                self.assert_invalid(copy, request)

    def test_a_request_without_an_allowed_pair_is_invalid(self):
        request = async_code_request("callerPaths", ["mainActor"], ["fromMainActor"])
        # The file is well formed for a neighboring request; the expectation fails first.
        lines = make_attempt_lines(
            async_code_request("callerPaths", ["actor"], ["fromMainActor"]), BUILD_ID
        )
        lines[0]["request"] = request
        self.assert_invalid(lines, request)

    def test_priority_inversion_attempt_with_both_holders_is_accepted(self):
        request = priority_inversion_request()
        lines = self.accepted_lines(request)
        self.assertEqual(sum(line["type"] == "block" for line in lines), 4)
        self.assertEqual(sum(line["type"] == "trial" for line in lines), 12)

        # Censored and invalid overlap are recorded observations, not correctness failures.
        trials = [line for line in lines if line["type"] == "trial"]
        trials[0].update(loadStop=trials[0]["mainAcquire"] - 1, outcome="censored")
        trials[1].update(mainArrival=trials[1]["holderAcquire"], outcome="invalid")
        self.assertTrue(self.verdict(lines, request).accepted)

        request["mechanisms"] = [
            "mutex", "osAllocatedUnfairLock", "osAllocatedUnfairLockAdaptiveSpin",
            "osUnfairLock", "nsLock", "nsRecursiveLock", "pthreadMutex",
            "pthreadReadWriteLock", "serialQueue", "barrierQueueSyncWrite",
            "barrierQueueAsyncWrite", "dispatchSemaphore", "actor", "objcSync",
        ]
        self.accepted_lines(request)

    def test_malformed_priority_inversion_attempts_are_invalid(self):
        request = priority_inversion_request()
        lines = self.accepted_lines(request)
        trial_index = next(
            index for index, line in enumerate(lines) if line["type"] == "trial"
        )
        mutations = {
            "missing trial": lambda copy: copy.pop(trial_index),
            "outcome": lambda copy: copy[trial_index].update(outcome="censored"),
            "acquire before release": lambda copy: copy[trial_index].update(
                mainAcquire=copy[trial_index]["holderRelease"] - 1
            ),
            "wrong result": lambda copy: copy[trial_index].update(
                holderResultCorrect=False
            ),
            "holder QoS": lambda copy: copy[trial_index].update(holderQoS="background"),
            "outside block": lambda copy: copy[trial_index].update(loadStart=1),
            "warmup": lambda copy: copy[trial_index].update(warmup=False),
            "wrong check": lambda copy: copy[-1]["checks"][0].update(
                name="baseComparison.utilityHolder"
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(name):
                broken = deepcopy(lines)
                mutate(broken)
                self.assert_invalid(broken, request)

    def test_priority_inversion_rejects_invalid_requests(self):
        request = priority_inversion_request()
        lines = make_attempt_lines(request, BUILD_ID)
        mutations = {
            "unknown mechanism": (
                "mechanisms", lambda copy: copy.update(mechanisms=["unknown"])
            ),
            "empty mechanisms": (
                "mechanisms", lambda copy: copy.update(mechanisms=[])
            ),
            "duplicate mechanisms": (
                "mechanisms", lambda copy: copy.update(mechanisms=["nsLock", "nsLock"])
            ),
            "unknown operation": (
                "operations", lambda copy: copy.update(operations=["unknown"])
            ),
            "empty operations": (
                "operations", lambda copy: copy.update(operations=[])
            ),
            "duplicate operations": (
                "operations",
                lambda copy: copy.update(operations=["utilityHolder", "utilityHolder"]),
            ),
            "variant": ("variant", lambda copy: copy.update(variant="unknown")),
            "threads": (
                "tunables.threads", lambda copy: copy["tunables"].update(threads=2)
            ),
            "missing tunables": (
                "tunables.priorityInversion",
                lambda copy: copy["tunables"].pop("priorityInversion"),
            ),
        }
        for name, (field, mutate) in mutations.items():
            with self.subTest(name):
                broken_request = deepcopy(request)
                mutate(broken_request)
                broken = deepcopy(lines)
                broken[0]["request"] = broken_request
                # A malformed request must fail before inspecting its otherwise valid blocks.
                self.assert_invalid(broken, broken_request, reason="request." + field)


class TrialLineTests(unittest.TestCase):
    """Exercise the shared trial parser alongside batch lines via a patched expectation."""

    TRIALS = 3
    WARMUP_TRIALS = 1

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.request = deepcopy(REQUEST)
        self.request["tunables"]["priorityInversion"] = {
            "holderWorkIterations": 1000,
            "loadQoS": "userInteractive",
            "loadMilliseconds": 5,
            "mainDelayMicroseconds": 0,
            "pauseMilliseconds": 0,
            "warmupTrials": self.WARMUP_TRIALS,
            "trials": self.TRIALS - self.WARMUP_TRIALS,
        }

    def expecting_trials(self, request, cpu_count):
        expected = expected_attempt(request, cpu_count)
        blocks = {
            key: replace(block, trial_lines=self.TRIALS)
            for key, block in expected.blocks.items()
        }
        return replace(expected, blocks=blocks)

    def lines(self):
        base = make_attempt_lines(self.request, BUILD_ID)
        return with_trials(base, self.TRIALS, self.WARMUP_TRIALS)

    def verdict(self, lines):
        result, done = write_attempt(self.path, lines)
        with mock.patch(
            "runner.attempt_check.expected_attempt", self.expecting_trials
        ):
            return check_attempt(result, done, self.request, BUILD_ID)

    def trial_indexes(self, lines):
        return [index for index, line in enumerate(lines) if line["type"] == "trial"]

    def test_well_formed_trials_are_accepted(self):
        self.assertTrue(self.verdict(self.lines()).accepted)

    def test_a_missing_or_extra_trial_is_invalid(self):
        lines = self.lines()
        missing = deepcopy(lines)
        missing.pop(self.trial_indexes(missing)[-1])
        extra = deepcopy(lines)
        index = self.trial_indexes(extra)[-1]
        block = extra[index]["block"]
        blocks = [line for line in extra if line["type"] == "block"]
        extra.insert(index + 1, trial_line(blocks[block], self.TRIALS))
        for broken in (missing, extra):
            self.assertEqual(self.verdict(broken).status, "invalid")

    def test_malformed_trials_are_invalid(self):
        mutations = {
            "gap": lambda line: line.update(trial=line["trial"] + 1),
            "warmup flag": lambda line: line.update(warmup=not line["warmup"]),
            "holder QoS": lambda line: line.update(holderQoS="background"),
            "outcome": lambda line: line.update(outcome="censored"),
            "wrong result": lambda line: line.update(holderResultCorrect=False),
            "observed trial": lambda line: line.update(
                mainObservedTrial=line["trial"] + 1
            ),
            "acquire before release": lambda line: line.update(
                mainAcquire=line["holderRelease"] - 1,
                outcome="valid",
            ),
            "before block": lambda line: line.update(loadStart=1),
            "after block": lambda line: line.update(loadStop=10**6),
            "CPU readings": lambda line: line.update(holderCPUReadings=[1]),
            "type": lambda line: line.update(mainCPU="0"),
            "missing field": lambda line: line.pop("loadStop"),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                lines = self.lines()
                mutate(lines[self.trial_indexes(lines)[1]])
                self.assertEqual(self.verdict(lines).status, "invalid")

    def test_trials_must_follow_the_samples_and_stay_in_their_block(self):
        lines = self.lines()
        indexes = self.trial_indexes(lines)
        misplaced = deepcopy(lines)
        batch = next(
            index for index, line in enumerate(misplaced) if line["type"] == "batch"
        )
        misplaced.insert(batch, misplaced.pop(indexes[0]))
        other_block = deepcopy(lines)
        other_block[indexes[0]]["block"] = 1
        for broken in (misplaced, other_block):
            self.assertEqual(self.verdict(broken).status, "invalid")
