#!/usr/bin/env python3
"""Compare measured arm64 Mach-O loop bodies without depending on names."""
from __future__ import annotations

import argparse
from dataclasses import asdict, dataclass
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Dict, List, Sequence


DEFAULT_FILTERS = (
    'BaseComparison', 'SharedInteger', 'Integer', 'Protection', 'AsyncCode',
    'CallerPaths', 'Batching', 'IsolationSettings', 'Counter', 'IsolationProbe',
    'Contended', 'Holder', 'Trial', 'LoadThreads', 'referenceLoop', 'BatchTimer',
)
INSTRUCTION = re.compile(r'^([0-9a-fA-F]+):\s+(\S+)(?:\s+(.*))?$')
ADDRESS = re.compile(r'(?<![#\w])0x([0-9a-fA-F]+)')
BRANCH = re.compile(r'^(?:b(?:\.[a-z]+)?|cbz|cbnz|tbz|tbnz)$')


@dataclass
class CodegenReport:
    missing: Dict[str, List[str]]
    added: Dict[str, List[str]]
    kept: int


def measured_units(disassembly: str, indirect_symbols: str,
                   demangled: Dict[str, str],
                   name_filters: Sequence[str]) -> Dict[str, List[str]]:
    """Hash each backward-branch region, or the full body when there is none.

    Aliases share a body and all matching names are retained for diagnostics.
    Async continuations often tail-call swift_task_switch instead of branching
    backward, so their full bodies must participate in the comparison.
    """
    imports = {}
    for line in indirect_symbols.splitlines():
        match = re.match(r'\s*0x([0-9a-fA-F]+)\s+\d+\s+(\S+)', line)
        if match:
            imports[int(match[1], 16)] = match[2]

    functions = []
    symbols = []
    body = []
    for line in disassembly.splitlines():
        line = line.strip()
        match = INSTRUCTION.match(line)
        if match:
            body.append((int(match[1], 16), match[2], match[3] or ''))
            continue
        if not line.endswith(':') or any(char.isspace() for char in line):
            continue
        if body:
            functions.append((symbols, body))
            symbols = []
            body = []
        symbols.append(line[:-1])
    if body:
        functions.append((symbols, body))

    units = {}
    for symbols, body in functions:
        names = sorted({demangled.get(symbol, symbol) for symbol in symbols
                        if any(value in demangled.get(symbol, symbol)
                               for value in name_filters)})
        if not names:
            continue
        start = body[0][0]
        end = body[-1][0]
        indices = {
            instruction[0]: index for index, instruction in enumerate(body)
        }
        normalized = []
        regions = []
        for index, (address, mnemonic, operands) in enumerate(body):
            operands = operands.split(';', 1)[0].strip()
            branch = BRANCH.fullmatch(mnemonic) is not None
            target = ADDRESS.search(operands)
            if target and (branch or mnemonic == 'bl'):
                destination = int(target[1], 16)
                if destination in imports:
                    replacement = 'IMPORT:' + imports[destination]
                elif branch and start <= destination <= end:
                    replacement = 'OFFSET:{:+#x}'.format(destination - start)
                    if destination <= address and destination in indices:
                        regions.append((indices[destination], index + 1))
                else:
                    replacement = 'LOCAL'
                operands = (
                    operands[:target.start()] + replacement
                    + operands[target.end():]
                )
            elif mnemonic in ('adr', 'adrp'):
                # Mach-O prints page deltas as decimal operands, with the
                # resolved address in a comment; neither identifies loop work.
                operands = operands.split(',', 1)[0] + ', ADDR'
            else:
                # Literal loads contain bare addresses; numeric immediates
                # such as #0x1 remain part of the measured instruction.
                operands = ADDRESS.sub('ADDR', operands)
            operands = re.sub(r'\s+', ' ', operands)
            normalized.append(mnemonic + (' ' + operands if operands else ''))

        if not regions:
            regions = [(0, len(body))]
        for first, last in regions:
            digest = hashlib.sha256(
                '\n'.join(normalized[first:last]).encode()
            ).hexdigest()
            units.setdefault(digest, set()).update(names)
    return {digest: sorted(names) for digest, names in sorted(units.items())}


def compare(baseline: Dict[str, List[str]],
            candidate: Dict[str, List[str]]) -> CodegenReport:
    """Report absent baseline units; extra candidate units are informational."""
    return CodegenReport(
        missing={
            digest: baseline[digest]
            for digest in sorted(baseline.keys() - candidate.keys())
        },
        added={
            digest: candidate[digest]
            for digest in sorted(candidate.keys() - baseline.keys())
        },
        kept=len(baseline.keys() & candidate.keys()),
    )


def _inspect(executable: Path) -> Dict[str, List[str]]:
    symbols = subprocess.check_output(['xcrun', 'nm', str(executable)], text=True)
    pretty = subprocess.check_output(
        ['xcrun', 'swift-demangle'], input=symbols, text=True,
    )
    demangled = {}
    for raw, readable in zip(symbols.splitlines(), pretty.splitlines()):
        raw_match = re.match(r'[0-9a-fA-F]+\s+[tT]\s+(.+)', raw)
        readable_match = re.match(r'[0-9a-fA-F]+\s+[tT]\s+(.+)', readable)
        if raw_match and readable_match:
            demangled[raw_match[1]] = readable_match[1]
    disassembly = subprocess.check_output([
        'xcrun', 'llvm-objdump', '--macho', '--mattr=+lse,+rcpc',
        '--no-show-raw-insn', '--disassemble', str(executable),
    ], text=True)
    indirect = subprocess.check_output([
        'xcrun', 'llvm-objdump', '--macho', '--indirect-symbols', str(executable),
    ], text=True)
    units = measured_units(disassembly, indirect, demangled, DEFAULT_FILTERS)
    if not units:
        raise ValueError('No measured units found in ' + str(executable))
    return units


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline_executable', type=Path)
    parser.add_argument('candidate_executable', type=Path)
    parser.add_argument('--report', required=True, type=Path)
    arguments = parser.parse_args()
    try:
        baseline = _inspect(arguments.baseline_executable)
        candidate = _inspect(arguments.candidate_executable)
        report = compare(baseline, candidate)
        arguments.report.parent.mkdir(parents=True, exist_ok=True)
        arguments.report.write_text(
            json.dumps(asdict(report), indent=2, sort_keys=True) + '\n'
        )
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2
    return 1 if report.missing else 0


if __name__ == '__main__':
    sys.exit(main())
