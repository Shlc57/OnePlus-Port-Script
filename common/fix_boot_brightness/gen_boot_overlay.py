#!/usr/bin/env python3
"""生成机型启动亮度 Overlay：替换 dimen 浮点值并对齐重打包。

用法: python3 gen_boot_overlay.py <输入.apk> <输出.apk> <旧浮点值> <新浮点值>
"""
import struct
import sys
import zipfile
import zlib

ALIGN = 4


def read_local_data_offset(f, info):
    """读取 local header 中记录的 data offset。"""
    f.seek(info.header_offset)
    local = f.read(30)
    name_len, extra_len = struct.unpack("<HH", local[26:30])
    return info.header_offset + 30 + name_len + extra_len


def check_aligned(path):
    """校验所有 entry data offset 是否 4 字节对齐（zipalign -c 4 等价）。"""
    with open(path, "rb") as f:
        z = zipfile.ZipFile(f)
        for info in z.infolist():
            off = read_local_data_offset(f, info)
            if off % ALIGN != 0:
                return False, info.filename, off
    return True, None, None


def align_repack(in_path, out_path, replace_map):
    """按 entry 顺序重写 zip，每个 entry data 从 4 字节边界开始。

    replace_map: {entry_name: (old_bytes, new_bytes)} 原地替换 data。
    """
    zin = zipfile.ZipFile(in_path)
    entries = []
    for info in zin.infolist():
        data = zin.read(info.filename)
        if info.filename in replace_map:
            old, new = replace_map[info.filename]
            count = data.count(old)
            if count != 1:
                raise SystemExit(f"替换目标 {info.filename} 中匹配 {count} 处，预期 1 处")
            data = data.replace(old, new)
        entries.append((info, data))

    with open(out_path, "wb") as out:
        central = []
        offset = 0
        for info, data in entries:
            name = info.filename.encode("utf-8")
            method = info.compress_type
            if method == zipfile.ZIP_STORED:
                cdata = data
            elif method == zipfile.ZIP_DEFLATED:
                co = zlib.compressobj(6, zlib.DEFLATED, -15)
                cdata = co.compress(data) + co.flush()
            else:
                raise SystemExit(f"不支持的压缩方式: {method}")

            crc = zlib.crc32(data) & 0xFFFFFFFF

            # local header + name + extra；extra 用于填充使 data 4 对齐
            header_size = 30 + len(name)
            extra_len = 0
            if (offset + header_size) % ALIGN != 0:
                extra_len = ALIGN - ((offset + header_size) % ALIGN)
            extra = b"\x00" * extra_len

            local = struct.pack(
                "<IHHHHHIIIHH",
                0x04034B50,  # signature
                20,  # version needed
                0x0800,  # flags: UTF-8
                method,
                0,  # mod time
                0,  # mod date
                crc,
                len(cdata),
                len(data),
                len(name),
                len(extra),
            )
            out.write(local)
            out.write(name)
            out.write(extra)
            data_start = offset + 30 + len(name) + extra_len
            assert data_start % ALIGN == 0, f"{info.filename} 未对齐: {data_start}"
            out.write(cdata)

            # central directory 条目
            central.append(
                struct.pack(
                    "<IHHHHHHIIIHHHHHII",
                    0x02014B50,  # signature
                    20,  # version made by
                    20,  # version needed
                    0x0800,
                    method,
                    0,
                    0,
                    crc,
                    len(cdata),
                    len(data),
                    len(name),
                    0,  # extra len
                    0,  # comment len
                    0,  # disk number
                    0,  # internal attrs
                    0,  # external attrs
                    offset,
                )
                + name
            )
            offset = data_start + len(cdata)

        central_offset = offset
        for c in central:
            out.write(c)
        eocd = struct.pack(
            "<IHHHHIIH",
            0x06054B50,
            0,
            0,
            len(entries),
            len(entries),
            len(b"".join(central)),
            central_offset,
            0,
        )
        out.write(eocd)
    return out_path


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    old_val, new_val = float(sys.argv[3]), float(sys.argv[4])
    old_b = struct.pack("<f", old_val)
    new_b = struct.pack("<f", new_val)
    print(f"替换: {old_val} ({old_b.hex()}) -> {new_val} ({new_b.hex()})")

    # 先读原 arsc 确认值存在
    with zipfile.ZipFile(src) as z:
        arsc = z.read("resources.arsc")
        n = arsc.count(old_b)
        if n != 1:
            raise SystemExit(f"resources.arsc 中匹配 {n} 处，预期 1 处")

    align_repack(src, dst, {"resources.arsc": (old_b, new_b)})
    ok, name, off = check_aligned(dst)
    if not ok:
        raise SystemExit(f"对齐失败: {name} @ {off}")
    print(f"✅ 输出: {dst}")
    print(f"✅ 对齐校验通过（所有 entry 4 字节对齐）")

    with zipfile.ZipFile(dst) as z:
        arsc2 = z.read("resources.arsc")
        assert arsc2.count(new_b) == 1, "替换后新值数量异常"
        # float32 精度：比较原始字节而非数值
        assert struct.pack("<f", struct.unpack_from("<f", arsc2, 576)[0]) == new_b, "偏移 576 值不正确"
    print(f"✅ 新值 {new_val} 已写入 resources.arsc（偏移 576）")
