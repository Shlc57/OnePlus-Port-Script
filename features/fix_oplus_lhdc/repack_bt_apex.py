#!/usr/bin/env python3
"""Inject the bundled LHDC bridge into a structurally compatible BT APEX.

The input and bundled-library contracts are structural.  No file hash, fixed
file size, Build ID, timestamp, ZIP layout snapshot, or binary file offset is
stored as an identity gate.

The payload is re-signed with the project AVB key.  The matching public key is
written to the APEX ``apex_pubkey`` member, which is the pre-installed key
apeXd uses for this package.  The outer JAR signature-looking members are
preserved because they are not the boot-time APEX verity trust anchor.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import importlib.util
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile


PAYLOAD_MEMBER = "apex_payload.img"
PUBKEY_MEMBER = "apex_pubkey"
MANIFEST_MEMBER = "apex_manifest.pb"
REQUIRED_MEMBERS = (
    PAYLOAD_MEMBER,
    PUBKEY_MEMBER,
    "AndroidManifest.xml",
    "apex_manifest.pb",
    "META-INF/MANIFEST.MF",
)

JNI_NAME = "libbluetooth_jni.so"
COLD_NEEDED = "libop13_lhdc_cold.so"
PREBUILT_CONTRACTS = {
    "liblhdcv5.so": {
        "required_needed": {"libc.so"},
        "exports": {
            "lhdcv5_util_get_handle",
            "lhdcv5_util_free_handle",
            "lhdcv5_util_init_encoder",
            "lhdcv5_util_enc_process",
        },
    },
    "liblhdcv5BT_enc.so": {
        "required_needed": {"liblhdcv5.so", "libc.so"},
        "exports": {
            "lhdcv5BT_get_handle",
            "lhdcv5BT_free_handle",
            "lhdcv5BT_get_bitrate",
            "lhdcv5BT_set_bitrate",
            "lhdcv5BT_set_max_bitrate",
            "lhdcv5BT_set_min_bitrate",
            "lhdcv5BT_adjust_bitrate",
            "lhdcv5BT_init_encoder",
            "lhdcv5BT_get_block_Size",
            "lhdcv5BT_encode",
        },
    },
    COLD_NEEDED: {
        "required_needed": {"libc.so", "libdl.so"},
        "exports": {
            "Java_local_mio_op13hyperosfix_BluetoothHooks_nativeApplyLhdcPatch",
            "Java_local_mio_op13hyperosfix_NativeDiagnostics_nativeProbeLhdc",
        },
    },
}
FINAL_LIBRARY_NAMES = (JNI_NAME, *PREBUILT_CONTRACTS)
AVB_ALGORITHM = "SHA256_RSA4096"

SYSTEM_LIB_CONTEXT = "u:object_r:system_lib_file:s0"
PAYLOAD_GROWTH_BYTES = 16 * 1024 * 1024
ELF_MACHINE_AARCH64 = 183
PT_LOAD = 1
PF_X = 1
PF_R = 4


class RepackError(RuntimeError):
    """The source or generated APEX violates the structural contract."""


@dataclass(frozen=True)
class BridgeContract:
    signature: bytes
    interval_offset: int
    cluster_size: int
    interval_instructions: tuple[int, int]


@dataclass(frozen=True)
class LoadSegment:
    flags: int
    offset: int
    vaddr: int
    file_size: int
    memory_size: int


@dataclass(frozen=True)
class AbiMatch:
    stub_file_offset: int
    stub_vaddr: int
    table_file_offset: int
    table_vaddr: int


@dataclass(frozen=True)
class PayloadState:
    name: str
    jni: Path
    abi: AbiMatch


def load_signing_block_helper():
    """Load the project APK Signing Block helper without relying on cwd."""

    helper_path = Path(__file__).resolve().parents[2] / "common/apk_signing_block.py"
    spec = importlib.util.spec_from_file_location("fix_oplus_lhdc_apk_signing_block", helper_path)
    if spec is None or spec.loader is None:
        raise RepackError(f"could not load APK Signing Block helper: {helper_path}")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    return helper


def read_preserved_signing_block(apex: Path) -> bytes:
    """Read the input APEX's v2/v3 block for byte-for-byte preservation."""

    require_regular_file(apex, "Bluetooth APEX")
    try:
        block, _pair_ids = load_signing_block_helper().read_signing_block(
            apex.read_bytes()
        )
    except Exception as exc:
        raise RepackError(
            "Bluetooth APEX lacks a valid input APK Signing Block; "
            "PMS requires the preserved v2/v3 block even when its content is invalid"
        ) from exc
    return block


def require_regular_file(path: Path, label: str) -> None:
    if path.is_symlink():
        raise RepackError(f"{label} must not be a symlink: {path}")
    try:
        mode = path.stat().st_mode
    except FileNotFoundError as exc:
        raise RepackError(f"{label} does not exist: {path}") from exc
    if not stat.S_ISREG(mode):
        raise RepackError(f"{label} is not a regular file: {path}")


def run(
    argv: list[str],
    *,
    check: bool = True,
    capture: bool = True,
    allowed_returncodes: tuple[int, ...] = (0,),
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        argv,
        check=False,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
    )
    if check and result.returncode not in allowed_returncodes:
        stdout = (result.stdout or "").strip()
        stderr = (result.stderr or "").strip()
        detail = "\n".join(part for part in (stdout, stderr) if part)
        raise RepackError(
            f"command failed ({result.returncode}): {' '.join(argv)}"
            + (f"\n{detail}" if detail else "")
        )
    return result


def check_tool(path: str, label: str) -> str:
    tool = Path(path)
    if "/" in path:
        require_regular_file(tool, label)
        if not os.access(tool, os.X_OK):
            raise RepackError(f"{label} is not executable: {tool}")
        return str(tool)
    resolved = shutil.which(path)
    if not resolved:
        raise RepackError(f"missing required tool: {label} ({path})")
    return resolved


def parse_bridge_contract(source: Path) -> BridgeContract:
    """Read the on-device scan signature from the bundled bridge source."""

    require_regular_file(source, "cold bridge source")
    text = source.read_text(encoding="utf-8")
    array_match = re.search(
        r"\bkStubSignature\s*=\s*\{(?P<body>.*?)\};", text, re.DOTALL
    )
    if not array_match:
        raise RepackError("cold bridge source lacks kStubSignature")
    signature = bytes(
        int(value, 16)
        for value in re.findall(r"0x([0-9a-fA-F]{2})", array_match.group("body"))
    )

    def read_cpp_integer(name: str) -> int:
        match = re.search(
            rf"\b{re.escape(name)}\s*=\s*(0x[0-9a-fA-F]+|[0-9]+)\s*;",
            text,
        )
        if not match:
            raise RepackError(f"cold bridge source lacks {name}")
        return int(match.group(1), 0)

    interval_offset = read_cpp_integer("kIntervalInstructionOffset")
    cluster_size = read_cpp_integer("kStubClusterSize")
    interval_instructions = (
        read_cpp_integer("kInterval20Instruction"),
        read_cpp_integer("kInterval10Instruction"),
    )
    if len(signature) != 48:
        raise RepackError("cold bridge kStubSignature must contain 48 bytes")
    if interval_offset < 0 or interval_offset + 4 > len(signature):
        raise RepackError("cold bridge interval instruction offset is invalid")
    if cluster_size != len(signature) + 24:
        raise RepackError("cold bridge stub cluster/trailer size contract changed")
    encoded_interval = int.from_bytes(
        signature[interval_offset : interval_offset + 4], "little"
    )
    if encoded_interval not in interval_instructions:
        raise RepackError("cold bridge signature interval instruction is inconsistent")
    return BridgeContract(
        signature=signature,
        interval_offset=interval_offset,
        cluster_size=cluster_size,
        interval_instructions=interval_instructions,
    )


def parse_elf_loads(data: bytes, name: str) -> list[LoadSegment]:
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise RepackError(f"{name} is not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise RepackError(f"{name} is not little-endian ELF64")
    elf_type, machine = struct.unpack_from("<HH", data, 16)
    if elf_type != 3 or machine != ELF_MACHINE_AARCH64:
        raise RepackError(f"{name} is not an AArch64 shared object")
    program_offset = struct.unpack_from("<Q", data, 32)[0]
    program_entry_size = struct.unpack_from("<H", data, 54)[0]
    program_count = struct.unpack_from("<H", data, 56)[0]
    if program_entry_size < 56 or program_count == 0 or program_count == 0xFFFF:
        raise RepackError(f"{name} has an unsupported program-header table")
    if program_offset + program_entry_size * program_count > len(data):
        raise RepackError(f"{name} has a truncated program-header table")

    loads: list[LoadSegment] = []
    for index in range(program_count):
        offset = program_offset + index * program_entry_size
        (
            program_type,
            flags,
            file_offset,
            vaddr,
            _physical,
            file_size,
            memory_size,
            _alignment,
        ) = struct.unpack_from("<IIQQQQQQ", data, offset)
        if program_type != PT_LOAD:
            continue
        if file_size > memory_size or file_offset + file_size > len(data):
            raise RepackError(f"{name} has an invalid PT_LOAD range")
        loads.append(
            LoadSegment(flags, file_offset, vaddr, file_size, memory_size)
        )
    if not loads:
        raise RepackError(f"{name} has no loadable segments")
    return loads


def parse_elf(data: bytes, name: str) -> None:
    loads = parse_elf_loads(data, name)
    if not any(segment.flags & PF_X for segment in loads):
        raise RepackError(f"{name} has no executable PT_LOAD")


def matches_stub(candidate: bytes, contract: BridgeContract) -> bool:
    signature = contract.signature
    interval = contract.interval_offset
    if len(candidate) != contract.cluster_size:
        return False
    if candidate[:interval] != signature[:interval]:
        return False
    if int.from_bytes(candidate[interval : interval + 4], "little") not in (
        contract.interval_instructions
    ):
        return False
    if candidate[interval + 4 : len(signature)] != signature[interval + 4 :]:
        return False
    trailer = struct.unpack_from("<6I", candidate, len(signature))
    return (
        trailer[0] == 0xD503245F
        and trailer[1] == 0xD65F03C0
        and trailer[2] == 0xD503245F
        and (trailer[3] & 0x9F00001F) == 0x90000008
        and (trailer[4] & 0xFFC003FF) == 0xB9000100
        and trailer[5] == 0xD65F03C0
    )


def validate_v5_abi(data: bytes, name: str, contract: BridgeContract) -> AbiMatch:
    """Mirror the cold bridge's unique stub and 8-slot table discovery."""

    loads = parse_elf_loads(data, name)
    clusters: list[tuple[int, int]] = []
    for segment in loads:
        if not (segment.flags & PF_X) or segment.file_size < contract.cluster_size:
            continue
        segment_data = data[segment.offset : segment.offset + segment.file_size]
        limit = len(segment_data) - contract.cluster_size
        for relative in range(0, limit + 1, 4):
            candidate = segment_data[relative : relative + contract.cluster_size]
            if matches_stub(candidate, contract):
                clusters.append(
                    (segment.offset + relative, segment.vaddr + relative)
                )
    if len(clusters) != 1:
        raise RepackError(
            f"{name} must contain exactly one compatible LHDC V5 stub cluster; "
            f"found {len(clusters)}"
        )
    stub_file_offset, stub_vaddr = clusters[0]

    expected_slots = (
        stub_vaddr,
        stub_vaddr + 8,
        stub_vaddr + 16,
        stub_vaddr + 24,
        stub_vaddr + 36,
        stub_vaddr + 48,
        stub_vaddr + 56,
    )
    executable_ranges = tuple(
        (segment.vaddr, segment.vaddr + segment.memory_size)
        for segment in loads
        if segment.flags & PF_X
    )
    tables: list[tuple[int, int]] = []
    for segment in loads:
        if not (segment.flags & PF_R) or segment.flags & PF_X or segment.file_size < 64:
            continue
        segment_data = data[segment.offset : segment.offset + segment.file_size]
        for relative in range(0, len(segment_data) - 64 + 1, 8):
            slots = struct.unpack_from("<8Q", segment_data, relative)
            getter_is_executable = any(
                start <= slots[0] < end for start, end in executable_ranges
            )
            if getter_is_executable and tuple(slots[1:]) == expected_slots:
                tables.append((segment.offset + relative, segment.vaddr + relative))
    if len(tables) != 1:
        raise RepackError(
            f"{name} must contain exactly one compatible LHDC V5 interface table; "
            f"found {len(tables)}"
        )
    table_file_offset, table_vaddr = tables[0]
    return AbiMatch(stub_file_offset, stub_vaddr, table_file_offset, table_vaddr)


def defined_dynamic_symbols(readelf: str, path: Path) -> set[str]:
    result = run([readelf, "--dyn-syms", "-W", str(path)])
    symbols: set[str] = set()
    for line in (result.stdout or "").splitlines():
        fields = line.split()
        # Num, Value, Size, Type, Bind, Vis, Ndx, Name[, Version].
        if len(fields) < 8 or fields[4] not in {"GLOBAL", "WEAK"}:
            continue
        if fields[6] == "UND":
            continue
        symbols.add(fields[7].split("@", 1)[0])
    return symbols


def undefined_dynamic_symbols(readelf: str, path: Path) -> set[str]:
    result = run([readelf, "--dyn-syms", "-W", str(path)])
    symbols: set[str] = set()
    for line in (result.stdout or "").splitlines():
        fields = line.split()
        if len(fields) < 8 or fields[4] not in {"GLOBAL", "WEAK"}:
            continue
        if fields[6] != "UND":
            continue
        symbols.add(fields[7].split("@", 1)[0])
    return symbols


def validate_prebuilt(
    path: Path,
    name: str,
    patchelf: str | None = None,
    readelf: str | None = None,
) -> None:
    require_regular_file(path, name)
    data = path.read_bytes()
    parse_elf(data, name)
    if patchelf is None or readelf is None:
        return
    contract = PREBUILT_CONTRACTS[name]
    soname = run([patchelf, "--print-soname", str(path)]).stdout.strip()
    if soname != name:
        raise RepackError(f"{name} has unexpected SONAME: {soname!r}")
    needed = print_needed(patchelf, path)
    if len(needed) != len(set(needed)) or any("/" in item for item in needed):
        raise RepackError(f"{name} has duplicate or path-based DT_NEEDED entries")
    needed_set = set(needed)
    missing = sorted(contract["required_needed"] - needed_set)
    if missing:
        raise RepackError(f"{name} lacks required DT_NEEDED entries: {missing}")
    if any(
        not re.fullmatch(r"lib[0-9A-Za-z_+.-]+\.so", item)
        for item in needed
    ):
        raise RepackError(f"{name} has an invalid DT_NEEDED library name")
    if set(needed) & {"libstdc++.so", "libc++_shared.so"}:
        raise RepackError(f"{name} depends on an unsupported C++ runtime")
    if name == "liblhdcv5BT_enc.so" and needed.count("liblhdcv5.so") != 1:
        raise RepackError("module LHDC wrapper must need liblhdcv5.so exactly once")
    symbols = defined_dynamic_symbols(readelf, path)
    missing_symbols = sorted(contract["exports"] - symbols)
    if missing_symbols:
        raise RepackError(f"{name} lacks required exported symbols: {missing_symbols}")


def validate_backend_pair(files: dict[str, Path], readelf: str) -> None:
    core = files["liblhdcv5.so"]
    wrapper = files["liblhdcv5BT_enc.so"]
    wrapper_core_imports = {
        name
        for name in undefined_dynamic_symbols(readelf, wrapper)
        if name.startswith("lhdcv5_util_")
    }
    if not wrapper_core_imports:
        raise RepackError("LHDC wrapper does not import the expected core ABI")
    core_exports = defined_dynamic_symbols(readelf, core)
    missing = sorted(wrapper_core_imports - core_exports)
    if missing:
        raise RepackError(f"LHDC core does not satisfy wrapper imports: {missing}")


def validate_signature_members(names: list[str]) -> None:
    upper_names = {name.upper(): name for name in names}
    signature_files = {
        upper_name.removesuffix(".SF")
        for upper_name in upper_names
        if upper_name.startswith("META-INF/") and upper_name.endswith(".SF")
    }
    signature_blocks = {
        upper_name.rsplit(".", 1)[0]
        for upper_name in upper_names
        if upper_name.startswith("META-INF/")
        and upper_name.rsplit(".", 1)[-1] in {"RSA", "DSA", "EC"}
    }
    if not signature_files or not signature_files & signature_blocks:
        raise RepackError(
            "Bluetooth APEX lacks a matching META-INF signature file/block pair"
        )


def zip_members(apex: Path) -> tuple[list[zipfile.ZipInfo], list[bytes]]:
    try:
        with zipfile.ZipFile(apex, "r") as archive:
            infos = archive.infolist()
            names = [info.filename for info in infos]
            seen_names: set[str] = set()
            duplicate_names: list[str] = []
            for name in names:
                if name in seen_names and name not in duplicate_names:
                    duplicate_names.append(name)
                seen_names.add(name)
            if duplicate_names:
                raise RepackError(
                    "Bluetooth APEX contains duplicate members: "
                    f"{duplicate_names}"
                )
            missing = [name for name in REQUIRED_MEMBERS if names.count(name) != 1]
            if missing:
                raise RepackError(
                    f"Bluetooth APEX lacks unique required members: {missing}"
                )
            validate_signature_members(names)
            if archive.testzip() is not None:
                raise RepackError("Bluetooth APEX ZIP CRC check failed")
            contents = [archive.read(info) for info in infos]
    except (OSError, RuntimeError, NotImplementedError, zipfile.BadZipFile) as exc:
        if isinstance(exc, RepackError):
            raise
        raise RepackError(f"cannot read Bluetooth APEX: {exc}") from exc
    return infos, contents


def unique_member_index(infos: list[zipfile.ZipInfo], name: str) -> int:
    indexes = [index for index, info in enumerate(infos) if info.filename == name]
    if len(indexes) != 1:
        raise RepackError(f"APEX member must occur exactly once: {name}")
    return indexes[0]


def read_varint(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    while offset < len(data) and shift < 70:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
        shift += 7
    raise RepackError("truncated or oversized APEX manifest varint")


def apex_manifest_name(manifest: bytes) -> str:
    """Read field 1 (name) from the small APEX manifest protobuf."""

    offset = 0
    while offset < len(manifest):
        tag, offset = read_varint(manifest, offset)
        field_number, wire_type = tag >> 3, tag & 0x07
        if field_number == 1 and wire_type == 2:
            length, offset = read_varint(manifest, offset)
            end = offset + length
            if end > len(manifest):
                raise RepackError("APEX manifest name is truncated")
            try:
                name = manifest[offset:end].decode("ascii")
            except UnicodeDecodeError as exc:
                raise RepackError("APEX manifest name is not ASCII") from exc
            if not name or "/" in name or "\\" in name:
                raise RepackError("APEX manifest name is invalid")
            return name

        if wire_type == 0:
            _, offset = read_varint(manifest, offset)
        elif wire_type == 1:
            offset += 8
        elif wire_type == 2:
            length, offset = read_varint(manifest, offset)
            offset += length
        elif wire_type == 5:
            offset += 4
        else:
            raise RepackError("APEX manifest uses an unsupported protobuf wire type")
        if offset > len(manifest):
            raise RepackError("APEX manifest field is truncated")
    raise RepackError("APEX manifest lacks a package name")


def extract_debugfs(debugfs: str, image: Path, source: str, output: Path) -> None:
    if output.exists():
        raise RepackError(f"debugfs output already exists: {output}")
    result = run([debugfs, "-R", f"dump {source} {output}", str(image)])
    output_text = (result.stdout or "") + (result.stderr or "")
    if "File not found" in output_text or not output.is_file():
        raise RepackError(f"debugfs could not extract {source}")


def read_debugfs_stat_optional(
    debugfs: str, image: Path, target: str
) -> str | None:
    result = run(
        [debugfs, "-R", f"stat {target}", str(image)],
        check=False,
    )
    output = (result.stdout or "") + (result.stderr or "")
    if "File not found" in output:
        return None
    if result.returncode != 0 or "Filesystem not open" in output:
        raise RepackError(f"debugfs could not stat {target}:\n{output.strip()}")
    return output


def read_debugfs_stat(debugfs: str, image: Path, target: str) -> str:
    output = read_debugfs_stat_optional(debugfs, image, target)
    if output is None:
        raise RepackError(f"payload path is missing: {target}")
    return output


def debugfs_write(debugfs: str, image: Path, command: str) -> str:
    result = run([debugfs, "-w", "-R", command, str(image)])
    output = (result.stdout or "") + (result.stderr or "")
    error_markers = (
        "Could not allocate",
        "File not found",
        "already exists",
        "Usage:",
        "while trying to open",
        "Filesystem not open",
    )
    if any(marker in output for marker in error_markers):
        raise RepackError(f"debugfs command failed: {command}\n{output.strip()}")
    return output


def delete_if_present(debugfs: str, image: Path, target: str) -> None:
    if read_debugfs_stat_optional(debugfs, image, target) is not None:
        debugfs_write(debugfs, image, f"rm {target}")


def set_payload_metadata(
    debugfs: str,
    image: Path,
    target: str,
    context_value_file: Path,
) -> None:
    for field, value in (
        ("mode", "0100644"),
        ("uid", "1000"),
        ("gid", "1000"),
    ):
        debugfs_write(debugfs, image, f"set_inode_field {target} {field} {value}")
    debugfs_write(
        debugfs,
        image,
        f"ea_set -f {context_value_file} {target} security.selinux",
    )


def validate_payload_stat(stat_output: str, name: str) -> None:
    scalar_patterns = (
        r"Type:\s+regular\b",
        r"Mode:\s+0644\b",
        r"User:\s+1000\b",
        r"Group:\s+1000\b",
    )
    if any(re.search(pattern, stat_output) is None for pattern in scalar_patterns):
        raise RepackError(f"invalid payload metadata for {name}:\n{stat_output}")
    xattr = re.search(
        r'security\.selinux\s+\((\d+)\)\s+=\s+"([^"]*)"', stat_output
    )
    expected_value = SYSTEM_LIB_CONTEXT + r"\000"
    if (
        xattr is None
        or int(xattr.group(1)) != len(SYSTEM_LIB_CONTEXT) + 1
        or xattr.group(2) != expected_value
    ):
        raise RepackError(f"invalid SELinux xattr for {name}:\n{stat_output}")


def print_needed(patchelf: str, path: Path) -> list[str]:
    result = run([patchelf, "--print-needed", str(path)])
    return [line.strip() for line in (result.stdout or "").splitlines() if line.strip()]


def classify_state(presence: dict[str, bool], cold_needed_count: int) -> str:
    present = [name for name, exists in presence.items() if exists]
    if not present and cold_needed_count == 0:
        return "original"
    if len(present) == len(PREBUILT_CONTRACTS) and cold_needed_count == 1:
        return "completed"
    absent = [name for name, exists in presence.items() if not exists]
    raise RepackError(
        "Bluetooth APEX is in a partial/mixed LHDC state; "
        f"present={present}, absent={absent}, cold_needed_count={cold_needed_count}"
    )


def detect_state(
    payload: Path,
    debugfs: str,
    patchelf: str,
    readelf: str,
    contract: BridgeContract,
    workspace: Path,
    expected_prebuilts: dict[str, Path],
    *,
    prefix: str,
) -> PayloadState:
    jni = workspace / f"{prefix}-{JNI_NAME}"
    extract_debugfs(debugfs, payload, f"/lib64/{JNI_NAME}", jni)
    jni_data = jni.read_bytes()
    abi = validate_v5_abi(jni_data, JNI_NAME, contract)
    needed = print_needed(patchelf, jni)

    presence = {
        name: read_debugfs_stat_optional(debugfs, payload, f"/lib64/{name}")
        is not None
        for name in PREBUILT_CONTRACTS
    }
    state_name = classify_state(presence, needed.count(COLD_NEEDED))
    if state_name == "original":
        return PayloadState(state_name, jni, abi)

    validate_payload_stat(
        read_debugfs_stat(debugfs, payload, f"/lib64/{JNI_NAME}"),
        JNI_NAME,
    )
    extracted_files: dict[str, Path] = {}
    for name in PREBUILT_CONTRACTS:
        extracted = workspace / f"{prefix}-{name}"
        extract_debugfs(debugfs, payload, f"/lib64/{name}", extracted)
        validate_prebuilt(extracted, name, patchelf, readelf)
        if extracted.read_bytes() != expected_prebuilts[name].read_bytes():
            raise RepackError(
                f"Bluetooth APEX {name} differs from the current module input"
            )
        extracted_files[name] = extracted
        validate_payload_stat(
            read_debugfs_stat(debugfs, payload, f"/lib64/{name}"),
            name,
        )
    validate_backend_pair(extracted_files, readelf)
    return PayloadState(state_name, jni, abi)


def prepare_jni(
    source: Path,
    output: Path,
    patchelf: str,
    contract: BridgeContract,
) -> None:
    require_regular_file(source, "source Bluetooth JNI")
    if output.exists():
        raise RepackError(f"prepared JNI output already exists: {output}")
    source_data = source.read_bytes()
    validate_v5_abi(source_data, JNI_NAME, contract)
    needed_before = print_needed(patchelf, source)
    if needed_before.count(COLD_NEEDED) != 0:
        raise RepackError("source Bluetooth JNI already loads the cold bridge")

    shutil.copy2(source, output)
    run([patchelf, "--add-needed", COLD_NEEDED, str(output)])
    output_data = output.read_bytes()
    validate_v5_abi(output_data, JNI_NAME, contract)
    needed_after = print_needed(patchelf, output)
    if needed_after.count(COLD_NEEDED) != 1:
        raise RepackError("prepared Bluetooth JNI must need the cold bridge once")


def filesystem_block_size(payload: Path) -> int:
    with payload.open("rb") as image:
        image.seek(1024)
        superblock = image.read(1024)
    if len(superblock) != 1024 or superblock[56:58] != b"\x53\xef":
        raise RepackError("APEX payload is not a supported ext filesystem")
    log_block_size = struct.unpack_from("<I", superblock, 24)[0]
    if log_block_size > 6:
        raise RepackError("APEX payload has an unsupported ext block size")
    block_size = 1024 << log_block_size
    if block_size < 1024 or block_size > 65536:
        raise RepackError("APEX payload ext block size is out of range")
    return block_size


def validate_avb_footer(original: bytes) -> tuple[int, int, int]:
    if len(original) < 64:
        raise RepackError("APEX payload is too small for an AVB footer")
    magic, _major, _minor, image_size, vbmeta_offset, vbmeta_size = (
        struct.unpack_from(">4sIIQQQ", original, len(original) - 64)
    )
    if magic != b"AVBf":
        raise RepackError("APEX payload lacks the expected AVB footer")
    if image_size <= 0 or image_size >= len(original):
        raise RepackError("APEX payload AVB original-image size is invalid")
    if vbmeta_offset < image_size or vbmeta_offset + vbmeta_size > len(original) - 64:
        raise RepackError("APEX payload AVB vbmeta range is invalid")
    return image_size, vbmeta_offset, vbmeta_size


def ensure_unshared(debugfs: str, payload: Path) -> None:
    result = run([debugfs, "-R", "stats", str(payload)])
    output = (result.stdout or "") + (result.stderr or "")
    features = re.search(r"Filesystem features:\s+(.+)", output)
    if features is None:
        raise RepackError("could not inspect ext filesystem features")
    if "shared_blocks" in features.group(1).split():
        raise RepackError("ext payload still has shared_blocks after unshare")


def grow_payload(
    payload: Path,
    avbtool: str,
    debugfs: str,
    e2fsck: str,
    resize2fs: str,
    truncate: str,
) -> None:
    original = payload.read_bytes()
    footer_image_size, _vbmeta_offset, _vbmeta_size = validate_avb_footer(original)
    run([avbtool, "erase_footer", "--image", str(payload)])
    filesystem_size = payload.stat().st_size
    if filesystem_size != footer_image_size or filesystem_size >= len(original):
        raise RepackError("avbtool erased an unexpected payload range")

    block_size = filesystem_block_size(payload)
    if filesystem_size % block_size:
        raise RepackError("ext filesystem image is not block aligned")
    growth = (
        (PAYLOAD_GROWTH_BYTES + block_size - 1) // block_size
    ) * block_size
    grown_size = filesystem_size + growth
    run([truncate, "-s", str(grown_size), str(payload)])
    run([resize2fs, str(payload)])
    run(
        [e2fsck, "-fy", "-E", "unshare_blocks", str(payload)],
        allowed_returncodes=(0, 1),
    )
    run([e2fsck, "-fy", str(payload)], allowed_returncodes=(0, 1))
    run([e2fsck, "-fn", str(payload)])
    ensure_unshared(debugfs, payload)


def inject_files(
    payload: Path,
    debugfs: str,
    files: dict[str, Path],
    context_value_file: Path,
) -> None:
    for name in FINAL_LIBRARY_NAMES:
        target = f"/lib64/{name}"
        delete_if_present(debugfs, payload, target)
        output = debugfs_write(debugfs, payload, f"write {files[name]} {target}")
        if "Allocated inode:" not in output:
            raise RepackError(f"debugfs did not allocate {target}")
        set_payload_metadata(debugfs, payload, target, context_value_file)
        validate_payload_stat(
            read_debugfs_stat(debugfs, payload, target),
            name,
        )


def extract_avb_public_key(avbtool: str, key: Path, output: Path) -> bytes:
    require_regular_file(key, "project AVB private key")
    if output.exists() or output.is_symlink():
        raise RepackError(f"AVB public-key output already exists: {output}")
    run(
        [
            avbtool,
            "extract_public_key",
            "--key",
            str(key),
            "--output",
            str(output),
        ]
    )
    require_regular_file(output, "extracted AVB public key")
    public_key = output.read_bytes()
    if len(public_key) == 0:
        raise RepackError("extracted AVB public key is empty")
    return public_key


def sign_payload(
    payload: Path,
    avbtool: str,
    key: Path,
    partition_name: str,
) -> None:
    require_regular_file(key, "project AVB private key")
    block_size = filesystem_block_size(payload)
    run(
        [
            avbtool,
            "add_hashtree_footer",
            "--image",
            str(payload),
            "--partition_name",
            partition_name,
            "--hash_algorithm",
            "sha256",
            "--block_size",
            str(block_size),
            "--do_not_generate_fec",
            "--algorithm",
            AVB_ALGORITHM,
            "--key",
            str(key),
            "--prop",
            f"apex.key:{partition_name}",
        ]
    )


def verify_signed_payload(
    payload: Path,
    avbtool: str,
    key: Path,
    partition_name: str,
    expected_public_key: bytes,
    workspace: Path,
) -> None:
    public_key = workspace / "verified-avb-pubkey.bin"
    actual_public_key = extract_avb_public_key(avbtool, key, public_key)
    if actual_public_key != expected_public_key:
        raise RepackError("APEX apex_pubkey does not match the project AVB key")

    image_alias = workspace / f"{partition_name}.img"
    if image_alias.exists() or image_alias.is_symlink():
        raise RepackError(f"AVB verification image alias already exists: {image_alias}")
    image_alias.symlink_to(payload)
    try:
        run([avbtool, "verify_image", "--image", str(payload), "--key", str(key)])
    finally:
        image_alias.unlink(missing_ok=True)


def clone_zip_info(info: zipfile.ZipInfo, *, payload: bool) -> zipfile.ZipInfo:
    cloned = zipfile.ZipInfo(info.filename, date_time=info.date_time)
    cloned.compress_type = zipfile.ZIP_STORED if payload else info.compress_type
    cloned.comment = info.comment
    cloned.create_system = info.create_system
    cloned.create_version = info.create_version
    cloned.extract_version = info.extract_version
    cloned.reserved = info.reserved
    cloned.internal_attr = info.internal_attr
    cloned.external_attr = info.external_attr
    cloned.volume = info.volume
    cloned.flag_bits = info.flag_bits & ~0x09
    cloned.extra = info.extra
    return cloned


def local_zip_data_offset(archive_path: Path, info: zipfile.ZipInfo) -> int:
    with archive_path.open("rb") as archive:
        archive.seek(info.header_offset)
        header = archive.read(30)
    if len(header) != 30:
        raise RepackError(f"truncated ZIP local header: {info.filename}")
    (
        signature,
        _version,
        _flags,
        _method,
        _time,
        _date,
        _crc,
        _compressed_size,
        _uncompressed_size,
        filename_length,
        extra_length,
    ) = struct.unpack("<IHHHHHIIIHH", header)
    if signature != 0x04034B50:
        raise RepackError(f"invalid ZIP local header: {info.filename}")
    return info.header_offset + 30 + filename_length + extra_length


def repack_zip(
    infos: list[zipfile.ZipInfo],
    preserved: list[bytes],
    payload: Path,
    unaligned: Path,
    output: Path,
    zipalign: str,
    replacements: dict[str, bytes] | None = None,
    signing_block: bytes | None = None,
) -> None:
    replacements = replacements or {}
    try:
        with zipfile.ZipFile(unaligned, "w", allowZip64=True) as archive:
            for info, member_data in zip(infos, preserved, strict=True):
                is_payload = info.filename == PAYLOAD_MEMBER
                cloned = clone_zip_info(info, payload=is_payload)
                if is_payload:
                    with payload.open("rb") as source_payload, archive.open(
                        cloned, "w", force_zip64=True
                    ) as destination:
                        shutil.copyfileobj(source_payload, destination, 1024 * 1024)
                else:
                    archive.writestr(
                        cloned,
                        replacements.get(info.filename, member_data),
                    )
    except (OSError, RuntimeError, NotImplementedError, zipfile.BadZipFile) as exc:
        raise RepackError(f"could not rebuild outer APEX ZIP: {exc}") from exc
    run([zipalign, "-f", "4096", str(unaligned), str(output)])
    require_regular_file(output, "repacked Bluetooth APEX")
    if signing_block is not None:
        helper = load_signing_block_helper()
        block_path = output.parent / "preserved-apk-signing-block.bin"
        if block_path.exists() or block_path.is_symlink():
            raise RepackError(f"temporary Signing Block path already exists: {block_path}")
        try:
            block_path.write_bytes(signing_block)
            helper.insert_signing_block(output, block_path)
        except Exception as exc:
            if isinstance(exc, RepackError):
                raise
            raise RepackError("could not reinsert the preserved APK Signing Block") from exc
        finally:
            block_path.unlink(missing_ok=True)

    output_infos, output_contents = zip_members(output)
    expected_names = [info.filename for info in infos]
    if [info.filename for info in output_infos] != expected_names:
        raise RepackError("repacked APEX member order changed")
    with zipfile.ZipFile(output, "r") as archive:
        payload_info = archive.getinfo(PAYLOAD_MEMBER)
        data_offset = local_zip_data_offset(output, payload_info)
        if payload_info.compress_type != zipfile.ZIP_STORED or data_offset % 4096:
            raise RepackError("APEX payload is not stored and 4096-byte aligned")
    if signing_block is not None:
        try:
            output_block, _pair_ids = load_signing_block_helper().read_signing_block(
                output.read_bytes()
            )
        except Exception as exc:
            raise RepackError("repacked Bluetooth APEX lacks a valid APK Signing Block") from exc
        if output_block != signing_block:
            raise RepackError("repacked Bluetooth APEX changed the preserved APK Signing Block")
    for index, (info, original_data) in enumerate(zip(infos, preserved, strict=True)):
        if info.filename != PAYLOAD_MEMBER and output_contents[index] != original_data:
            if info.filename not in replacements:
                raise RepackError(
                    f"repacked APEX changed preserved member bytes: {info.filename}"
                )


def validate_output(
    output: Path,
    expected_member_names: list[str],
    expected_nonpayload: list[bytes],
    debugfs: str,
    patchelf: str,
    readelf: str,
    contract: BridgeContract,
    workspace: Path,
    expected_prebuilts: dict[str, Path],
    expected_jni: Path | None,
    avbtool: str,
    avb_key: Path,
    expected_public_key: bytes,
    partition_name: str,
    expected_signing_block: bytes,
) -> None:
    infos, contents = zip_members(output)
    if [info.filename for info in infos] != expected_member_names:
        raise RepackError("output APEX member order differs from its input")
    for index, (name, original_data) in enumerate(
        zip(expected_member_names, expected_nonpayload, strict=True)
    ):
        if name == PAYLOAD_MEMBER:
            continue
        if name == PUBKEY_MEMBER:
            if contents[index] != expected_public_key:
                raise RepackError("output APEX apex_pubkey differs from the project key")
            continue
        if contents[index] != original_data:
            raise RepackError(f"output APEX did not preserve member bytes: {name}")
    try:
        output_signing_block, _pair_ids = load_signing_block_helper().read_signing_block(
            output.read_bytes()
        )
    except Exception as exc:
        raise RepackError("output Bluetooth APEX lacks the preserved APK Signing Block") from exc
    if output_signing_block != expected_signing_block:
        raise RepackError("output Bluetooth APEX changed the preserved APK Signing Block")

    payload = workspace / "verify-payload.img"
    payload_index = unique_member_index(infos, PAYLOAD_MEMBER)
    payload.write_bytes(contents[payload_index])
    verify_signed_payload(
        payload,
        avbtool,
        avb_key,
        partition_name,
        expected_public_key,
        workspace,
    )
    verified = detect_state(
        payload,
        debugfs,
        patchelf,
        readelf,
        contract,
        workspace,
        expected_prebuilts,
        prefix="verify",
    )
    if verified.name != "completed":
        raise RepackError(f"output APEX is not completed: {verified.name}")
    if expected_jni is not None and verified.jni.read_bytes() != expected_jni.read_bytes():
        raise RepackError("output payload JNI differs from the prepared OTA JNI copy")


def make_report(
    report: Path,
    source: Path,
    output: Path,
    state: PayloadState,
) -> None:
    if state.name == "original":
        signature_status = "STALE_PRESERVED_BYTES_NOT_VALID"
        action = "REPACKED_AND_INJECTED"
    else:
        signature_status = "NOT_VERIFIED_INPUT_WAS_NOT_REPACKED"
        action = "COPIED_ALREADY_COMPLETED_INPUT"
    lines = [
        "fix_oplus_lhdc Bluetooth APEX structural report",
        "",
        f"source_state={state.name}",
        f"action={action}",
        f"source_apex={source}",
        f"output_apex={output}",
        "input_contract=OTA_STRUCTURAL_NO_STATIC_FILE_IDENTITY",
        "v5_stub_contract=UNIQUE",
        "v5_interface_table_contract=UNIQUE",
        "jni_contract=STRUCTURAL_ABI_AND_DT_NEEDED",
        "jni_cold_dt_needed_count=1",
        "payload_library_metadata=1000_1000_0644_SYSTEM_LIB_FILE",
        "payload_avb_signature=VALID_SELF_SIGNED_SHA256_RSA4096",
        f"outer_meta_inf_signature={signature_status}",
        "apk_signing_block=PRESERVED_BYTE_FOR_BYTE",
        "apex_trust=PREINSTALLED_BUNDLED_PUBLIC_KEY",
        "apex_pubkey=REPLACED_WITH_PROJECT_PUBLIC_KEY",
        "all_other_nonpayload_members=PRESERVED_BYTE_FOR_BYTE_IN_INPUT_ORDER",
    ]
    lines.extend(
        [
            "",
            "The payload AVB footer, hashtree and vbmeta are generated with the",
            "project key and verified on the host. META-INF JAR signature-looking",
            "members and the APK v2/v3 Signing Block remain from the input and",
            "are not regenerated. No device,",
            "runtime or cold-boot validation is implied.",
        ]
    )
    report.write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--prebuilt-dir", required=True, type=Path)
    parser.add_argument("--bridge-source", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--debugfs", default="debugfs")
    parser.add_argument("--e2fsck", default="e2fsck")
    parser.add_argument("--resize2fs", default="resize2fs")
    parser.add_argument("--truncate", default="truncate")
    parser.add_argument("--patchelf", default="patchelf")
    parser.add_argument("--readelf", default="readelf")
    parser.add_argument("--avbtool", required=True)
    parser.add_argument("--zipalign", required=True)
    parser.add_argument("--avb-key", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        require_regular_file(args.input, "Bluetooth APEX")
        if args.input.resolve() == args.output.resolve():
            raise RepackError("input and output APEX paths must differ")
        if args.output.is_symlink() or args.report.is_symlink():
            raise RepackError("output and report paths must not be symlinks")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        require_regular_file(args.avb_key, "project AVB private key")
        tools = {
            name: check_tool(value, name)
            for name, value in (
                ("debugfs", args.debugfs),
                ("e2fsck", args.e2fsck),
                ("resize2fs", args.resize2fs),
                ("truncate", args.truncate),
                ("patchelf", args.patchelf),
                ("readelf", args.readelf),
                ("avbtool", args.avbtool),
                ("zipalign", args.zipalign),
            )
        }
        contract = parse_bridge_contract(args.bridge_source)
        prebuilt_files = {
            name: args.prebuilt_dir / name for name in PREBUILT_CONTRACTS
        }
        for name, path in prebuilt_files.items():
            validate_prebuilt(path, name, tools["patchelf"], tools["readelf"])
        validate_backend_pair(prebuilt_files, tools["readelf"])

        infos, contents = zip_members(args.input)
        preserved_signing_block = read_preserved_signing_block(args.input)
        member_names = [info.filename for info in infos]
        payload_index = unique_member_index(infos, PAYLOAD_MEMBER)
        manifest_index = unique_member_index(infos, MANIFEST_MEMBER)
        partition_name = apex_manifest_name(contents[manifest_index])
        if partition_name != "com.android.bt":
            raise RepackError(
                "Bluetooth APEX manifest name is not com.android.bt: "
                f"{partition_name}"
            )
        with tempfile.TemporaryDirectory(prefix="fix-lhdc-apex.") as temporary:
            workspace = Path(temporary)
            public_key = extract_avb_public_key(
                tools["avbtool"],
                args.avb_key,
                workspace / "project-avb-pubkey.bin",
            )
            payload = workspace / "payload.img"
            payload.write_bytes(contents[payload_index])
            state = detect_state(
                payload,
                tools["debugfs"],
                tools["patchelf"],
                tools["readelf"],
                contract,
                workspace,
                prebuilt_files,
                prefix="source",
            )
            if state.name == "completed":
                if contents[unique_member_index(infos, PUBKEY_MEMBER)] != public_key:
                    raise RepackError(
                        "completed Bluetooth APEX uses a different AVB public key"
                    )
                shutil.copy2(args.input, args.output)
                try:
                    output_block = read_preserved_signing_block(args.output)
                except RepackError as exc:
                    raise RepackError(
                        "completed Bluetooth APEX lost its input APK Signing Block"
                    ) from exc
                if output_block != preserved_signing_block:
                    raise RepackError("completed Bluetooth APEX changed its APK Signing Block")
                expected_jni = None
            else:
                prepared_jni = workspace / "prepared-libbluetooth_jni.so"
                prepare_jni(
                    state.jni,
                    prepared_jni,
                    tools["patchelf"],
                    contract,
                )
                files = {JNI_NAME: prepared_jni, **prebuilt_files}
                grow_payload(
                    payload,
                    tools["avbtool"],
                    tools["debugfs"],
                    tools["e2fsck"],
                    tools["resize2fs"],
                    tools["truncate"],
                )
                context_value = workspace / "system_lib_file.context"
                context_value.write_bytes(SYSTEM_LIB_CONTEXT.encode("ascii") + b"\0")
                inject_files(
                    payload,
                    tools["debugfs"],
                    files,
                    context_value,
                )
                run(
                    [tools["e2fsck"], "-fy", str(payload)],
                    allowed_returncodes=(0, 1),
                )
                run([tools["e2fsck"], "-fn", str(payload)])
                sign_payload(
                    payload,
                    tools["avbtool"],
                    args.avb_key,
                    partition_name,
                )
                unaligned = workspace / "repacked-unaligned.apex"
                repack_zip(
                    infos,
                    contents,
                    payload,
                    unaligned,
                    args.output,
                    tools["zipalign"],
                    replacements={PUBKEY_MEMBER: public_key},
                    signing_block=preserved_signing_block,
                )
                expected_jni = prepared_jni

            validate_output(
                args.output,
                member_names,
                contents,
                tools["debugfs"],
                tools["patchelf"],
                tools["readelf"],
                contract,
                workspace,
                prebuilt_files,
                expected_jni,
                tools["avbtool"],
                args.avb_key,
                public_key,
                partition_name,
                preserved_signing_block,
            )
        make_report(
            args.report,
            args.input,
            args.output,
            state,
        )
        print(state.name)
        return 0
    except (OSError, RepackError, ValueError, struct.error, zipfile.BadZipFile) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
