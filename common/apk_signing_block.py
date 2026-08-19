#!/usr/bin/env python3

import struct
import sys
from pathlib import Path


EOCD_SIGNATURE = b"PK\x05\x06"
CENTRAL_DIRECTORY_SIGNATURE = b"PK\x01\x02"
SIGNING_BLOCK_MAGIC = b"APK Sig Block 42"
SIGNATURE_SCHEME_IDS = {
    0x7109871A,
    0xF05368C0,
    0x1B93AD61,
}


class SigningBlockError(Exception):
    pass


def find_eocd(data):
    search_start = max(0, len(data) - 22 - 0xFFFF)
    search_end = len(data)

    while True:
        offset = data.rfind(EOCD_SIGNATURE, search_start, search_end)
        if offset < 0:
            raise SigningBlockError("找不到 ZIP EOCD")
        if offset + 22 <= len(data):
            comment_length = struct.unpack_from("<H", data, offset + 20)[0]
            if offset + 22 + comment_length == len(data):
                break
        search_end = offset

    (
        disk_number,
        central_directory_disk,
        disk_entries,
        total_entries,
        central_directory_size,
        central_directory_offset,
    ) = struct.unpack_from("<HHHHII", data, offset + 4)

    if disk_number != 0 or central_directory_disk != 0 or disk_entries != total_entries:
        raise SigningBlockError("不支持分卷 ZIP APK")
    if (
        disk_entries == 0xFFFF
        or total_entries == 0xFFFF
        or central_directory_size == 0xFFFFFFFF
        or central_directory_offset == 0xFFFFFFFF
    ):
        raise SigningBlockError("不支持 ZIP64 APK")
    if central_directory_offset + central_directory_size != offset:
        raise SigningBlockError("ZIP 中央目录范围异常")
    if (
        total_entries
        and data[central_directory_offset:central_directory_offset + 4]
        != CENTRAL_DIRECTORY_SIGNATURE
    ):
        raise SigningBlockError("ZIP 中央目录签名异常")

    return offset, central_directory_offset


def validate_signing_block(block):
    if len(block) < 32 or block[-16:] != SIGNING_BLOCK_MAGIC:
        raise SigningBlockError("APK Signing Block 无效")

    block_size = struct.unpack_from("<Q", block, 0)[0]
    if block_size + 8 != len(block):
        raise SigningBlockError("APK Signing Block 长度异常")
    if struct.unpack_from("<Q", block, len(block) - 24)[0] != block_size:
        raise SigningBlockError("APK Signing Block 首尾长度不一致")

    pair_ids = []
    position = 8
    pairs_end = len(block) - 24
    while position < pairs_end:
        if position + 8 > pairs_end:
            raise SigningBlockError("APK Signing Block 条目长度异常")
        pair_size = struct.unpack_from("<Q", block, position)[0]
        position += 8
        if pair_size < 4 or position + pair_size > pairs_end:
            raise SigningBlockError("APK Signing Block 条目越界")
        pair_ids.append(struct.unpack_from("<I", block, position)[0])
        position += pair_size

    if position != pairs_end:
        raise SigningBlockError("APK Signing Block 条目范围异常")
    if not SIGNATURE_SCHEME_IDS.intersection(pair_ids):
        raise SigningBlockError("APK Signing Block 中未发现 v2/v3 签名方案")

    return pair_ids


def read_signing_block(apk_data):
    _, central_directory_offset = find_eocd(apk_data)
    if central_directory_offset < 24:
        raise SigningBlockError("APK Signing Block 不存在")
    if apk_data[central_directory_offset - 16:central_directory_offset] != SIGNING_BLOCK_MAGIC:
        raise SigningBlockError("APK Signing Block 不存在，请使用原始已签名 APK")

    block_size = struct.unpack_from("<Q", apk_data, central_directory_offset - 24)[0]
    block_start = central_directory_offset - block_size - 8
    if block_start < 0:
        raise SigningBlockError("APK Signing Block 长度异常")

    block = apk_data[block_start:central_directory_offset]
    pair_ids = validate_signing_block(block)
    return block, pair_ids


def extract_signing_block(apk_path, output_path):
    block, pair_ids = read_signing_block(apk_path.read_bytes())
    output_path.write_bytes(block)
    print(",".join("0x{:08x}".format(pair_id) for pair_id in pair_ids))


def insert_signing_block(apk_path, block_path):
    apk_data = apk_path.read_bytes()
    block = block_path.read_bytes()
    validate_signing_block(block)

    eocd_offset, central_directory_offset = find_eocd(apk_data)
    if (
        central_directory_offset >= 24
        and apk_data[central_directory_offset - 16:central_directory_offset]
        == SIGNING_BLOCK_MAGIC
    ):
        raise SigningBlockError("目标 APK 已包含 Signing Block，拒绝重复回插")

    new_central_directory_offset = central_directory_offset + len(block)
    if new_central_directory_offset > 0xFFFFFFFF:
        raise SigningBlockError("回插 Signing Block 后需要 ZIP64，当前工具不支持")

    patched_data = bytearray(
        apk_data[:central_directory_offset]
        + block
        + apk_data[central_directory_offset:]
    )
    new_eocd_offset = eocd_offset + len(block)
    struct.pack_into("<I", patched_data, new_eocd_offset + 16, new_central_directory_offset)
    apk_path.write_bytes(patched_data)


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in {"extract", "insert"}:
        print(
            "用法：apk_signing_block.py <extract|insert> <APK> <Signing Block 文件>",
            file=sys.stderr,
        )
        return 2

    command = sys.argv[1]
    apk_path = Path(sys.argv[2])
    block_path = Path(sys.argv[3])

    try:
        if command == "extract":
            extract_signing_block(apk_path, block_path)
        else:
            insert_signing_block(apk_path, block_path)
    except (OSError, SigningBlockError) as error:
        print("[!] {}".format(error), file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
