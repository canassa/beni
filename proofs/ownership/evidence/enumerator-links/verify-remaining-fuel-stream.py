#!/usr/bin/env python3
"""Check the existing FuelLeft byte stream. Run through run-heavy.zsh."""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import re
import sys
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime
from enum import Enum
from pathlib import Path
from typing import BinaryIO, Iterator, Protocol

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "proofs/ownership"
EXPECTED_CASES = 226_088
EXPECTED_ACCEPTED = 71_747
EXPECTED_RUNS = 238_166
EXPECTED_ROWS = EXPECTED_CASES + 2 * EXPECTED_RUNS
GENERATOR_COUNT = 20_000
ENUMERATOR_COUNT = 105_150
TARGETED_COUNT = 740
FIXTURE_COUNT = 98
SYNC_COUNT = 99
SEEDS = (20_261_011, 17, 271_828)
CAMPAIGN_FUEL = 100_000
ENUMERATOR_FUEL = 20_000
SMALL_FUELS = tuple(range(33)) + (CAMPAIGN_FUEL,)
MAX_ROW_BYTES = 64 * 1024 * 1024
SUCCESS_PREFIX = b"Except.ok { remainingFuel := "
TRACE_SEPARATOR = b",\\n  trace := "
ERROR_PREFIX = b'Except.error "'
LOGGER = logging.getLogger(__name__)


class Family(str, Enum):
    WITNESS = "witness"
    FIXTURE = "fixture"
    SYNC = "sync"
    TARGETED = "targeted"
    V5 = "v5"
    V6 = "v6"
    ENUM = "enum"


class Outcome(str, Enum):
    SUCCESS = "success"
    ERROR = "error"


class SchemaError(Exception):
    pass


class Digest(Protocol):
    def update(self, value: bytes) -> None: ...

    def hexdigest(self) -> str: ...


@dataclass(frozen=True)
class Fingerprint:
    file: str
    sha256: str
    bytes: int


@dataclass(frozen=True)
class FileState:
    device: int
    inode: int
    bytes: int
    modified_ns: int


@dataclass(frozen=True)
class ByteStream:
    rows: int
    bytes: int
    sha256: str


@dataclass
class Accumulator:
    rows: int = 0
    bytes: int = 0
    digest: Digest = field(default_factory=hashlib.sha256)

    def add(self, row: bytes) -> None:
        self.rows += 1
        self.bytes += len(row)
        self.digest.update(row)

    def finish(self) -> ByteStream:
        return ByteStream(self.rows, self.bytes, self.digest.hexdigest())


@dataclass(frozen=True)
class StreamHashes:
    combined: ByteStream
    checks_only: ByteStream
    value_results_only: ByteStream
    heap_results_only: ByteStream
    value_with_checks: ByteStream
    heap_with_checks: ByteStream


@dataclass(frozen=True)
class CaseSpec:
    label: bytes
    family: Family
    fuels: tuple[int, ...]


@dataclass(frozen=True)
class Row:
    number: int
    label: bytes
    operation: bytes
    payload: bytes
    raw: bytes


@dataclass(frozen=True)
class EvalResult:
    outcome: Outcome
    remaining_fuel: int | None = None
    trace: bytes | None = None
    trace_outcome: Outcome | None = None


@dataclass
class FamilyCounts:
    family: Family
    cases: int = 0
    accepted: int = 0
    runs: int = 0
    paired_eval_success: int = 0
    paired_eval_error: int = 0


@dataclass
class Counts:
    cases: int = 0
    accepted: int = 0
    rejected: int = 0
    runs: int = 0
    paired_eval_success: int = 0
    equal_remaining_fuel: int = 0
    unequal_remaining_fuel: int = 0
    value_eval_only: int = 0
    heap_eval_only: int = 0
    paired_eval_error: int = 0
    paired_eval_error_bytes_equal: int = 0
    paired_eval_error_bytes_different: int = 0
    paired_trace_success: int = 0
    exact_trace_bytes_equal: int = 0
    exact_trace_bytes_different: int = 0
    value_trace_only: int = 0
    heap_trace_only: int = 0
    paired_final_snapshot_error: int = 0
    paired_final_snapshot_error_bytes_equal: int = 0
    paired_final_snapshot_error_bytes_different: int = 0


@dataclass(frozen=True)
class Mismatch:
    case: str
    initial_fuel: int
    reason: str
    value_row: int
    heap_row: int
    raw_value_record: str
    raw_heap_record: str


@dataclass(frozen=True)
class Expected:
    cases: int = EXPECTED_CASES
    accepted: int = EXPECTED_ACCEPTED
    rejected: int = EXPECTED_CASES - EXPECTED_ACCEPTED
    runs: int = EXPECTED_RUNS
    rows: int = EXPECTED_ROWS


@dataclass(frozen=True)
class Report:
    complete: bool
    passed: bool
    started_at_utc: datetime
    finished_at_utc: datetime
    input_file: str
    input_before: FileState
    input_after: FileState
    input_unchanged: bool
    verifier: Fingerprint
    schedule_sources: tuple[Fingerprint, ...]
    schedule_sources_unchanged: bool
    expected: Expected
    counts: Counts
    families: tuple[FamilyCounts, ...]
    streams: StreamHashes
    mismatches: tuple[Mismatch, ...]
    errors: tuple[str, ...]
    limits: tuple[str, ...]


def fingerprint(filename: Path) -> Fingerprint:
    data = filename.read_bytes()
    return Fingerprint(str(filename.relative_to(ROOT)), hashlib.sha256(data).hexdigest(), len(data))


def file_state(filename: Path) -> FileState:
    state = filename.stat()
    return FileState(state.st_dev, state.st_ino, state.st_size, state.st_mtime_ns)


def labels(source: Path, start: str, end: str, count: int) -> tuple[bytes, ...]:
    text = source.read_text()
    if text.count(start) != 1 or text.count(end) != 1:
        raise SchemaError(f"Unexpected source markers: {source}")
    body = text.split(start, 1)[1].split(end, 1)[0]
    values = re.findall(r'(?:⟨|\()\s*"([^"\\]*)"\s*,', body)
    if len(values) != count or len(set(values)) != count:
        raise SchemaError(f"Expected {count} unique labels in {source}; got {len(values)}")
    return tuple(value.encode("utf-8") for value in values)


def expected_cases() -> Iterator[CaseSpec]:
    yield CaseSpec(b"witness", Family.WITNESS, SMALL_FUELS)
    fixtures = labels(PACKAGE / "Ownership/Fixtures.lean", "def all : List Fixture := [", "\ndef run", FIXTURE_COUNT)
    sync_source = PACKAGE / "Ownership/Sync.lean"
    legacy = labels(sync_source, "def legacyFixtures : List (String × Program × Bool) := [", "\ndef extraFixtures", 44)
    extra = labels(sync_source, "def extraFixtures : List (String × Program × Bool) := [", "\ndef extraPrograms", SYNC_COUNT - len(legacy))
    for name in fixtures:
        yield CaseSpec(b"fixture:" + name, Family.FIXTURE, (CAMPAIGN_FUEL,))
    for name in legacy + extra:
        yield CaseSpec(b"sync:" + name, Family.SYNC, (CAMPAIGN_FUEL,))
    for index in range(TARGETED_COUNT):
        yield CaseSpec(f"targeted:{index}".encode(), Family.TARGETED, (CAMPAIGN_FUEL,))
    for version, family in ((5, Family.V5), (6, Family.V6)):
        for seed in SEEDS:
            for index in range(GENERATOR_COUNT):
                yield CaseSpec(f"v{version}:{seed}:{index}".encode(), family, SMALL_FUELS if version == 6 else (CAMPAIGN_FUEL,))
    for index in range(ENUMERATOR_COUNT):
        yield CaseSpec(f"enum:{index}".encode(), Family.ENUM, (ENUMERATOR_FUEL,))


class Reader:
    def __init__(self, stream: BinaryIO) -> None:
        self.stream = stream
        self.combined = Accumulator()
        self.checks = Accumulator()
        self.values = Accumulator()
        self.heaps = Accumulator()
        self.value_cases = Accumulator()
        self.heap_cases = Accumulator()

    def take(self) -> Row | None:
        raw = self.stream.readline(MAX_ROW_BYTES + 1)
        if not raw:
            return None
        self.combined.add(raw)
        number = self.combined.rows
        if len(raw) > MAX_ROW_BYTES or not raw.endswith(b"\n"):
            raise SchemaError(f"Row {number}: oversized row or missing final newline")
        if b"\r" in raw or b"\x00" in raw or raw.count(b"\t") != 2:
            raise SchemaError(f"Row {number}: expected exactly two tabs, no CR or NUL")
        label, operation, payload = raw[:-1].split(b"\t")
        raw.decode("utf-8")
        row = Row(number, label, operation, payload, raw)
        if operation == b"check":
            self.checks.add(raw)
            self.value_cases.add(raw)
            self.heap_cases.add(raw)
        elif re.fullmatch(rb"value-(0|[1-9][0-9]*)", operation):
            self.values.add(raw)
            self.value_cases.add(raw)
        elif re.fullmatch(rb"heap-(0|[1-9][0-9]*)", operation):
            self.heaps.add(raw)
            self.heap_cases.add(raw)
        else:
            raise SchemaError(f"Row {number}: unknown operation {operation!r}")
        return row

    def require(self, case: CaseSpec, operation: bytes) -> Row:
        row = self.take()
        if row is None:
            raise SchemaError(f"Unexpected EOF: expected {case.label!r} {operation!r}")
        if row.label != case.label or row.operation != operation:
            raise SchemaError(f"Row {row.number}: expected {(case.label, operation)!r}; got {(row.label, row.operation)!r}")
        return row

    def hashes(self) -> StreamHashes:
        return StreamHashes(*(part.finish() for part in (self.combined, self.checks, self.values, self.heaps, self.value_cases, self.heap_cases)))


def valid_error(payload: bytes) -> bool:
    if not payload.startswith(ERROR_PREFIX) or not payload.endswith(b'"'):
        return False
    escaped = False
    for character in payload[len(ERROR_PREFIX):-1]:
        if escaped:
            escaped = False
        elif character == 92:
            escaped = True
        elif character == 34:
            return False
    return not escaped


def parse_eval(row: Row, initial_fuel: int) -> EvalResult:
    payload = row.payload
    if valid_error(payload):
        return EvalResult(Outcome.ERROR)
    if not payload.startswith(SUCCESS_PREFIX) or not payload.endswith(b" }"):
        raise SchemaError(f"Row {row.number}: unexpected evaluation result schema")
    fields = payload[len(SUCCESS_PREFIX):-2].split(TRACE_SEPARATOR)
    if len(fields) != 2 or re.fullmatch(rb"0|[1-9][0-9]*", fields[0]) is None:
        raise SchemaError(f"Row {row.number}: expected remainingFuel and trace fields")
    remaining = int(fields[0])
    if remaining > initial_fuel:
        raise SchemaError(f"Row {row.number}: remaining fuel exceeds initial fuel")
    trace = fields[1]
    if valid_error(trace):
        return EvalResult(Outcome.SUCCESS, remaining, trace, Outcome.ERROR)
    if not trace.startswith(b"Except.ok { reads := ") or not trace.endswith(b" }"):
        raise SchemaError(f"Row {row.number}: unexpected public trace schema")
    if trace.count(b"finalValue := ") != 1 or trace.count(b"externalReads := ") != 1:
        raise SchemaError(f"Row {row.number}: missing or repeated public trace fields")
    return EvalResult(Outcome.SUCCESS, remaining, trace, Outcome.SUCCESS)


def compare_pair(case: CaseSpec, fuel: int, value: Row, heap: Row, tally: Counts, family: FamilyCounts) -> list[Mismatch]:
    left, right = parse_eval(value, fuel), parse_eval(heap, fuel)
    tally.runs += 1
    family.runs += 1
    reasons: list[str] = []
    if left.outcome == right.outcome == Outcome.ERROR:
        tally.paired_eval_error += 1
        family.paired_eval_error += 1
        if value.payload == heap.payload:
            tally.paired_eval_error_bytes_equal += 1
        else:
            tally.paired_eval_error_bytes_different += 1
    elif left.outcome != right.outcome:
        if left.outcome == Outcome.SUCCESS:
            tally.value_eval_only += 1
        else:
            tally.heap_eval_only += 1
        reasons.append("Only one interpreter evaluation succeeds")
    else:
        tally.paired_eval_success += 1
        family.paired_eval_success += 1
        if left.remaining_fuel == right.remaining_fuel:
            tally.equal_remaining_fuel += 1
        else:
            tally.unequal_remaining_fuel += 1
            reasons.append("Remaining fuel differs after successful evaluations")
        if left.trace_outcome == right.trace_outcome == Outcome.SUCCESS:
            tally.paired_trace_success += 1
            if left.trace == right.trace:
                tally.exact_trace_bytes_equal += 1
            else:
                tally.exact_trace_bytes_different += 1
                reasons.append("Successful public trace bytes differ")
        elif left.trace_outcome == right.trace_outcome == Outcome.ERROR:
            tally.paired_final_snapshot_error += 1
            if left.trace == right.trace:
                tally.paired_final_snapshot_error_bytes_equal += 1
            else:
                tally.paired_final_snapshot_error_bytes_different += 1
        else:
            if left.trace_outcome == Outcome.SUCCESS:
                tally.value_trace_only += 1
            else:
                tally.heap_trace_only += 1
            reasons.append("Only one final snapshot succeeds")
    return [Mismatch(case.label.decode(), fuel, reason, value.number, heap.number, value.raw.decode(), heap.raw.decode()) for reason in reasons]


def encode(value: object) -> str:
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, Enum):
        return str(value.value)
    raise TypeError(f"Unsupported JSON type: {type(value).__name__}")


def verify(filename: Path) -> Report:
    started = datetime.now(UTC)
    initial = file_state(filename)
    schedule_files = tuple(PACKAGE / name for name in ("Ownership/Fixtures.lean", "Ownership/Sync.lean", "evidence/construction-fuel/FuelLeft.lean"))
    schedule_sources = tuple(fingerprint(name) for name in schedule_files)
    tally = Counts()
    families = {family: FamilyCounts(family) for family in Family}
    mismatches: list[Mismatch] = []
    errors: list[str] = []
    complete = False
    with filename.open("rb") as stream:
        reader = Reader(stream)
        try:
            seen: set[bytes] = set()
            for case in expected_cases():
                if case.label in seen:
                    raise SchemaError(f"Duplicate expected case key: {case.label!r}")
                seen.add(case.label)
                check = reader.require(case, b"check")
                tally.cases += 1
                family = families[case.family]
                family.cases += 1
                if check.payload == b"Except.ok ()":
                    tally.accepted += 1
                    family.accepted += 1
                    for fuel in case.fuels:
                        value = reader.require(case, f"value-{fuel}".encode())
                        heap = reader.require(case, f"heap-{fuel}".encode())
                        mismatches.extend(compare_pair(case, fuel, value, heap, tally, family))
                elif valid_error(check.payload):
                    tally.rejected += 1
                else:
                    raise SchemaError(f"Row {check.number}: unexpected checker result schema")
            extra = reader.take()
            if extra is not None:
                raise SchemaError(f"Row {extra.number}: unexpected trailing record")
            complete = True
        except (SchemaError, UnicodeError) as error:
            errors.append(str(error))
            LOGGER.error("Stream validation stopped: %s", error)
        hashes = reader.hashes()
    final = file_state(filename)
    expected = Expected()
    for name, actual, wanted in (
        ("cases", tally.cases, expected.cases), ("accepted", tally.accepted, expected.accepted),
        ("rejected", tally.rejected, expected.rejected), ("runs", tally.runs, expected.runs),
        ("rows", hashes.combined.rows, expected.rows),
        ("check rows", hashes.checks_only.rows, expected.cases),
        ("value result rows", hashes.value_results_only.rows, expected.runs),
        ("heap result rows", hashes.heap_results_only.rows, expected.runs),
        ("value rows with checks", hashes.value_with_checks.rows, expected.cases + expected.runs),
        ("heap rows with checks", hashes.heap_with_checks.rows, expected.cases + expected.runs),
    ):
        if actual != wanted:
            errors.append(f"Expected {name}={wanted}; got {actual}")
    if initial != final or hashes.combined.bytes != initial.bytes:
        errors.append("Input changed during the scan or the stream hash is incomplete")
    schedule_unchanged = schedule_sources == tuple(fingerprint(name) for name in schedule_files)
    if not schedule_unchanged:
        errors.append("The schedule sources changed during the scan")
    return Report(complete, complete and not errors and not mismatches, started, datetime.now(UTC),
                  str(filename.relative_to(ROOT)), initial, final, initial == final, fingerprint(Path(__file__)),
                  schedule_sources, schedule_unchanged, expected, tally, tuple(families.values()), hashes, tuple(mismatches), tuple(errors),
                  ("Raw LF-delimited rows, labels, fuel keys, result bytes, traces, and errors enter hashes without normalization.",
                   "Each interpreter-with-checks stream contains every original check row and only that interpreter's result rows, in source order.",
                   "The result-only hashes omit check rows explicitly; the check-only hash retains all rejected case records.",
                   "Paired evaluation failures retain exact bytes but do not establish equal remaining fuel or equal error strings.",
                   "Successful evaluation pairs compare remaining fuel; successful final snapshots also compare exact public trace bytes.",
                   "The parser checks the top-level Lean result schema and compares successful trace payloads as exact bytes without interpretation.",
                   "A schema failure stops validation and produces an explicitly partial hash; no row is silently normalized or excluded.",
                   "This scan validates existing stream bytes, not the historical build or execution provenance.",
                   "The finite measurement does not prove Invariant.fuel or any general soundness statement."))


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s", stream=sys.stderr)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("The output must use a fresh filename")
    report = verify(args.input.resolve())
    with args.output.open("x") as output:
        output.write(json.dumps(asdict(report), default=encode, indent=2) + "\n")
    LOGGER.info("complete=%s passed=%s cases=%d accepted=%d runs=%d rows=%d mismatches=%d errors=%d",
                report.complete, report.passed, report.counts.cases, report.counts.accepted, report.counts.runs,
                report.streams.combined.rows, len(report.mismatches), len(report.errors))
    return 0 if report.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
