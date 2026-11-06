from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
from pathlib import Path
import unittest
from unittest.mock import patch

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

    def test_dump_lists_imports_of_each_loop(self):
        # Exercise the CLI with the real parser; only Xcode's external output
        # is substituted so this test also runs without an installed SDK.
        symbols = '\n'.join('0000 T ' + symbol for symbol in DEMANGLED)
        readable = '\n'.join('0000 T ' + name for name in DEMANGLED.values())
        output = io.StringIO()
        with patch('sys.argv', ['codegen_compare.py', '--dump', 'fixture']), \
                patch('subprocess.check_output', side_effect=[
                    symbols, readable,
                    (FIXTURES / 'baseline.txt').read_text(),
                    (FIXTURES / 'indirect.txt').read_text(),
                ]), redirect_stdout(output):
            self.assertEqual(codegen_compare.main(), 0)
        self.assertEqual(output.getvalue(), (
            'BaseComparison.alias()\n'
            'BaseComparison.original()\n'
            'adrp x8, ADDR\n'
            'ldr x9, ADDR\n'
            'bl LOCAL:helper()\n'
            'ldr x8, [x0]\n'
            'add x8, x8, #0x1\n'
            'bl IMPORT:_os_unfair_lock_lock\n'
            'subs x1, x1, #0x1\n'
            'b.ne OFFSET:+0x4\n\n'
            'AsyncCode.original() resume partial function\n'
            'adrp x1, ADDR\n'
            'mov x2, #0x0\n'
            'b IMPORT:_swift_task_switch\n\n'
        ))

    def test_default_filters_select_new_experiments(self):
        for name in (
            'RequestRegistry', 'Registry', 'HotFlag', 'Flag',
            'TransactionalStore', 'Store', 'MainThreadCache', 'ImageCache',
            'CreationCost', 'Object',
        ):
            with self.subTest(name=name):
                self.assertIn(name, codegen_compare.DEFAULT_FILTERS)

    def test_cli_rejects_invalid_modes_and_empty_selection(self):
        for arguments in (
            [], ['baseline'], ['baseline', 'candidate'],
            ['--dump', 'fixture', 'candidate', '--report', 'out.json'],
            ['--dump', 'fixture', '--report', 'out.json'],
        ):
            with self.subTest(arguments=arguments), \
                    patch('sys.argv', ['codegen_compare.py'] + arguments), \
                    redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as error:
                    codegen_compare.main()
                self.assertEqual(error.exception.code, 2)
        with patch('sys.argv', ['codegen_compare.py', '--dump', 'fixture']), \
                patch('subprocess.check_output', side_effect=['', '', '', '']), \
                redirect_stderr(io.StringIO()):
            self.assertEqual(codegen_compare.main(), 2)

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

    def test_page_relative_addresses_relocate_without_changing_units(self):
        names = {'_metadata': 'Counter.metadata', '_literal': 'Counter.literal'}
        baseline = codegen_compare.measured_units(
            (FIXTURES / 'page-baseline.txt').read_text(), '', names, ('Counter',),
        )
        candidate = codegen_compare.measured_units(
            (FIXTURES / 'page-relocated.txt').read_text(), '', names, ('Counter',),
        )
        report = codegen_compare.compare(baseline, candidate)
        self.assertEqual(report.missing, {})
        self.assertEqual(report.added, {})
        self.assertEqual(report.kept, 2)

    def test_ordinary_immediates_survive_page_address_normalization(self):
        # Page provenance ends when a register is loaded, overwritten, or
        # clobbered by a call. These offsets describe work and must be retained.
        source = (FIXTURES / 'page-baseline.txt').read_text()
        names = {'_ordinary': 'Counter.ordinary'}
        baseline = codegen_compare.measured_units(source, '', names, ('Counter',))
        for old, new in (
            ('3000: add x0, x0, #0xa60', '3000: add x0, x0, #0x9a0'),
            ('3004: ldr x1, [x2, #0x1a8]', '3004: ldr x1, [x2, #0x1b8]'),
            ('3010: ldr x9, [x8, #0x10]', '3010: ldr x9, [x8, #0x18]'),
            ('301c: ldr x11, [x10, #0x20]', '301c: ldr x11, [x10, #0x28]'),
            ('3028: ldr x13, [x12, #0x30]', '3028: ldr x13, [x12, #0x38]'),
            ('3034: ldr x15, [x14, #0x40]', '3034: ldr x15, [x14, #0x48]'),
            ('3044: ldr x9, [x15, #0x50]', '3044: ldr x9, [x15, #0x58]'),
            ('3050: ldr x18, [x16, #0x60]', '3050: ldr x18, [x16, #0x68]'),
        ):
            with self.subTest(instruction=old):
                candidate = codegen_compare.measured_units(
                    source.replace(old, new), '', names, ('Counter',),
                )
                self.assertEqual(
                    codegen_compare.compare(baseline, candidate).missing, baseline,
                )

    def test_symbolic_local_calls_and_branches_ignore_renames(self):
        names = {
            '_old': 'Counter.old', '_new': 'Counter.new',
            '_tail': 'Counter.tail', '_renamedTail': 'Counter.renamedTail',
        }
        baseline = codegen_compare.measured_units(
            (FIXTURES / 'symbolic-baseline.txt').read_text(), '', names, ('Counter',),
        )
        candidate = codegen_compare.measured_units(
            (FIXTURES / 'symbolic-renamed.txt').read_text(), '', names, ('Counter',),
        )
        self.assertEqual(codegen_compare.compare(baseline, candidate).missing, {})
        expected_loop = hashlib.sha256(b'cbnz x0, OFFSET:+0x0').hexdigest()
        self.assertEqual(baseline[expected_loop], ['Counter.tail'])
        # Calls and tail branches stay distinct after local names disappear.
        changed = (FIXTURES / 'symbolic-renamed.txt').read_text().replace(
            '4000: bl _renamedHelper', '4000: b _renamedHelper',
        )
        candidate = codegen_compare.measured_units(changed, '', names, ('Counter',))
        self.assertEqual(len(codegen_compare.compare(baseline, candidate).missing), 1)

    def test_multi_destination_and_status_writes_end_page_provenance(self):
        names = {'_counter': 'Counter.increment'}
        for instruction in (
            'ldadd x0, x8, [x1]',
            'ldpsw x0, x8, [x1]',
            'stxr w8, x0, [x1]',
        ):
            with self.subTest(instruction=instruction):
                source = (
                    '_counter:\n'
                    '1000: adrp x8, 111\n'
                    '1004: ' + instruction + '\n'
                    '1008: ldr x9, [x8, #0x10]\n'
                    '100c: ret\n'
                )
                baseline = codegen_compare.measured_units(
                    source, '', names, ('Counter',),
                )
                candidate = codegen_compare.measured_units(
                    source.replace('#0x10', '#0x18'), '', names, ('Counter',),
                )
                self.assertEqual(
                    codegen_compare.compare(baseline, candidate).missing, baseline,
                )

    def test_read_operands_preserve_relocatable_page_provenance(self):
        names = {'_counter': 'Counter.increment'}
        for instruction in (
            'mov x9, x8',
            'str x8, [x1]',
            'stp x8, x9, [x1]',
            'add x9, x8, #0x30',
            'ldadd x8, x0, [x1]',
        ):
            with self.subTest(instruction=instruction):
                source = (
                    '_counter:\n'
                    '1000: adrp x8, 111\n'
                    '1004: ' + instruction + '\n'
                    '1008: ldr x0, [x8, #0x10]\n'
                    '100c: ret\n'
                )
                baseline = codegen_compare.measured_units(
                    source, '', names, ('Counter',),
                )
                candidate = codegen_compare.measured_units(
                    source.replace('111', '222').replace('#0x10', '#0x18'),
                    '', names, ('Counter',),
                )
                report = codegen_compare.compare(baseline, candidate)
                self.assertEqual(report.missing, {})
                self.assertEqual(report.added, {})
                self.assertEqual(report.kept, 1)
