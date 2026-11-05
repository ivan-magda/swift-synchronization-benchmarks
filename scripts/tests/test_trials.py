from __future__ import annotations

import unittest

from runner.trials import classify_trial


def trial(**ticks):
    """A trial line with the holder holding the lock from 200 to 400."""
    line = {
        "loadStart": 100,
        "loadStop": 600,
        "holderAcquire": 200,
        "holderRelease": 400,
        "mainArrival": 300,
        "mainAcquire": 450,
    }
    line.update(ticks)
    return line


class ClassifyTrialTests(unittest.TestCase):
    def test_arrival_during_hold_and_acquire_before_load_stop_is_valid(self):
        self.assertEqual(classify_trial(trial()), "valid")

    def test_acquire_exactly_at_load_stop_is_valid(self):
        self.assertEqual(classify_trial(trial(mainAcquire=600)), "valid")

    def test_acquire_after_load_stop_is_censored(self):
        self.assertEqual(classify_trial(trial(mainAcquire=601)), "censored")

    def test_arrival_before_holder_acquire_is_invalid(self):
        self.assertEqual(classify_trial(trial(mainArrival=150)), "invalid")

    def test_arrival_after_holder_release_is_invalid(self):
        self.assertEqual(classify_trial(trial(mainArrival=401)), "invalid")

    def test_arrival_after_load_stop_is_invalid(self):
        line = trial(holderRelease=800, mainArrival=650, mainAcquire=850)
        self.assertEqual(classify_trial(line), "invalid")
