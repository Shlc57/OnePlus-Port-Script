#!/usr/bin/env python3
"""Validate NFC APK structure without a base-package release identity list.

The reference APK is project-owned and can be checksum-verified separately.
The target APK comes from the base/original package, so this validator stores
no target hash, byte size, or release-specific ZIP metadata.  OTA revisions
are accepted when the APK remains a valid ZIP/DEX application with the same
manifest package.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import struct
import sys
import zipfile
import zlib
from pathlib import Path


class ApkContractError(ValueError):
    """The APK is not a safe candidate for this patch."""


@dataclass(frozen=True)
class ManifestContract:
    strings: frozenset[str]
    package_name: str | None


def _read_u8(data: bytes, offset: int) -> int:
    if offset < 0 or offset >= len(data):
        raise ApkContractError("binary AndroidManifest.xml has a truncated byte")
    return data[offset]


def _read_u16(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 2 > len(data):
        raise ApkContractError("binary AndroidManifest.xml has a truncated uint16")
    return struct.unpack_from("<H", data, offset)[0]


def _read_u32(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise ApkContractError("binary AndroidManifest.xml has a truncated uint32")
    return struct.unpack_from("<I", data, offset)[0]


def _read_utf8_length(data: bytes, cursor: int, end: int) -> tuple[int, int]:
    """Read one Android string-pool UTF-8 length varint."""

    if cursor < 0 or cursor >= end:
        raise ApkContractError("AndroidManifest.xml UTF-8 length is truncated")
    first = _read_u8(data, cursor)
    cursor += 1
    if not first & 0x80:
        return first, cursor
    if cursor >= end:
        raise ApkContractError("AndroidManifest.xml UTF-8 length is truncated")
    second = _read_u8(data, cursor)
    cursor += 1
    if second & 0x80:
        raise ApkContractError("AndroidManifest.xml UTF-8 length has invalid continuation")
    value = ((first & 0x7F) << 7) | second
    if cursor > end:
        raise ApkContractError("AndroidManifest.xml UTF-8 length is truncated")
    return value, cursor


def _read_utf16_length(data: bytes, cursor: int, end: int) -> tuple[int, int]:
    """Read one Android string-pool UTF-16 length varint."""

    if cursor < 0 or cursor + 2 > end:
        raise ApkContractError("AndroidManifest.xml UTF-16 length is truncated")
    first = _read_u16(data, cursor)
    cursor += 2
    if not first & 0x8000:
        return first, cursor
    if cursor + 2 > end:
        raise ApkContractError("AndroidManifest.xml UTF-16 length is truncated")
    second = _read_u16(data, cursor)
    cursor += 2
    if second & 0x8000:
        raise ApkContractError("AndroidManifest.xml UTF-16 length has invalid continuation")
    value = ((first & 0x7FFF) << 16) | second
    if cursor > end:
        raise ApkContractError("AndroidManifest.xml UTF-16 length is truncated")
    return value, cursor


def _string_pool(data: bytes, chunk_offset: int) -> list[str]:
    """Decode and bounds-check an Android resource string-pool chunk."""

    if (
        chunk_offset < 0
        or chunk_offset + 8 > len(data)
        or _read_u16(data, chunk_offset) != 0x0001
    ):
        raise ApkContractError("AndroidManifest.xml has no string-pool chunk")
    header_size = _read_u16(data, chunk_offset + 2)
    chunk_size = _read_u32(data, chunk_offset + 4)
    chunk_end = chunk_offset + chunk_size
    if (
        header_size < 28
        or chunk_size < header_size
        or chunk_end > len(data)
        or header_size > chunk_size
    ):
        raise ApkContractError("AndroidManifest.xml string-pool bounds are invalid")

    string_count = _read_u32(data, chunk_offset + 8)
    style_count = _read_u32(data, chunk_offset + 12)
    flags = _read_u32(data, chunk_offset + 16)
    strings_start = _read_u32(data, chunk_offset + 20)
    styles_start = _read_u32(data, chunk_offset + 24)
    offsets_end = header_size + string_count * 4
    if (
        offsets_end < header_size
        or offsets_end > chunk_size
        or strings_start < offsets_end
        or strings_start > chunk_size
    ):
        raise ApkContractError("AndroidManifest.xml string-pool offsets are invalid")
    if styles_start:
        if styles_start < strings_start or styles_start > chunk_size:
            raise ApkContractError("AndroidManifest.xml style-pool offset is invalid")
        string_data_end = styles_start
    else:
        string_data_end = chunk_size
    if style_count and not styles_start:
        raise ApkContractError("AndroidManifest.xml style count has no style-pool offset")

    offsets = [
        _read_u32(data, chunk_offset + header_size + index * 4)
        for index in range(string_count)
    ]
    string_data_start = chunk_offset + strings_start
    string_data_limit = chunk_offset + string_data_end
    utf8 = bool(flags & 0x00000100)
    result: list[str] = []
    for relative_offset in offsets:
        start = string_data_start + relative_offset
        if start < string_data_start or start >= string_data_limit:
            raise ApkContractError("AndroidManifest.xml string offset is invalid")
        if utf8:
            # UTF-8 pools contain UTF-16 length, UTF-8 byte length, bytes, NUL.
            _utf16_length, cursor = _read_utf8_length(data, start, string_data_limit)
            byte_length, cursor = _read_utf8_length(data, cursor, string_data_limit)
            end = cursor + byte_length
            if end < cursor or end >= string_data_limit or data[end] != 0:
                raise ApkContractError("AndroidManifest.xml UTF-8 string exceeds its chunk")
            try:
                value = data[cursor:end].decode("utf-8", "strict")
            except UnicodeDecodeError as error:
                raise ApkContractError("AndroidManifest.xml has invalid UTF-8") from error
            result.append(value)
        else:
            length, cursor = _read_utf16_length(data, start, string_data_limit)
            end = cursor + length * 2
            if end < cursor or end + 2 > string_data_limit:
                raise ApkContractError("AndroidManifest.xml UTF-16 string exceeds its chunk")
            if _read_u16(data, end) != 0:
                raise ApkContractError("AndroidManifest.xml UTF-16 string is unterminated")
            try:
                result.append(data[cursor:end].decode("utf-16le", "strict"))
            except UnicodeDecodeError as error:
                raise ApkContractError("AndroidManifest.xml has invalid UTF-16") from error
    return result


def _parse_xml_chunks(manifest: bytes) -> tuple[list[str], list[tuple[int, int, int, int]]]:
    """Return the string pool and every bounded XML chunk.

    Unknown chunk types are allowed so OTA-added namespaces/resources remain
    forward compatible; their declared bounds must still be valid.
    """

    if len(manifest) < 8 or _read_u16(manifest, 0) != 0x0003:
        raise ApkContractError("AndroidManifest.xml is not a binary XML document")
    root_header_size = _read_u16(manifest, 2)
    document_size = _read_u32(manifest, 4)
    if root_header_size < 8 or document_size != len(manifest):
        raise ApkContractError("AndroidManifest.xml document size is inconsistent")
    if root_header_size > len(manifest) - 8:
        raise ApkContractError("AndroidManifest.xml root header exceeds document")

    strings = _string_pool(manifest, root_header_size)
    chunks: list[tuple[int, int, int, int]] = []
    cursor = root_header_size
    while cursor < len(manifest):
        if cursor + 8 > len(manifest):
            raise ApkContractError("AndroidManifest.xml has a truncated chunk header")
        chunk_type = _read_u16(manifest, cursor)
        header_size = _read_u16(manifest, cursor + 2)
        chunk_size = _read_u32(manifest, cursor + 4)
        if (
            header_size < 8
            or chunk_size < header_size
            or cursor + chunk_size > len(manifest)
        ):
            raise ApkContractError("AndroidManifest.xml chunk bounds are invalid")
        chunks.append((chunk_type, cursor, header_size, chunk_size))
        cursor += chunk_size
    if cursor != len(manifest):
        raise ApkContractError("AndroidManifest.xml chunks do not end at document boundary")
    return strings, chunks


def _resolve_string(strings: list[str], index: int, field: str) -> str | None:
    if index == 0xFFFFFFFF:
        return None
    if index >= len(strings):
        raise ApkContractError(f"AndroidManifest.xml {field} string index is invalid")
    return strings[index]


def _manifest_contract(manifest: bytes) -> ManifestContract:
    strings, chunks = _parse_xml_chunks(manifest)
    package_name: str | None = None
    first_start_element_seen = False

    for chunk_type, chunk_offset, header_size, chunk_size in chunks:
        if chunk_type != 0x0102:  # RES_XML_START_ELEMENT_TYPE
            continue
        chunk_end = chunk_offset + chunk_size
        ext_start = chunk_offset + header_size
        # ResXMLTree_attrExt contains 20 bytes after the node header:
        # namespace/name plus six uint16 attribute fields.  The line and
        # comment fields are part of the 16-byte node header itself.
        if ext_start + 20 > chunk_end:
            raise ApkContractError("AndroidManifest.xml start-element header is truncated")
        element_name = _resolve_string(
            strings, _read_u32(manifest, ext_start + 4), "element name"
        )
        if element_name is None:
            raise ApkContractError("AndroidManifest.xml start element has no name")
        if not first_start_element_seen:
            first_start_element_seen = True
            if element_name != "manifest":
                raise ApkContractError("AndroidManifest.xml root element is not manifest")
        attribute_start = _read_u16(manifest, ext_start + 8)
        attribute_size = _read_u16(manifest, ext_start + 10)
        attribute_count = _read_u16(manifest, ext_start + 12)
        if attribute_start < 20 or attribute_size < 20:
            raise ApkContractError("AndroidManifest.xml attribute layout is invalid")
        attributes_start = ext_start + attribute_start
        attributes_end = attributes_start + attribute_count * attribute_size
        if (
            attributes_start < ext_start
            or attributes_end < attributes_start
            or attributes_end > chunk_end
        ):
            raise ApkContractError("AndroidManifest.xml attributes exceed their chunk")

        for index in range(attribute_count):
            attr_offset = attributes_start + index * attribute_size
            attr_namespace = _resolve_string(
                strings, _read_u32(manifest, attr_offset), "attribute namespace"
            )
            attr_name = _resolve_string(
                strings, _read_u32(manifest, attr_offset + 4), "attribute name"
            )
            value_size = _read_u16(manifest, attr_offset + 12)
            if value_size < 8:
                raise ApkContractError("AndroidManifest.xml attribute value is truncated")
            raw_value = _resolve_string(
                strings,
                _read_u32(manifest, attr_offset + 8),
                "attribute raw value",
            )
            if element_name != "manifest" or attr_name != "package" or attr_namespace is not None:
                continue
            value_type = _read_u8(manifest, attr_offset + 15)
            typed_value = None
            if value_type == 0x03:  # TYPE_STRING
                typed_value = _resolve_string(
                    strings, _read_u32(manifest, attr_offset + 16), "package value"
                )
            value = raw_value if raw_value is not None else typed_value
            if value is None or not value:
                raise ApkContractError("AndroidManifest.xml package attribute is empty")
            if package_name is not None:
                raise ApkContractError("AndroidManifest.xml has duplicate package attributes")
            package_name = value

    if not first_start_element_seen or package_name is None:
        raise ApkContractError("AndroidManifest.xml has no manifest package attribute")
    return ManifestContract(frozenset(strings), package_name)


def manifest_strings(manifest: bytes) -> set[str]:
    """Parse the string pool and validate XML chunks and package bounds."""

    strings, _chunks = _parse_xml_chunks(manifest)
    return set(strings)


def _safe_zip_name(name: str) -> bool:
    path = Path(name)
    return (
        bool(name)
        and not path.is_absolute()
        and ".." not in path.parts
        and "\\" not in name
        and "\x00" not in name
    )


@dataclass(frozen=True)
class _ApkInspection:
    manifest: ManifestContract


def _inspect_apk(path: Path, *, require_package: bool) -> _ApkInspection:
    if path.is_symlink() or not path.is_file():
        raise ApkContractError(f"APK must be a regular file: {path}")
    try:
        with zipfile.ZipFile(path) as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            if len(names) != len(set(names)):
                raise ApkContractError(f"APK has duplicate ZIP members: {path}")
            if any(not _safe_zip_name(name) for name in names):
                raise ApkContractError(f"APK has an unsafe ZIP member path: {path}")
            if "AndroidManifest.xml" not in names:
                raise ApkContractError(f"APK has no AndroidManifest.xml: {path}")
            dex_names = [
                name
                for name in names
                if name == "classes.dex"
                or (name.startswith("classes") and name.endswith(".dex"))
            ]
            if not dex_names:
                raise ApkContractError(f"APK has no classes*.dex member: {path}")
            for dex_name in dex_names:
                dex = archive.read(dex_name)
                if len(dex) < 8 or not dex.startswith(b"dex\n"):
                    raise ApkContractError(f"APK member is not a DEX file: {path}:{dex_name}")
            # Reading members verifies ZIP CRCs for this invocation, without
            # persisting target release CRC/size/hash metadata in the project.
            for info in infos:
                archive.read(info.filename)
            manifest_bytes = archive.read("AndroidManifest.xml")
            if require_package:
                manifest = _manifest_contract(manifest_bytes)
            else:
                strings, _chunks = _parse_xml_chunks(manifest_bytes)
                manifest = ManifestContract(frozenset(strings), None)
            return _ApkInspection(manifest)
    except ApkContractError:
        raise
    except (
        OSError,
        EOFError,
        IndexError,
        MemoryError,
        OverflowError,
        RuntimeError,
        ValueError,
        UnicodeError,
        struct.error,
        zipfile.BadZipFile,
        zipfile.LargeZipFile,
        zlib.error,
    ) as error:
        # Malformed OTA APKs are ordinary contract failures; never expose a
        # parser traceback from the patcher.
        raise ApkContractError(f"APK ZIP/manifest validation failed for {path}: {error}") from error


def inspect_apk(path: Path) -> set[str]:
    """Compatibility helper returning the validated manifest string pool."""

    return set(_inspect_apk(path, require_package=False).manifest.strings)


def validate(target: Path, reference: Path) -> None:
    reference_info = _inspect_apk(reference, require_package=True)
    target_info = _inspect_apk(target, require_package=True)
    reference_package = reference_info.manifest.package_name
    if target_info.manifest.package_name != reference_package:
        raise ApkContractError(
            "target APK manifest package differs from the project NFC package: "
            f"{target_info.manifest.package_name} != {reference_package}"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("target", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        validate(args.target, args.reference)
    except ApkContractError as error:
        print(f"NFC APK contract failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
