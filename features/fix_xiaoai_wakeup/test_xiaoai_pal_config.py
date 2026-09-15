import os
import stat
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import xiaoai_pal_config as tool

PROFILES = tool.PROFILE_NAMES


def profile_xml(name):
    return f'<capture_profile name="{name}"><param value="16" /></capture_profile>'


def source_xml():
    profiles = "".join(profile_xml(name) for name in PROFILES)
    return ("<audio><vui_platform_info><stream_config vendor_uuid=\"%s\" "
            "capture_profile=\"%s\"><param mode=\"voice\" /></stream_config>"
            "</vui_platform_info><capture_profile_list>%s</capture_profile_list></audio>" %
            (tool.VENDOR_UUID, PROFILES[0], profiles))


def target_xml(names=()):
    profiles = "".join(profile_xml(name) for name in names)
    return "<audio><vui_platform_info></vui_platform_info><capture_profile_list>%s</capture_profile_list></audio>" % profiles


class XiaoAiPalConfigTest(unittest.TestCase):
    def run_merge(self, source, target, mode=0o640):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source_path = root / "source.xml"
            target_path = root / "target.xml"
            output_path = root / "output.xml"
            source_path.write_text(source, encoding="utf-8")
            target_path.write_text(target, encoding="utf-8")
            os.chmod(target_path, mode)
            tool.merge(str(source_path), str(target_path), str(output_path))
            return output_path.read_bytes(), stat.S_IMODE(output_path.stat().st_mode)

    def test_adds_stream_and_profiles(self):
        data, mode = self.run_merge(source_xml(), target_xml())
        root = ET.fromstring(data)
        self.assertEqual(mode, 0o640)
        self.assertEqual(len([n for n in root.iter() if n.attrib.get("vendor_uuid") == tool.VENDOR_UUID]), 1)
        self.assertEqual({n.attrib["name"] for n in root.iter() if n.tag == "capture_profile"}, set(PROFILES))

    def test_idempotent_existing_structure(self):
        target = target_xml(PROFILES).replace(
            "<vui_platform_info></vui_platform_info>",
            '<vui_platform_info><stream_config vendor_uuid="%s" capture_profile="%s"><param mode="voice" /></stream_config></vui_platform_info>' %
            (tool.VENDOR_UUID, PROFILES[0]))
        first, _ = self.run_merge(source_xml(), target)
        second, _ = self.run_merge(source_xml(), first.decode("utf-8"))
        self.assertEqual(first, second)

    def test_rejects_conflicting_profile(self):
        with self.assertRaisesRegex(ValueError, "结构与来源不一致"):
            self.run_merge(source_xml(), target_xml((PROFILES[0],)).replace("value=\"16\"", "value=\"8\""))

    def test_rejects_missing_profile_parent(self):
        with self.assertRaisesRegex(ValueError, "capture_profile_list"):
            self.run_merge(source_xml(), "<audio><vui_platform_info></vui_platform_info></audio>")

    def test_rejects_duplicate_source_profile_parent(self):
        source = source_xml()[:-len("</audio>")] + "<capture_profile_list></capture_profile_list></audio>"
        with self.assertRaisesRegex(ValueError, "capture_profile_list.*2"):
            self.run_merge(source, target_xml())

    def test_rejects_duplicate_profile_parent(self):
        target = target_xml()[:-len("</audio>")] + "<capture_profile_list></capture_profile_list></audio>"
        with self.assertRaisesRegex(ValueError, "capture_profile_list.*2"):
            self.run_merge(source_xml(), target)

    def test_rejects_duplicate_uuid(self):
        target = target_xml().replace(
            "<vui_platform_info></vui_platform_info>",
            '<vui_platform_info><stream_config vendor_uuid="%s" /><stream_config vendor_uuid="%s" /></vui_platform_info>' %
            (tool.VENDOR_UUID, tool.VENDOR_UUID))
        with self.assertRaisesRegex(ValueError, "重复"):
            self.run_merge(source_xml(), target)


if __name__ == "__main__":
    unittest.main()
