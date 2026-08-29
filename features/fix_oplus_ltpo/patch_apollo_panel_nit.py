#!/usr/bin/env python3
"""Stage the Apollo panel-nit database and adapt its vendor path.

The XML asset is owned by this project and is therefore checked against its
project-side digest. ``libsdmcore.so`` is supplied by the base package and
may change on every OTA; it is identified only by ELF layout, the Apollo path
reference, and the instructions belonging to
``ApolloXmlParser::parseXmlFile()``. No release-wide library hash or size is
part of this contract.
"""

from __future__ import annotations

import argparse
import base64
import gzip
import hashlib
import struct
import sys
import xml.etree.ElementTree as element_tree
from pathlib import Path
from typing import Iterable, NamedTuple


OLD_PREFIX = b"/my_product/vendor/etc/display_apollo_list_"
NEW_PREFIX = b"/vendor/etc/display_apollo_list_"
PARSE_SYMBOL_SUFFIX = "ApolloXmlParser12parseXmlFileEv"
ELF_VERSION_CURRENT = 1
EM_AARCH64 = 183
PT_LOAD = 1
SHT_NULL = 0
SHT_STRTAB = 3
SHT_NOBITS = 8
SHT_SYMTAB = 2
SHT_DYNSYM = 11
PF_X = 1
PF_W = 2
PF_R = 4
SHF_ALLOC = 0x2
SHF_EXECINSTR = 0x4
PACIASP = 0xD503233F
PACIBSP = 0xD503237F
RET = 0xD65F03C0
NOP = 0xD503201F
BTI_C = 0xD503245F


class ApolloPatchError(RuntimeError):
    """An input is not an exact, safe Apollo patch candidate."""


class ProgramHeader(NamedTuple):
    type: int
    flags: int
    offset: int
    virtual_address: int
    file_size: int
    memory_size: int


class Section(NamedTuple):
    name: str
    type: int
    flags: int
    address: int
    offset: int
    size: int
    link: int
    info: int
    entry_size: int


class Symbol(NamedTuple):
    name: str
    value: int
    size: int
    section_index: int
    type: int


class ElfLayout(NamedTuple):
    program_headers: tuple[ProgramHeader, ...]
    sections: tuple[Section, ...]
    symbols: tuple[Symbol, ...]


class FunctionRange(NamedTuple):
    start: int
    end: int
    name: str


class PathCandidate(NamedTuple):
    offset: int
    virtual_address: int
    form: str


class CodeSites(NamedTuple):
    function: FunctionRange
    reference_offset: int
    length_offset: int
    length_register: int
    nul_offset: int
    state: str


def sha256_file(path: Path) -> str:
    """Hash a project-owned asset (never a base/original package file)."""

    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_regular_file(path: Path, description: str) -> None:
    if path.is_symlink() or not path.is_file():
        raise ApolloPatchError(f"{description} must be a regular file: {path}")


def parse_apollo_xml(xml_bytes: bytes) -> None:
    try:
        root = element_tree.fromstring(xml_bytes)
    except element_tree.ParseError as error:
        raise ApolloPatchError(f"Apollo XML cannot be parsed: {error}") from error

    if root.tag != "filter-conf":
        raise ApolloPatchError(f"unexpected Apollo XML root: {root.tag}")
    if (root.findtext("filter-name") or "").strip() != "display_apollo_list":
        raise ApolloPatchError("Apollo XML does not declare display_apollo_list")
    levels = root.find("Levels")
    if levels is None or levels.get("apollo") != "primary":
        raise ApolloPatchError("Apollo XML has no primary Levels database")
    try:
        declared_range = int(levels.get("range", ""))
    except ValueError as error:
        raise ApolloPatchError("Apollo XML Levels range is invalid") from error
    level_nodes = levels.findall("Level")
    if declared_range <= 0 or not level_nodes:
        raise ApolloPatchError("Apollo XML has no valid primary Levels range")
    for expected_index, level_node in enumerate(level_nodes):
        fields = [field.strip() for field in (level_node.text or "").split(",")]
        if len(fields) != 10:
            raise ApolloPatchError(
                f"Apollo XML level {expected_index} has {len(fields)} fields, expected 10"
            )
        try:
            if int(fields[0]) != expected_index:
                raise ApolloPatchError(
                    f"Apollo XML level index is not contiguous at {expected_index}"
                )
            int(fields[1])
            int(fields[2])
            for field in fields[3:]:
                float(field)
        except ValueError as error:
            raise ApolloPatchError(
                f"Apollo XML level {expected_index} contains a non-numeric field"
            ) from error


def decode_asset(asset_path: Path, expected_sha256: str) -> bytes:
    require_regular_file(asset_path, "Apollo asset")
    try:
        encoded = b"".join(asset_path.read_bytes().split())
        compressed = base64.b64decode(encoded, validate=True)
        xml_bytes = gzip.decompress(compressed)
    except (OSError, ValueError, gzip.BadGzipFile) as error:
        raise ApolloPatchError(f"Apollo asset decode failed: {error}") from error

    actual_sha256 = hashlib.sha256(xml_bytes).hexdigest()
    if actual_sha256 != expected_sha256:
        raise ApolloPatchError(
            f"Apollo XML SHA-256 mismatch: expected {expected_sha256}, got {actual_sha256}"
        )
    parse_apollo_xml(xml_bytes)
    return xml_bytes


def _checked_slice(binary: bytes, offset: int, size: int, description: str) -> bytes:
    if offset < 0 or size < 0 or offset + size > len(binary):
        raise ApolloPatchError(f"{description} exceeds the ELF file")
    return binary[offset : offset + size]


def _checked_table(
    binary: bytes, offset: int, count: int, entry_size: int, description: str
) -> None:
    """Validate an ELF table before iterating attacker-controlled counts."""

    if count < 0 or entry_size <= 0:
        raise ApolloPatchError(f"{description} has an invalid count or entry size")
    if count and (
        offset < 0
        or offset > len(binary)
        or count > (len(binary) - offset) // entry_size
    ):
        raise ApolloPatchError(f"{description} exceeds the ELF file")


def parse_elf(binary: bytes) -> ElfLayout:
    if len(binary) < 64 or binary[:4] != b"\x7fELF" or binary[4:6] != b"\x02\x01":
        raise ApolloPatchError("display core is not a little-endian ELF64 binary")

    (
        _ident,
        elf_type,
        machine,
        version,
        _entry,
        program_header_offset,
        section_header_offset,
        _flags,
        header_size,
        program_header_size,
        program_header_count,
        section_header_size,
        section_header_count,
        section_name_index,
    ) = struct.unpack_from("<16sHHIQQQIHHHHHH", binary, 0)
    if binary[6] != ELF_VERSION_CURRENT or version != ELF_VERSION_CURRENT:
        raise ApolloPatchError("display core has an unsupported ELF version")
    if machine != EM_AARCH64:
        raise ApolloPatchError("display core is not an AArch64 ELF binary")
    if header_size != 64 or program_header_size != 56:
        raise ApolloPatchError("display core has an unsupported ELF header layout")
    if elf_type not in (2, 3):  # ET_EXEC / ET_DYN; both are valid shared-code inputs.
        raise ApolloPatchError("display core has an unsupported ELF file type")
    if program_header_count == 0:
        raise ApolloPatchError("display core has no program headers")
    _checked_table(
        binary,
        program_header_offset,
        program_header_count,
        program_header_size,
        "ELF program-header table",
    )
    if section_header_count and section_header_size != 64:
        raise ApolloPatchError("display core has an unsupported section header layout")
    if section_header_count:
        _checked_table(
            binary,
            section_header_offset,
            section_header_count,
            section_header_size,
            "ELF section-header table",
        )
    if section_name_index >= section_header_count and section_header_count:
        raise ApolloPatchError("display core has an invalid section-name index")

    program_headers: list[ProgramHeader] = []
    for index in range(program_header_count):
        offset = program_header_offset + index * program_header_size
        fields = struct.unpack_from("<IIQQQQQQ", binary, offset)
        (
            type_,
            flags,
            file_offset,
            virtual_address,
            _physical,
            file_size,
            memory_size,
            _align,
        ) = fields
        _checked_slice(binary, file_offset, file_size, "ELF load segment")
        if file_size > memory_size:
            raise ApolloPatchError("ELF load segment file size exceeds memory size")
        program_headers.append(
            ProgramHeader(type_, flags, file_offset, virtual_address, file_size, memory_size)
        )
    load_segments = [segment for segment in program_headers if segment.type == PT_LOAD]
    if not load_segments:
        raise ApolloPatchError("display core has no ELF LOAD segments")
    if any(
        left.offset < right.offset + right.file_size
        and right.offset < left.offset + left.file_size
        and left.virtual_address < right.virtual_address + right.file_size
        and right.virtual_address < left.virtual_address + left.file_size
        for index, left in enumerate(load_segments)
        for right in load_segments[index + 1 :]
    ):
        raise ApolloPatchError("display core has overlapping ELF LOAD segments")

    raw_sections: list[tuple[int, int, int, int, int, int, int, int, int, int]] = []
    for index in range(section_header_count):
        offset = section_header_offset + index * section_header_size
        fields = struct.unpack_from("<IIQQQQIIQQ", binary, offset)
        (
            name_offset,
            type_,
            flags,
            address,
            file_offset,
            size,
            link,
            info,
            align,
            entry_size,
        ) = fields
        if type_ != SHT_NOBITS:  # SHT_NOBITS has no bytes to slice.
            _checked_slice(binary, file_offset, size, "ELF section")
        raw_sections.append(
            (name_offset, type_, flags, address, file_offset, size, link, info, align, entry_size)
        )

    sections: list[Section] = []
    if section_header_count:
        name_section = raw_sections[section_name_index]
        if name_section[1] != SHT_STRTAB:
            raise ApolloPatchError("display core has an invalid section-name table")
        string_table = _checked_slice(
            binary, name_section[4], name_section[5], "section-name table"
        )

        def section_name(name_offset: int) -> str:
            if name_offset >= len(string_table):
                raise ApolloPatchError("display core has an invalid section name")
            raw_name = string_table[name_offset:].split(b"\0", 1)[0]
            try:
                return raw_name.decode("ascii", "strict")
            except UnicodeDecodeError as error:
                raise ApolloPatchError("display core has a non-ASCII section name") from error

        sections = [
            Section(
                section_name(fields[0]),
                fields[1],
                fields[2],
                fields[3],
                fields[4],
                fields[5],
                fields[6],
                fields[7],
                fields[9],
            )
            for fields in raw_sections
        ]

    symbols: list[Symbol] = []
    for symbol_section in sections:
        if symbol_section.type not in (SHT_SYMTAB, SHT_DYNSYM):
            continue
        if symbol_section.link >= len(sections):
            continue
        string_section = sections[symbol_section.link]
        if string_section.type != SHT_STRTAB:
            raise ApolloPatchError("display core has an invalid symbol string table")
        strings = _checked_slice(
            binary, string_section.offset, string_section.size, "symbol strings"
        )
        entry_size = symbol_section.entry_size or 24
        if entry_size < 24:
            raise ApolloPatchError("display core has an invalid symbol table")
        if symbol_section.size % entry_size:
            raise ApolloPatchError("display core has a truncated symbol table")
        usable_size = symbol_section.size
        for offset in range(
            symbol_section.offset,
            symbol_section.offset + usable_size,
            entry_size,
        ):
            st_name, info, _other, section_index, value, size = struct.unpack_from(
                "<IBBHQQ", _checked_slice(binary, offset, 24, "symbol entry"), 0
            )
            if st_name >= len(strings):
                continue
            raw_name = strings[st_name:].split(b"\0", 1)[0]
            try:
                name = raw_name.decode("utf-8", "strict")
            except UnicodeDecodeError:
                continue
            symbols.append(Symbol(name, value, size, section_index, info & 0xF))

    return ElfLayout(tuple(program_headers), tuple(sections), tuple(symbols))


def _file_offset_to_vaddr(layout: ElfLayout, offset: int, size: int = 1) -> int:
    matches = [
        segment.virtual_address + (offset - segment.offset)
        for segment in layout.program_headers
        if segment.type == PT_LOAD
        and segment.offset <= offset
        and offset + size <= segment.offset + segment.file_size
    ]
    if len(matches) != 1:
        raise ApolloPatchError(
            f"file range {offset:#x}+{size:#x} is not in exactly one ELF LOAD segment"
        )
    return matches[0]


def _vaddr_to_file_offset(layout: ElfLayout, address: int, size: int = 1) -> int:
    matches = [
        segment.offset + (address - segment.virtual_address)
        for segment in layout.program_headers
        if segment.type == PT_LOAD
        and segment.virtual_address <= address
        and address + size <= segment.virtual_address + segment.file_size
    ]
    if len(matches) != 1:
        raise ApolloPatchError(
            f"virtual range {address:#x}+{size:#x} is not in exactly one ELF LOAD segment"
        )
    return matches[0]


def _iter_regions(
    layout: ElfLayout,
    *,
    executable: bool,
) -> Iterable[tuple[int, int, int, str]]:
    """Yield (file start, file end, flags, description) for safe ELF regions."""

    wanted: list[tuple[int, int, int, str]] = []
    for section in layout.sections:
        if not section.flags & SHF_ALLOC or section.size == 0:
            continue
        is_executable = bool(section.flags & SHF_EXECINSTR)
        if is_executable != executable or section.type == SHT_NOBITS:
            continue
        containing_segments = [
            segment
            for segment in layout.program_headers
            if segment.type == PT_LOAD
            and segment.offset <= section.offset
            and section.offset + section.size <= segment.offset + segment.file_size
        ]
        if len(containing_segments) != 1:
            continue
        segment = containing_segments[0]
        if executable:
            if not segment.flags & PF_X or not segment.flags & PF_R or segment.flags & PF_W:
                continue
        elif segment.flags & (PF_W | PF_X) or not segment.flags & PF_R:
            continue
        wanted.append((section.offset, section.offset + section.size, segment.flags, section.name))

    if wanted:
        yield from wanted
        return

    # OTA tools occasionally strip section headers. The LOAD contract still
    # gives us a safe fallback range without inventing a file-size allow-list.
    for segment in layout.program_headers:
        if segment.type != PT_LOAD or segment.file_size == 0:
            continue
        if executable and not segment.flags & PF_X:
            continue
        if not executable and (segment.flags & (PF_W | PF_X) or not segment.flags & PF_R):
            continue
        yield (
            segment.offset,
            segment.offset + segment.file_size,
            segment.flags,
            f"LOAD@{segment.offset:#x}",
        )


def _find_bytes(
    binary: bytes,
    needle: bytes,
    regions: Iterable[tuple[int, int, int, str]],
) -> list[int]:
    found: list[int] = []
    for start, end, _flags, _description in regions:
        cursor = start
        while True:
            position = binary.find(needle, cursor, end)
            if position < 0:
                break
            found.append(position)
            cursor = position + 1
    return sorted(set(found))


def find_path_candidate(binary: bytes, layout: ElfLayout) -> PathCandidate:
    readonly_regions = list(_iter_regions(layout, executable=False))
    padded_new = NEW_PREFIX + b"\0" * (len(OLD_PREFIX) - len(NEW_PREFIX))
    old_offsets = [
        offset
        for offset in _find_bytes(binary, OLD_PREFIX, readonly_regions)
        if offset + len(OLD_PREFIX) < len(binary)
        and binary[offset + len(OLD_PREFIX)] == 0
    ]
    padded_offsets = _find_bytes(binary, padded_new, readonly_regions)
    short_offsets = [
        offset
        for offset in _find_bytes(binary, NEW_PREFIX, readonly_regions)
        if binary[offset + len(NEW_PREFIX) : offset + len(NEW_PREFIX) + 1] == b"\0"
        and not any(old <= offset < old + len(OLD_PREFIX) for old in old_offsets)
    ]

    candidates: list[PathCandidate] = []
    candidates.extend(
        PathCandidate(offset, _file_offset_to_vaddr(layout, offset, len(OLD_PREFIX)), "old")
        for offset in old_offsets
    )
    candidates.extend(
        PathCandidate(offset, _file_offset_to_vaddr(layout, offset, len(padded_new)), "new-padded")
        for offset in padded_offsets
    )
    candidates.extend(
        PathCandidate(offset, _file_offset_to_vaddr(layout, offset, len(NEW_PREFIX)), "new-short")
        for offset in short_offsets
        if offset not in padded_offsets
    )
    if len(candidates) != 1:
        details = ", ".join(
            f"{candidate.form}@{candidate.offset:#x}" for candidate in candidates
        )
        raise ApolloPatchError(
            "Apollo path literal must be unique in a read-only allocated region; "
            f"found {len(candidates)} ({details or 'none'})"
        )
    return candidates[0]


def _sign_extend(value: int, bits: int) -> int:
    if value & (1 << (bits - 1)):
        value -= 1 << bits
    return value


def _decode_adrp(word: int, virtual_address: int) -> tuple[int, int] | None:
    if word & 0x9F000000 != 0x90000000:
        return None
    register = word & 0x1F
    immediate = (((word >> 5) & 0x7FFFF) << 2) | ((word >> 29) & 0x3)
    page = (virtual_address & ~0xFFF) + (_sign_extend(immediate, 21) << 12)
    return register, page


def _decode_adr(word: int, virtual_address: int) -> tuple[int, int] | None:
    if word & 0x9F000000 != 0x10000000:
        return None
    register = word & 0x1F
    immediate = (((word >> 5) & 0x7FFFF) << 2) | ((word >> 29) & 0x3)
    return register, virtual_address + _sign_extend(immediate, 21)


def _decode_add_immediate(word: int) -> tuple[int, int, int] | None:
    if word & 0xFFC00000 != 0x91000000 or word & (1 << 22):
        return None
    destination = word & 0x1F
    source = (word >> 5) & 0x1F
    immediate = (word >> 10) & 0xFFF
    return destination, source, immediate


def _is_control_transfer(word: int) -> bool:
    """Return whether an instruction can terminate/re-route the ADRP chain."""

    return bool(
        (word & 0x7C000000) == 0x14000000  # B/BL
        or (word & 0xFF000010) == 0x54000000  # B.cond
        or (word & 0x7F000000) == 0x34000000  # CBZ/CBNZ
        or (word & 0x7F000000) == 0x36000000  # TBZ/TBNZ
        or (word & 0xFFFFFC1F) in (0xD61F0000, 0xD63F0000, RET)  # BR/BLR/RET
    )


def _writes_register(word: int, register: int) -> bool:
    """Conservatively detect common instructions which overwrite ``register``."""

    if not 0 <= register < 32:
        return True
    destination = word & 0x1F
    if destination != register:
        return False
    # ADR/ADRP, ADD/SUB (immediate), logical-immediate, and move-wide all
    # write Rd. Loads and other encodings are deliberately not guessed here;
    # a control-transfer check above still prevents crossing a branch.
    return bool(
        (word & 0x9F000000) in (0x10000000, 0x90000000)
        or (word & 0x1F000000) in (0x11000000, 0x12000000)
        or (word & 0x1F800000) in (0x12800000, 0x13000000)
        or (word & 0x1F800000) in (0x52800000, 0x72800000, 0xD2800000, 0xF2800000)
    )


def find_path_references(
    binary: bytes,
    layout: ElfLayout,
    candidate: PathCandidate,
) -> list[int]:
    references: list[int] = []
    for start, end, _flags, _description in _iter_regions(layout, executable=True):
        aligned_start = (start + 3) & ~3
        aligned_end = end - (end % 4)
        for offset in range(aligned_start, aligned_end, 4):
            word = struct.unpack_from("<I", binary, offset)[0]
            virtual_address = _file_offset_to_vaddr(layout, offset, 4)
            adr = _decode_adr(word, virtual_address)
            if adr is not None and adr[1] == candidate.virtual_address:
                references.append(offset)
                continue
            adrp = _decode_adrp(word, virtual_address)
            if adrp is None:
                continue
            register, page = adrp
            for lookahead in range(1, 5):
                next_offset = offset + lookahead * 4
                if next_offset + 4 > end:
                    break
                next_word = struct.unpack_from("<I", binary, next_offset)[0]
                add = _decode_add_immediate(next_word)
                if add is not None:
                    destination, source, immediate = add
                    if (
                        destination == register
                        and source == register
                        and page + immediate == candidate.virtual_address
                    ):
                        references.append(offset)
                    break
                # Do not walk through a control transfer or an instruction
                # that obviously overwrites the ADRP destination.  This keeps
                # the small scheduling allowance from turning into a broad
                # byte-pattern search.
                if _is_control_transfer(next_word) or _writes_register(next_word, register):
                    break
    return sorted(set(references))


def _symbol_function_ranges(layout: ElfLayout) -> list[FunctionRange]:
    functions = [symbol for symbol in layout.symbols if symbol.type == 2 and symbol.value]
    ranges: list[FunctionRange] = []
    for symbol in functions:
        if not symbol.name.endswith(PARSE_SYMBOL_SUFFIX):
            continue
        try:
            start = _vaddr_to_file_offset(layout, symbol.value, 1)
        except ApolloPatchError:
            continue
        end: int | None = None
        if symbol.size:
            try:
                end = _vaddr_to_file_offset(layout, symbol.value + symbol.size - 1, 1) + 1
            except ApolloPatchError:
                end = None
        if end is None:
            following = [
                candidate.value
                for candidate in functions
                if candidate.section_index == symbol.section_index and candidate.value > symbol.value
            ]
            next_value = min(following, default=0)
            if next_value:
                try:
                    end = _vaddr_to_file_offset(layout, next_value, 1)
                except ApolloPatchError:
                    end = None
        if end is None:
            section = next(
                (
                    section
                    for section in layout.sections
                    if section.address <= symbol.value < section.address + section.size
                ),
                None,
            )
            if section is not None:
                end = section.offset + section.size
        if end is not None and start < end:
            ranges.append(FunctionRange(start, end, symbol.name))
    return ranges


def _infer_function_range(binary: bytes, layout: ElfLayout, reference: int) -> FunctionRange:
    """Infer a conservative function range when an OTA stripped symbols."""

    text_regions = list(_iter_regions(layout, executable=True))
    region = next((item for item in text_regions if item[0] <= reference < item[1]), None)
    if region is None:
        raise ApolloPatchError("Apollo path reference is outside executable code")
    start, end, _flags, _description = region
    # PACIASP is the common arm64 C++ prologue used by this library. Stop at
    # the closest preceding prologue, then at the first return after the ref.
    prologues = [
        offset
        for offset in range(max(start, reference - 0x4000), reference + 1, 4)
        if struct.unpack_from("<I", binary, offset)[0] == 0xD503233F
    ]
    inferred_start = prologues[-1] if prologues else start
    inferred_end = end
    for offset in range(reference, min(end - 3, reference + 0x4000), 4):
        if struct.unpack_from("<I", binary, offset)[0] == 0xD65F03C0:
            inferred_end = offset + 4
            break
    if inferred_start >= inferred_end:
        raise ApolloPatchError("cannot infer Apollo parser function boundaries")
    return FunctionRange(inferred_start, inferred_end, "inferred ApolloXmlParser::parseXmlFile")


def _function_for_reference(
    binary: bytes, layout: ElfLayout, reference_offsets: list[int]
) -> tuple[FunctionRange, int]:
    if not reference_offsets:
        raise ApolloPatchError("Apollo parser has no instruction reference to its path literal")
    symbol_ranges = _symbol_function_ranges(layout)
    matches = [
        (function, reference)
        for function in symbol_ranges
        for reference in reference_offsets
        if function.start <= reference < function.end
    ]
    if matches:
        unique = {(item[0].start, item[0].end, item[1]) for item in matches}
        if len(unique) != 1:
            raise ApolloPatchError("Apollo path reference is ambiguous across parser symbols")
        return matches[0]
    if len(reference_offsets) != 1:
        raise ApolloPatchError("Apollo parser path references are ambiguous")
    return _infer_function_range(binary, layout, reference_offsets[0]), reference_offsets[0]


def _decode_mov_w_imm(word: int) -> tuple[int, int] | None:
    # MOV Wd, #imm is the MOVZ (32-bit, shift 0) alias.
    if word & 0xFFE00000 != 0x52800000 or word & (3 << 21):
        return None
    return word & 0x1F, (word >> 5) & 0xFFFF


def _decode_strb_zero(word: int) -> tuple[int, int, int] | None:
    # STRB WZR, [Xn, #imm12] (unsigned immediate form).
    if word & 0xFFC00000 != 0x39000000:
        return None
    return word & 0x1F, (word >> 5) & 0x1F, (word >> 10) & 0xFFF


def _instruction_words(binary: bytes, function: FunctionRange) -> Iterable[tuple[int, int]]:
    for offset in range(function.start - function.start % 4, function.end - 3, 4):
        yield offset, struct.unpack_from("<I", binary, offset)[0]


def locate_code_sites(
    binary: bytes,
    function: FunctionRange,
    reference_offset: int,
    prefix_form: str,
) -> CodeSites:
    old_length = len(OLD_PREFIX)
    new_length = len(NEW_PREFIX)
    old_mov: list[tuple[int, int]] = []
    new_mov: list[tuple[int, int]] = []
    old_nul: list[int] = []
    new_nul: list[int] = []
    for offset, word in _instruction_words(binary, function):
        mov = _decode_mov_w_imm(word)
        if mov is not None:
            if mov[1] == old_length:
                old_mov.append((offset, mov[0]))
            elif mov[1] == new_length:
                new_mov.append((offset, mov[0]))
        strb = _decode_strb_zero(word)
        if strb is not None and strb[0] == 31 and strb[1] == 0:
            if strb[2] == old_length:
                old_nul.append(offset)
            elif strb[2] == new_length:
                new_nul.append(offset)

    def nearby_pairs(
        movs: list[tuple[int, int]], nuls: list[int]
    ) -> list[tuple[int, int, int]]:
        return [
            (mov_offset, register, nul_offset)
            for mov_offset, register in movs
            for nul_offset in nuls
            if reference_offset <= mov_offset < nul_offset <= reference_offset + 0x400
        ]

    old_pairs = nearby_pairs(old_mov, old_nul)
    new_pairs = nearby_pairs(new_mov, new_nul)
    if prefix_form == "old":
        if len(old_pairs) != 1 or new_pairs:
            raise ApolloPatchError("Apollo parser is not in a coherent original state")
        pairs, state = old_pairs, "original"
    elif len(new_pairs) == 1 and not old_pairs:
        pairs, state = new_pairs, "complete"
    elif len(old_pairs) == 1 and not new_pairs:
        # The first version of this module changed only the string literal.
        # Accept it as an upgrade-only state, without identifying it by hash.
        pairs, state = old_pairs, "prefix-only"
    else:
        raise ApolloPatchError("Apollo parser length/NUL instruction pair is ambiguous or mixed")
    length_offset, length_register, nul_offset = pairs[0]
    return CodeSites(
        function,
        reference_offset,
        length_offset,
        length_register,
        nul_offset,
        state,
    )


def inspect_library(binary: bytes) -> tuple[ElfLayout, PathCandidate, CodeSites]:
    layout = parse_elf(binary)
    candidate = find_path_candidate(binary, layout)
    references = find_path_references(binary, layout, candidate)
    function, reference = _function_for_reference(binary, layout, references)
    sites = locate_code_sites(binary, function, reference, candidate.form)
    return layout, candidate, sites


def _encode_mov_w_imm(register: int, immediate: int) -> int:
    if not 0 <= register < 32 or not 0 <= immediate <= 0xFFFF:
        raise ApolloPatchError("Apollo path length cannot be encoded as MOV W immediate")
    return 0x52800000 | (immediate << 5) | register


def apply_library_patch(binary: bytes) -> bytes:
    _layout, candidate, sites = inspect_library(binary)
    if candidate.form == "old" and sites.state != "original":
        raise ApolloPatchError("Apollo path and parser instructions are in mixed states")
    if candidate.form != "old" and sites.state not in ("prefix-only", "complete"):
        raise ApolloPatchError("Apollo path and parser instructions are in mixed states")
    if candidate.form != "old" and sites.state == "complete":
        return binary

    patched = bytearray(binary)
    if candidate.form == "old":
        padded_replacement = NEW_PREFIX + b"\0" * (len(OLD_PREFIX) - len(NEW_PREFIX))
        patched[candidate.offset : candidate.offset + len(OLD_PREFIX)] = padded_replacement

    old_word = struct.unpack_from("<I", binary, sites.length_offset)[0]
    mov = _decode_mov_w_imm(old_word)
    if mov is None:
        raise ApolloPatchError("Apollo parser length instruction changed during patch")
    struct.pack_into(
        "<I", patched, sites.length_offset, _encode_mov_w_imm(mov[0], len(NEW_PREFIX))
    )
    old_nul_word = struct.unpack_from("<I", binary, sites.nul_offset)[0]
    strb = _decode_strb_zero(old_nul_word)
    if strb is None or strb[0] != 31 or strb[1] != 0:
        raise ApolloPatchError("Apollo parser NUL instruction changed during patch")
    patched_nul_word = (old_nul_word & ~(0xFFF << 10)) | (len(NEW_PREFIX) << 10)
    struct.pack_into("<I", patched, sites.nul_offset, patched_nul_word)

    # Re-inspect the result. This catches malformed candidates and makes the
    # complete state independent of any output hash.
    _layout_after, candidate_after, sites_after = inspect_library(bytes(patched))
    if candidate_after.form not in ("new-padded", "new-short") or sites_after.state != "complete":
        raise ApolloPatchError("Apollo library did not reach a complete parser contract")
    return bytes(patched)


def patch_library(input_library: Path, output_library: Path) -> None:
    require_regular_file(input_library, "display core")
    binary = input_library.read_bytes()
    output_library.write_bytes(apply_library_patch(binary))


def stage(
    asset_path: Path,
    output_xml: Path,
    expected_xml_sha256: str,
    input_library: Path,
    output_library: Path,
) -> None:
    xml_bytes = decode_asset(asset_path, expected_xml_sha256)
    output_xml.write_bytes(xml_bytes)
    if sha256_file(output_xml) != expected_xml_sha256:
        raise ApolloPatchError("staged Apollo XML SHA-256 verification failed")
    patch_library(input_library, output_library)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset", type=Path, required=True)
    parser.add_argument("--output-xml", type=Path, required=True)
    parser.add_argument("--xml-sha256", required=True)
    parser.add_argument("--input-library", type=Path, required=True)
    parser.add_argument("--output-library", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        stage(
            args.asset,
            args.output_xml,
            args.xml_sha256,
            args.input_library,
            args.output_library,
        )
    except (ApolloPatchError, OSError, struct.error) as error:
        print(f"Apollo panel-nit patch failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
