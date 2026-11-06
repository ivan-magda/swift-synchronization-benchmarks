from __future__ import annotations

import hashlib
from pathlib import Path
import unittest

import codegen_compare


FIXTURES = Path(__file__).parent / 'fixtures' / 'codegen'
DEMANGLED = {
    '_loop': 'BaseComparison.original()',
    '_loopAlias': 'BaseComparison.alias()',
    '_renamed': 'BaseComparison.readable()',
    '_helper': 'helper()',
    '_otherHelper': 'otherHelper()',
    '_resume': 'AsyncCode.original() resume partial function',
    '_otherResume': 'AsyncCode.readable() resume partial function',
    '_ignored': 'unrelated()',
}


class CodegenCompareTests(unittest.TestCase):
    # Four tests are required: rename tolerance, changed loop work, import
    # resolution and async continuation coverage are separate failure modes.
    def units(self, fixture, filters=('BaseComparison', 'AsyncCode')):
        return codegen_compare.measured_units(
            (FIXTURES / fixture).read_text(),
            (FIXTURES / 'indirect.txt').read_text(),
            DEMANGLED,
            filters,
        )

    def test_renamed_function_with_same_loop_is_kept(self):
        baseline = self.units('baseline.txt')
        candidate = self.units('renamed.txt')
        report = codegen_compare.compare(baseline, candidate)
        self.assertEqual(report.missing, {})
        self.assertEqual(report.added, {})
        self.assertEqual(report.kept, 2)
        self.assertEqual(
            sorted(name for names in baseline.values() for name in names),
            ['AsyncCode.original() resume partial function',
             'BaseComparison.alias()', 'BaseComparison.original()'],
        )

    def test_extra_call_in_loop_is_missing(self):
        baseline = self.units('baseline.txt', ('BaseComparison',))
        candidate = self.units('extra-call.txt', ('BaseComparison',))
        report = codegen_compare.compare(baseline, candidate)
        self.assertEqual(report.missing, baseline)
        self.assertEqual(
            list(report.missing.values()),
            [['BaseComparison.alias()', 'BaseComparison.original()']],
        )
        self.assertEqual(report.added, candidate)
        self.assertEqual(report.kept, 0)

    def test_stub_calls_resolve_through_indirect_symbols(self):
        # Pin the normalized unit, so ignoring all calls cannot pass a
        # rename-only comparison. The comment supplies no trusted symbol.
        expected_lines = (
            'adrp x8, ADDR\n'
            'ldr x9, ADDR\n'
            'bl LOCAL\n'
            'ldr x8, [x0]\n'
            'add x8, x8, #0x1\n'
            'bl IMPORT:_os_unfair_lock_lock\n'
            'subs x1, x1, #0x1\n'
            'b.ne OFFSET:+0x4'
        )
        expected_hash = hashlib.sha256(expected_lines.encode()).hexdigest()
        self.assertEqual(
            self.units('baseline.txt', ('BaseComparison',)),
            {expected_hash: ['BaseComparison.alias()', 'BaseComparison.original()']},
        )

    def test_resume_function_without_loop_is_one_unit(self):
        expected_lines = (
            'adrp x1, ADDR\n'
            'mov x2, #0x0\n'
            'b IMPORT:_swift_task_switch'
        )
        expected_hash = hashlib.sha256(expected_lines.encode()).hexdigest()
        self.assertEqual(
            self.units('baseline.txt', ('AsyncCode',)),
            {expected_hash: ['AsyncCode.original() resume partial function']},
        )
