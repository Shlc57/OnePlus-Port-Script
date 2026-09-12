#!/usr/bin/env python3
"""Merge the XiaoAi PAL stream and its capture profiles into a target XML."""
import argparse
import copy
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

VENDOR_UUID = "61696d69-30f2-11e6-b0ac-40a8f03d3f1e"
PROFILE_NAMES = (
    "DUAL_MIC_16KHZ_16BIT_CUSTOM_NS_RAW",
    "SINGLE_MIC_16KHZ_16BIT_HEADSET_CUSTOM_NS_RAW",
    "DUAL_MIC_48KHZ_16BIT_CUSTOM_ECNS_RAW",
    "SINGLE_MIC_16KHZ_16BIT_HEADSET_CUSTOM_ECNS_RAW",
)


def local_name(tag):
    return tag.rsplit("}", 1)[-1]


def normalized(element):
    def shape(node):
        return (local_name(node.tag), tuple(sorted(node.attrib.items())),
                (node.text or "").strip(), tuple(shape(child) for child in node))
    return repr(shape(element)).encode("utf-8")


def children_by_name(parent, name):
    return [node for node in parent if node.attrib.get("name") == name]


def stream_has_uuid(stream):
    return any(node.attrib.get("vendor_uuid") == VENDOR_UUID for node in stream.iter())


def find_uuid_stream(root):
    matches = [node for node in root.iter()
               if local_name(node.tag) == "stream_config" and stream_has_uuid(node)]
    if len(matches) != 1:
        raise ValueError(f"vendor_uuid stream_config 数量不是 1：{len(matches)}")
    return matches[0]


def parent_of(root, child):
    for parent in root.iter():
        if child in list(parent):
            return parent
    return None


def locate_profile_parent(root):
    parents = [node for node in root.iter() if local_name(node.tag) == "capture_profile_list"]
    if len(parents) != 1:
        raise ValueError(f"capture_profile_list 节点数量不是 1：{len(parents)}")
    return parents[0]


def merge(source_path, target_path, output_path):
    try:
        source_root = ET.parse(source_path).getroot()
        target_root = ET.parse(target_path).getroot()
    except (ET.ParseError, OSError) as exc:
        raise ValueError(f"XML 解析失败：{exc}") from None

    source_stream = find_uuid_stream(source_root)
    source_stream_parent = parent_of(source_root, source_stream)
    if source_stream_parent is None or local_name(source_stream_parent.tag) != "vui_platform_info":
        raise ValueError("来源 stream_config 不在 vui_platform_info 节点中")

    source_profile_parent = locate_profile_parent(source_root)
    source_profiles = {}
    for name in PROFILE_NAMES:
        matches = children_by_name(source_profile_parent, name)
        if len(matches) != 1:
            raise ValueError(f"来源 capture_profile {name} 数量不是 1：{len(matches)}")
        source_profiles[name] = matches[0]

    target_streams = [node for node in target_root.iter()
                      if local_name(node.tag) == "stream_config" and stream_has_uuid(node)]
    if len(target_streams) > 1:
        raise ValueError("目标 vendor_uuid 重复")
    if target_streams and normalized(target_streams[0]) != normalized(source_stream):
        raise ValueError("目标 XiaoAi PAL stream_config 结构与来源不一致")

    target_profile_parent = locate_profile_parent(target_root)
    target_profiles = {}
    for name in PROFILE_NAMES:
        matches = children_by_name(target_profile_parent, name)
        if len(matches) > 1:
            raise ValueError(f"目标 capture_profile 重复：{name}")
        if matches and normalized(matches[0]) != normalized(source_profiles[name]):
            raise ValueError(f"目标 capture_profile 结构与来源不一致：{name}")
        if matches:
            target_profiles[name] = matches[0]

    profile_parent = target_profile_parent
    stream_parents = [node for node in target_root.iter()
                      if local_name(node.tag) == "vui_platform_info"]
    if len(stream_parents) != 1:
        raise ValueError(f"vui_platform_info 节点数量不是 1：{len(stream_parents)}")
    stream_parent = stream_parents[0]
    if target_streams and parent_of(target_root, target_streams[0]) is not stream_parent:
        raise ValueError("目标 stream_config 不在 vui_platform_info 节点中")

    changed = False
    for name in PROFILE_NAMES:
        if name not in target_profiles:
            profile_parent.append(copy.deepcopy(source_profiles[name]))
            changed = True
    if not target_streams:
        stream_parent.append(copy.deepcopy(source_stream))
        changed = True

    if not changed:
        data = Path(target_path).read_bytes()
    else:
        data = ET.tostring(target_root, encoding="utf-8", xml_declaration=True)
    mode = os.stat(target_path).st_mode & 0o7777
    parent = os.path.dirname(os.path.abspath(output_path)) or "."
    fd, temporary = tempfile.mkstemp(prefix=".xiaoai-pal.", dir=parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, output_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args(argv)
    try:
        merge(args.source, args.target, args.output)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
