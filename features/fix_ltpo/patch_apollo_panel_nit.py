#!/usr/bin/env python3
"""Stage a verified Oplus Apollo panel-nit database and path adjustment.

The target display core is a bottom-package binary.  It looks for Apollo XML
below /my_product/vendor/etc/, whereas a port only carries a final vendor
partition.  This utility deliberately supports exactly one pre-audited string
replacement and its paired string-length instructions at a caller-provided
hash, and writes only staging outputs.
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


OLD_PREFIX = b"/my_product/vendor/etc/display_apollo_list_"
NEW_PREFIX = b"/vendor/etc/display_apollo_list_"
PATCH_OFFSET = 0x2FFD7
# ``ApolloXmlParser::parseXmlFile()`` creates the panel-specific filename with
# the literal at PATCH_OFFSET.  The original implementation copies 43 bytes
# and records the same value as std::string's logical length.  Replacing only
# the literal with the 32-byte final-vendor prefix therefore leaves embedded
# NULs and a stale length in the constructed path.  Both instructions below
# are in the same, explicitly pinned parser ABI.
PATH_LENGTH_OFFSET = 0x512D4
PATH_LENGTH_ORIGINAL = bytes.fromhex("6a058052")  # mov w10, #43
PATH_LENGTH_PATCHED = bytes.fromhex("0a048052")  # mov w10, #32
PATH_NUL_OFFSET = 0x512F8
PATH_NUL_ORIGINAL = bytes.fromhex("1fac0039")  # strb wzr, [x0, #43]
PATH_NUL_PATCHED = bytes.fromhex("1f800039")  # strb wzr, [x0, #32]
# This was the output from the earlier prefix-only revision.  It is accepted
# solely to upgrade an already-unpacked OnePlus 15 worktree to the complete
# parser contract; all other unknown intermediates are rejected.
PREFIX_ONLY_OUTPUT_SHA256 = (
    "fa03ba5a29cf6a76bc79926701017be20512afb3276b17ab4858e91b391d8896"
)
PT_LOAD = 1
PF_X = 1
PF_R = 4
SHF_ALLOC = 0x2
SHF_EXECINSTR = 0x4


class ApolloPatchError(RuntimeError):
    """An input is not an exact, safe Apollo patch candidate."""


def sha256_file(path: Path) -> str:
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


def elf64_little_endian_sections(
    binary: bytes,
) -> tuple[list[tuple[int, int, int, int]], list[tuple[str, int, int, int]]]:
    if len(binary) < 64 or binary[:4] != b"\x7fELF" or binary[4:6] != b"\x02\x01":
        raise ApolloPatchError("display core is not a little-endian ELF64 binary")

    (
        _ident,
        _type,
        _machine,
        _version,
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
    if header_size != 64 or program_header_size != 56 or section_header_size != 64:
        raise ApolloPatchError("display core has an unsupported ELF header layout")
    if section_name_index >= section_header_count:
        raise ApolloPatchError("display core has an invalid section-name index")

    program_headers: list[tuple[int, int, int, int]] = []
    for index in range(program_header_count):
        offset = program_header_offset + index * program_header_size
        if offset + program_header_size > len(binary):
            raise ApolloPatchError("display core program header exceeds file length")
        type_, flags, file_offset, _virtual, _physical, file_size, _memory, _align = (
            struct.unpack_from("<IIQQQQQQ", binary, offset)
        )
        program_headers.append((type_, flags, file_offset, file_size))

    raw_sections: list[tuple[int, int, int]] = []
    for index in range(section_header_count):
        offset = section_header_offset + index * section_header_size
        if offset + section_header_size > len(binary):
            raise ApolloPatchError("display core section header exceeds file length")
        name_offset, _type, flags, _address, file_offset, file_size, *_rest = struct.unpack_from(
            "<IIQQQQIIQQ", binary, offset
        )
        raw_sections.append((name_offset, flags, file_offset, file_size))

    name_offset, _flags, string_offset, string_size = raw_sections[section_name_index]
    del name_offset
    if string_offset + string_size > len(binary):
        raise ApolloPatchError("display core section-name table exceeds file length")
    string_table = binary[string_offset : string_offset + string_size]

    def section_name(offset: int) -> str:
        if offset >= len(string_table):
            raise ApolloPatchError("display core has an invalid section name")
        return string_table[offset:].split(b"\0", 1)[0].decode("ascii", "strict")

    sections = [
        (section_name(name), flags, offset, size)
        for name, flags, offset, size in raw_sections
    ]
    return [(type_, flags, offset, size) for type_, flags, offset, size in program_headers], sections


def verify_prefix_patch_site(binary: bytes, offset: int) -> None:
    replacement_end = offset + len(OLD_PREFIX)
    if offset != PATCH_OFFSET:
        raise ApolloPatchError(f"Apollo prefix offset mismatch: expected {PATCH_OFFSET:#x}, got {offset:#x}")

    program_headers, sections = elf64_little_endian_sections(binary)
    loads = [
        (flags, start, size)
        for type_, flags, start, size in program_headers
        if type_ == PT_LOAD and start <= offset and replacement_end <= start + size
    ]
    if len(loads) != 1:
        raise ApolloPatchError("Apollo prefix is not contained by exactly one LOAD segment")
    flags, _start, _size = loads[0]
    if flags & PF_X or not flags & PF_R:
        raise ApolloPatchError("Apollo prefix is not in a read-only non-executable LOAD segment")

    containing_sections = [
        (name, section_flags)
        for name, section_flags, start, size in sections
        if start <= offset and replacement_end <= start + size
    ]
    if len(containing_sections) != 1 or containing_sections[0][0] != ".rodata":
        raise ApolloPatchError(
            f"Apollo prefix is not exclusively in allocated .rodata: {containing_sections}"
        )
    if not containing_sections[0][1] & SHF_ALLOC or containing_sections[0][1] & SHF_EXECINSTR:
        raise ApolloPatchError("Apollo prefix unexpectedly has executable section flags")


def verify_code_patch_site(binary: bytes, offset: int, expected: bytes) -> None:
    if len(expected) != 4:
        raise ApolloPatchError("Apollo parser instruction must be exactly four bytes")
    if binary[offset : offset + len(expected)] != expected:
        raise ApolloPatchError(f"Apollo parser instruction differs at {offset:#x}")

    program_headers, sections = elf64_little_endian_sections(binary)
    loads = [
        (flags, start, size)
        for type_, flags, start, size in program_headers
        if type_ == PT_LOAD and start <= offset and offset + len(expected) <= start + size
    ]
    if len(loads) != 1:
        raise ApolloPatchError("Apollo parser instruction is not contained by exactly one LOAD segment")
    flags, _start, _size = loads[0]
    if not flags & PF_X or not flags & PF_R:
        raise ApolloPatchError("Apollo parser instruction is not in an executable read-only LOAD segment")

    containing_sections = [
        (name, section_flags)
        for name, section_flags, start, size in sections
        if start <= offset and offset + len(expected) <= start + size
    ]
    if len(containing_sections) != 1 or containing_sections[0][0] != ".text":
        raise ApolloPatchError(
            f"Apollo parser instruction is not exclusively in .text: {containing_sections}"
        )
    if not containing_sections[0][1] & SHF_ALLOC or not containing_sections[0][1] & SHF_EXECINSTR:
        raise ApolloPatchError("Apollo parser instruction unexpectedly lacks executable section flags")


def verify_library_state(binary: bytes, state: str) -> None:
    padded_replacement = NEW_PREFIX + b"\0" * (len(OLD_PREFIX) - len(NEW_PREFIX))
    verify_prefix_patch_site(binary, PATCH_OFFSET)

    if state == "original":
        if binary.count(OLD_PREFIX) != 1:
            raise ApolloPatchError("original display core does not contain a unique Apollo prefix")
        if binary[PATCH_OFFSET : PATCH_OFFSET + len(OLD_PREFIX)] != OLD_PREFIX:
            raise ApolloPatchError("original display core has unexpected Apollo prefix bytes")
        verify_code_patch_site(binary, PATH_LENGTH_OFFSET, PATH_LENGTH_ORIGINAL)
        verify_code_patch_site(binary, PATH_NUL_OFFSET, PATH_NUL_ORIGINAL)
        return
    if state == "prefix-only":
        if binary.count(padded_replacement) != 1:
            raise ApolloPatchError("prefix-only display core does not contain a unique Apollo prefix")
        if binary[PATCH_OFFSET : PATCH_OFFSET + len(OLD_PREFIX)] != padded_replacement:
            raise ApolloPatchError("prefix-only display core has invalid Apollo prefix bytes")
        verify_code_patch_site(binary, PATH_LENGTH_OFFSET, PATH_LENGTH_ORIGINAL)
        verify_code_patch_site(binary, PATH_NUL_OFFSET, PATH_NUL_ORIGINAL)
        return
    if state == "complete":
        if binary.count(padded_replacement) != 1:
            raise ApolloPatchError("complete display core does not contain a unique Apollo prefix")
        if binary[PATCH_OFFSET : PATCH_OFFSET + len(OLD_PREFIX)] != padded_replacement:
            raise ApolloPatchError("complete display core has invalid Apollo prefix bytes")
        verify_code_patch_site(binary, PATH_LENGTH_OFFSET, PATH_LENGTH_PATCHED)
        verify_code_patch_site(binary, PATH_NUL_OFFSET, PATH_NUL_PATCHED)
        return
    raise ApolloPatchError(f"unknown Apollo display-core state: {state}")


def apply_complete_patch(binary: bytes, patch_prefix: bool) -> bytes:
    patched = bytearray(binary)
    if patch_prefix:
        padded_replacement = NEW_PREFIX + b"\0" * (len(OLD_PREFIX) - len(NEW_PREFIX))
        patched[PATCH_OFFSET : PATCH_OFFSET + len(OLD_PREFIX)] = padded_replacement
    patched[PATH_LENGTH_OFFSET : PATH_LENGTH_OFFSET + 4] = PATH_LENGTH_PATCHED
    patched[PATH_NUL_OFFSET : PATH_NUL_OFFSET + 4] = PATH_NUL_PATCHED
    return bytes(patched)


def patch_library(
    input_library: Path,
    output_library: Path,
    expected_input_sha256: str,
    expected_output_sha256: str,
) -> None:
    require_regular_file(input_library, "display core")
    binary = input_library.read_bytes()
    input_sha256 = hashlib.sha256(binary).hexdigest()

    if input_sha256 == expected_output_sha256:
        verify_library_state(binary, "complete")
        patched = binary
    elif input_sha256 == expected_input_sha256:
        verify_library_state(binary, "original")
        patched = apply_complete_patch(binary, patch_prefix=True)
    elif input_sha256 == PREFIX_ONLY_OUTPUT_SHA256:
        verify_library_state(binary, "prefix-only")
        patched = apply_complete_patch(binary, patch_prefix=False)
    else:
        raise ApolloPatchError(
            "unsupported display core SHA-256: "
            f"expected {expected_input_sha256}, {PREFIX_ONLY_OUTPUT_SHA256}, or "
            f"{expected_output_sha256}, got {input_sha256}"
        )

    output_sha256 = hashlib.sha256(patched).hexdigest()
    if output_sha256 != expected_output_sha256:
        raise ApolloPatchError(
            f"patched display core SHA-256 mismatch: expected {expected_output_sha256}, got {output_sha256}"
        )
    verify_library_state(patched, "complete")
    output_library.write_bytes(patched)


def stage(
    asset_path: Path,
    output_xml: Path,
    expected_xml_sha256: str,
    input_library: Path,
    output_library: Path,
    expected_input_library_sha256: str,
    expected_output_library_sha256: str,
) -> None:
    xml_bytes = decode_asset(asset_path, expected_xml_sha256)
    output_xml.write_bytes(xml_bytes)
    if sha256_file(output_xml) != expected_xml_sha256:
        raise ApolloPatchError("staged Apollo XML SHA-256 verification failed")
    patch_library(
        input_library,
        output_library,
        expected_input_library_sha256,
        expected_output_library_sha256,
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--asset", type=Path, required=True)
    parser.add_argument("--output-xml", type=Path, required=True)
    parser.add_argument("--xml-sha256", required=True)
    parser.add_argument("--input-library", type=Path, required=True)
    parser.add_argument("--output-library", type=Path, required=True)
    parser.add_argument("--input-library-sha256", required=True)
    parser.add_argument("--output-library-sha256", required=True)
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
            args.input_library_sha256,
            args.output_library_sha256,
        )
    except (ApolloPatchError, OSError) as error:
        print(f"Apollo panel-nit patch failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
