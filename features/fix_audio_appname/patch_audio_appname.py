#!/usr/bin/env python3
"""Safely disable the private appname setParameters calls in two ARM64 ELFs.

The patch intentionally has no release-wide file digest or file-size allow-list.
Every input is checked as an ELF64/AArch64 object and call sites are located by
exported function symbols plus instruction-level semantic anchors. Harmless
layout shifts are therefore allowed, while an ambiguous OTA is rejected.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import os
import stat
import struct
import sys


BLR_X8 = bytes.fromhex("00 01 3f d6")
ARM64_NOP = bytes.fromhex("1f 20 03 d5")

PT_LOAD = 1
PF_X = 1
SHT_SYMTAB = 2
SHT_DYNSYM = 11
STT_FUNC = 2


class PatchError(ValueError):
    """An input is not an unambiguous supported library state."""


@dataclass(frozen=True)
class PatternContract:
    name: str
    before: tuple[bytes, ...]
    after: tuple[bytes, ...]
    count: int


@dataclass(frozen=True)
class FunctionContract:
    symbol: str
    patterns: tuple[PatternContract, ...]


@dataclass(frozen=True)
class LibrarySpec:
    filename: str
    functions: tuple[FunctionContract, ...]

    @property
    def site_count(self) -> int:
        return sum(
            pattern.count
            for function in self.functions
            for pattern in function.patterns
        )


@dataclass(frozen=True)
class ProgramLoad:
    file_offset: int
    file_size: int
    virtual_address: int
    virtual_size: int
    flags: int

    @property
    def executable(self) -> bool:
        return bool(self.flags & PF_X)


@dataclass(frozen=True)
class FunctionSymbol:
    name: str
    value: int
    size: int


@dataclass(frozen=True)
class LocatedSite:
    pattern_name: str
    offset: int
    state: str


@dataclass(frozen=True)
class Inspection:
    state: str
    sites: tuple[LocatedSite, ...]


def _instruction(hex_word: str) -> bytes:
    if len(hex_word) != 8:
        raise AssertionError(f"not an AArch64 instruction: {hex_word}")
    try:
        return int(hex_word, 16).to_bytes(4, "little")
    except ValueError as exc:
        raise AssertionError(f"not an AArch64 instruction: {hex_word}") from exc


def _pattern(name: str, before: str, after: str, count: int) -> PatternContract:
    before_words = tuple(_instruction(word) for word in before.split())
    after_words = tuple(_instruction(word) for word in after.split())
    if not before_words or not after_words or count <= 0:
        raise AssertionError(f"invalid pattern contract: {name}")
    return PatternContract(name, before_words, after_words, count)


# These anchors encode the C++ call operation instead of a release-wide file
# digest: load the stream object's vtable, fetch slot 0x60 (setParameters),
# invoke it, then continue with the adjacent String object. Each match is also
# constrained to its exported function's symbol range and executable PT_LOAD.
LIBRARIES = {
    "libaudiopolicymanagerimpl.so": LibrarySpec(
        filename="libaudiopolicymanagerimpl.so",
        functions=(
            FunctionContract(
                symbol=(
                    "_ZN7android22AudioPolicyManagerImpl19setAppNameParameterERKNS_2spINS_21TrackClientDescriptorEEEPNS_26AudioPolicyClientInterfaceERKNS1_INS_23SwAudioOutputDescriptorEEEb"
                ),
                patterns=(
                    _pattern(
                        "app-output-primary",
                        "f94002c8 d10083a2 aa1603e0 2a1f03e1 2a1f03e3 f9403108",
                        "d100a3a0",
                        1,
                    ),
                    _pattern(
                        "app-output-secondary",
                        "f94002e8 f94002c9 d10083a2 aa1603e0 2a1f03e3 b940e101 f9403128",
                        "d10083a0",
                        1,
                    ),
                ),
            ),
            FunctionContract(
                symbol=(
                    "_ZN7android22AudioPolicyManagerImpl28setParametersForSystemClientENS_2spINS_22RecordClientDescriptorEEEPNS_26AudioPolicyClientInterfaceEib"
                ),
                patterns=(
                    _pattern(
                        "system-client-output",
                        "f9400288 910063a2 aa1403e0 2a1303e1 2a1f03e3 f9403108",
                        "910063a0",
                        1,
                    ),
                ),
            ),
        ),
    ),
    "libmiaudiopolicymanager.so": LibrarySpec(
        filename="libmiaudiopolicymanager.so",
        functions=(
            FunctionContract(
                symbol="_ZN7android20MiAudioPolicyManager10startInputEi",
                patterns=(
                    _pattern(
                        "input-start-primary",
                        "f94002c8 910023e2 aa1603e0 2a1303e1 2a1f03e3 f9403108",
                        "910023e0",
                        1,
                    ),
                    _pattern(
                        "input-start-secondary",
                        "f9404280 910043e2 2a1303e1 2a1f03e3 f9400008 f9403108",
                        "910043e0",
                        2,
                    ),
                ),
            ),
            FunctionContract(
                symbol="_ZN7android20MiAudioPolicyManager9stopInputEi",
                patterns=(
                    _pattern(
                        "input-stop",
                        "f9404260 910063e2 2a1403e1 2a1f03e3 f9400008 f9403108",
                        "910063e0",
                        2,
                    ),
                ),
            ),
        ),
    ),
}


def _read_struct(
    fmt: str, data: bytes, offset: int, description: str
) -> tuple[int, ...]:
    size = struct.calcsize(fmt)
    if offset < 0 or offset + size > len(data):
        raise PatchError(f"truncated ELF {description}")
    return struct.unpack_from(fmt, data, offset)


def _parse_elf(
    data: bytes, filename: str
) -> tuple[tuple[ProgramLoad, ...], tuple[FunctionSymbol, ...]]:
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise PatchError(f"{filename}: not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise PatchError(f"{filename}: expected ELF64 little-endian")

    (
        _ident,
        elf_type,
        machine,
        _version,
        _entry,
        program_offset,
        section_offset,
        _flags,
        header_size,
        program_size,
        program_count,
        section_size,
        section_count,
        section_string_index,
    ) = _read_struct("<16sHHIQQQIHHHHHH", data, 0, "header")
    if elf_type != 3 or machine != 183:
        raise PatchError(f"{filename}: expected an AArch64 shared object")
    if header_size != 64 or program_size != 56 or section_size != 64:
        raise PatchError(f"{filename}: unsupported ELF header layout")
    if program_count == 0 or program_offset + program_count * program_size > len(data):
        raise PatchError(f"{filename}: invalid program-header table")

    loads: list[ProgramLoad] = []
    for index in range(program_count):
        (
            segment_type,
            flags,
            file_offset,
            virtual_address,
            _physical_address,
            file_size,
            virtual_size,
            _align,
        ) = _read_struct(
            "<IIQQQQQQ",
            data,
            program_offset + index * program_size,
            f"program header {index}",
        )
        if segment_type != PT_LOAD:
            continue
        if file_offset + file_size > len(data) or file_size > virtual_size:
            raise PatchError(f"{filename}: invalid PT_LOAD bounds")
        loads.append(
            ProgramLoad(file_offset, file_size, virtual_address, virtual_size, flags)
        )
    if not any(load.executable and load.file_size for load in loads):
        raise PatchError(f"{filename}: no executable PT_LOAD segment")

    if section_count == 0:
        raise PatchError(
            f"{filename}: missing section table needed for semantic symbols"
        )
    if section_offset + section_count * section_size > len(data):
        raise PatchError(f"{filename}: invalid section-header table")
    if section_string_index >= section_count:
        raise PatchError(f"{filename}: invalid section-name string-table index")

    sections: list[tuple[int, ...]] = []
    for index in range(section_count):
        sections.append(
            _read_struct(
                "<IIQQQQIIQQ",
                data,
                section_offset + index * section_size,
                f"section header {index}",
            )
        )

    def section_bytes(index: int) -> bytes:
        (
            _name,
            _kind,
            _flags,
            _address,
            offset,
            size,
            _link,
            _info,
            _align,
            _entry_size,
        ) = sections[index]
        if offset + size > len(data):
            raise PatchError(f"{filename}: section {index} exceeds file bounds")
        return data[offset : offset + size]

    # Reading the shstrtab as well catches a corrupt section-name reference even
    # though symbol matching below only needs each symbol table's linked strtab.
    section_bytes(section_string_index)

    def string_at(table: bytes, index: int) -> str:
        if index < 0 or index >= len(table):
            return ""
        end = table.find(b"\0", index)
        if end < 0:
            return ""
        return table[index:end].decode("utf-8", errors="replace")

    symbols: list[FunctionSymbol] = []
    for index, section in enumerate(sections):
        (
            _name,
            kind,
            _flags,
            _address,
            _offset,
            size,
            link,
            _info,
            _align,
            entry_size,
        ) = section
        if kind not in (SHT_SYMTAB, SHT_DYNSYM):
            continue
        if entry_size != 24 or size % entry_size != 0 or link >= section_count:
            raise PatchError(
                f"{filename}: invalid symbol-table layout at section {index}"
            )
        string_table = section_bytes(link)
        symbol_data = section_bytes(index)
        for symbol_offset in range(0, len(symbol_data), entry_size):
            name_index, info, _other, symbol_section, value, symbol_size = _read_struct(
                "<IBBHQQ", symbol_data, symbol_offset, "symbol entry"
            )
            if (info & 0xF) != STT_FUNC or symbol_section == 0:
                continue
            name = string_at(string_table, name_index)
            if name:
                symbols.append(FunctionSymbol(name, value, symbol_size))
    # A binary may retain both .dynsym and .symtab. Identical records are one
    # semantic symbol, while same-name records with different ranges remain
    # deliberately ambiguous and are rejected by _find_function_symbol.
    unique_symbols = tuple(dict.fromkeys(symbols))
    return tuple(loads), unique_symbols


def _executable_range_for_address(
    loads: tuple[ProgramLoad, ...], address: int, size: int
) -> tuple[int, int] | None:
    if size <= 0:
        return None
    for load in loads:
        if not load.executable:
            continue
        if (
            load.virtual_address <= address
            and address + size <= load.virtual_address + load.file_size
        ):
            start = load.file_offset + address - load.virtual_address
            return start, start + size
    return None


def _find_function_symbol(
    symbols: tuple[FunctionSymbol, ...], symbol_name: str, filename: str
) -> FunctionSymbol:
    matches = [symbol for symbol in symbols if symbol.name == symbol_name]
    if len(matches) != 1:
        raise PatchError(
            f"{filename}: semantic function anchor is missing or ambiguous: "
            f"{symbol_name}"
        )
    if matches[0].size <= 0:
        raise PatchError(
            f"{filename}: function anchor has no safe range: {symbol_name}"
        )
    return matches[0]


def _matches_at(
    data: bytes,
    offset: int,
    before: tuple[bytes, ...],
    after: tuple[bytes, ...],
    target: bytes,
) -> bool:
    before_start = offset - len(before) * 4
    after_start = offset + 4
    if before_start < 0 or after_start + len(after) * 4 > len(data):
        return False
    if data[offset : offset + 4] != target:
        return False
    for index, instruction in enumerate(before):
        start = before_start + index * 4
        if data[start : start + 4] != instruction:
            return False
    for index, instruction in enumerate(after):
        start = after_start + index * 4
        if data[start : start + 4] != instruction:
            return False
    return True


def _locate_sites(data: bytes, spec: LibrarySpec, filename: str) -> Inspection:
    loads, symbols = _parse_elf(data, filename)
    located: list[LocatedSite] = []
    seen_offsets: set[int] = set()

    for function in spec.functions:
        symbol = _find_function_symbol(symbols, function.symbol, filename)
        function_range = _executable_range_for_address(loads, symbol.value, symbol.size)
        if function_range is None:
            raise PatchError(
                f"{filename}: function anchor is outside executable PT_LOAD: "
                f"{function.symbol}"
            )
        function_start, function_end = function_range
        if function_start % 4 or function_end <= function_start:
            raise PatchError(f"{filename}: unaligned function anchor: {function.symbol}")

        for pattern in function.patterns:
            candidates: list[LocatedSite] = []
            first_offset = function_start + len(pattern.before) * 4
            last_offset = function_end - len(pattern.after) * 4 - 4
            for offset in range(first_offset, last_offset + 1, 4):
                state: str | None = None
                if _matches_at(
                    data, offset, pattern.before, pattern.after, BLR_X8
                ):
                    state = "original"
                elif _matches_at(
                    data, offset, pattern.before, pattern.after, ARM64_NOP
                ):
                    state = "patched"
                if state is not None:
                    candidates.append(LocatedSite(pattern.name, offset, state))
            if len(candidates) != pattern.count:
                raise PatchError(
                    f"{filename}: semantic anchor {pattern.name} found "
                    f"{len(candidates)} sites, expected {pattern.count}"
                )
            for candidate in candidates:
                if candidate.offset in seen_offsets:
                    raise PatchError(
                        f"{filename}: semantic anchors overlap at "
                        f"0x{candidate.offset:x}"
                    )
                seen_offsets.add(candidate.offset)
                located.append(candidate)

    if len(located) != spec.site_count:
        raise PatchError(
            f"{filename}: found {len(located)} call sites, expected {spec.site_count}"
        )
    states = {site.state for site in located}
    if states == {"original"}:
        overall_state = "original"
    elif states == {"patched"}:
        overall_state = "patched"
    else:
        raise PatchError(
            f"{filename}: call sites are in a mixed original/patched state"
        )
    return Inspection(
        overall_state, tuple(sorted(located, key=lambda site: site.offset))
    )


def inspect_data(data: bytes, spec: LibrarySpec) -> str:
    """Validate an ELF and return ``original`` or ``patched``."""

    return _locate_sites(data, spec, spec.filename).state


def read_regular_file(path: Path) -> bytes:
    if path.is_symlink():
        raise PatchError(f"refusing to patch a symlink: {path}")
    try:
        file_stat = path.stat()
    except FileNotFoundError as exc:
        raise PatchError(f"file does not exist: {path}") from exc
    if not stat.S_ISREG(file_stat.st_mode):
        raise PatchError(f"not a regular file: {path}")
    return path.read_bytes()


def inspect_file(path: Path, spec: LibrarySpec) -> Inspection:
    return _locate_sites(read_regular_file(path), spec, path.name)


def patch_file(path: Path, spec: LibrarySpec) -> str:
    data = read_regular_file(path)
    inspection = _locate_sites(data, spec, path.name)
    if inspection.state == "patched":
        return inspection.state

    patched_data = bytearray(data)
    for site in inspection.sites:
        patched_data[site.offset : site.offset + 4] = ARM64_NOP
    patched_inspection = _locate_sites(bytes(patched_data), spec, path.name)
    if patched_inspection.state != "patched":
        raise PatchError(
            f"{path.name}: generated output did not pass semantic verification"
        )

    with path.open("r+b") as output_file:
        for site in inspection.sites:
            output_file.seek(site.offset)
            output_file.write(ARM64_NOP)
        output_file.flush()
        os.fsync(output_file.fileno())

    if _locate_sites(read_regular_file(path), spec, path.name).state != "patched":
        raise PatchError(
            f"{path.name}: written output did not pass semantic verification"
        )
    return "patched"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Strictly locate and patch HyperOS ARM64 audio appname calls."
    )
    parser.add_argument("action", choices=("check", "patch"))
    parser.add_argument("--library", required=True, choices=tuple(LIBRARIES))
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument(
        "--expected",
        choices=("any", "original", "patched"),
        default="any",
        help="accepted state for the check action",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    spec = LIBRARIES[args.library]
    try:
        if args.action == "patch":
            if args.expected != "any":
                raise PatchError("--expected is only valid with the check action")
            state = patch_file(args.file, spec)
        else:
            inspection = inspect_file(args.file, spec)
            state = inspection.state
            if args.expected != "any" and state != args.expected:
                raise PatchError(
                    f"{spec.filename}: state is {state}, expected {args.expected}"
                )
    except (OSError, PatchError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
