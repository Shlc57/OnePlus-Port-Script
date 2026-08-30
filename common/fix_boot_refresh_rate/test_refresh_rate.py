#!/usr/bin/env python3
import json
import os
import subprocess
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


SCRIPT = Path(__file__).with_name("refresh_rate.py")
PORT_MAIN = SCRIPT.parents[2] / "port_main.sh"


class RefreshRateTest(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self):
        self.temporary_directory.cleanup()

    def write(self, name: str, content: str) -> Path:
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")
        return path

    def inputs(self, versions: str = "6") -> dict[str, Path]:
        vendor = self.write("vendor.prop", "ro.board.platform=canoe\n")
        odm = self.write(
            "odm.prop",
            """
            import /odm/build.prop
            ro.vendor.display.default_fps=60
            ro.vendor.display.fod_monitor_default_fps=120
            ro.vendor.display.dynamic_refresh_rate=120,90,60,30:100,60,5
            ro.vendor.mi_sf.new_dynamic_refresh_rate=120,60:5
            """,
        )
        version_lines = "\n".join(
            f"        setprop vendor.display.target.version {value}"
            for value in versions.split(",")
        )
        init_script = self.write(
            "init.sh",
            f"""
            target=`getprop ro.board.platform`
            case "$target" in
                "canoe")
                case "$soc_hwid" in
                  660|661)
            {version_lines}
                    ;;
                esac
                ;;
            esac
            """,
        )
        advanced = self.write(
            "advanced.xml",
            """
            <AdvancedSfOffsets>
              <Device version="6">
                <FpsOffsetMap fps="20" />
                <FpsOffsetMap fps="30" />
                <FpsOffsetMap fps="60" />
                <FpsOffsetMap fps="90" />
                <FpsOffsetMap fps="120" />
                <FpsOffsetMap fps="144" />
                <FpsOffsetMap fps="165" />
              </Device>
            </AdvancedSfOffsets>
            """,
        )
        resolution = self.write(
            "resolution.xml",
            """
            <Targets>
              <Target name="canoe">
                <PanelResolution width="1272" height="2772">
                  <ScalingResolution w="1080" h="2354" />
                </PanelResolution>
              </Target>
              <Target name="anorak">
                <PanelResolution width="7104" height="3840" />
              </Target>
            </Targets>
            """,
        )
        feature = self.write(
            "feature.xml",
            """
            <features>
                <!-- Display BEGIN -->
                <integer name="smart_fps_value">120</integer>
                <integer-array name="fpsList">
                    <item>120</item>
                    <item>60</item>
                </integer-array>
            </features>
            """,
        )
        return {
            "vendor": vendor,
            "odm": odm,
            "init": init_script,
            "advanced": advanced,
            "resolution": resolution,
            "feature": feature,
        }

    def run_tool(
        self, inputs: dict[str, Path], target_filter: str | None = None
    ) -> tuple[dict[str, object], str, Path]:
        model = self.root / "model.json"
        props = self.root / "generated.props"
        output = self.root / "feature-output.xml"
        command = [
            "python3",
            str(SCRIPT),
            "--vendor-prop",
            str(inputs["vendor"]),
            "--odm-prop",
            str(inputs["odm"]),
            "--init-script",
            str(inputs["init"]),
            "--advanced-xml",
            str(inputs["advanced"]),
            "--resolution-xml",
            str(inputs["resolution"]),
            "--model-output",
            str(model),
            "--props-output",
            str(props),
            "--feature-input",
            str(inputs["feature"]),
            "--feature-output",
            str(output),
        ]
        if target_filter:
            command += ["--target-filter", target_filter]
        subprocess.run(command, check=True)
        return json.loads(model.read_text(encoding="utf-8")), props.read_text(), output

    def test_generates_refresh_model_props_and_feature_xml(self):
        model, props, output = self.run_tool(self.inputs())
        self.assertEqual(model["platform"], "canoe")
        self.assertEqual(model["target_version"], "6")
        self.assertEqual(model["fps"], [165, 144, 120, 90, 60])
        self.assertEqual(model["panels"], [[1272, 2772], [7104, 3840]])
        self.assertEqual(model["widths"], [1272, 1080, 7104])
        self.assertIn(
            "ro.vendor.display.dynamic_refresh_rate=165,144,120,90,60,30:100,60,5\n",
            props,
        )
        self.assertIn("ro.vendor.mi_sf.new_dynamic_refresh_rate=165,60:5\n", props)

        root = ET.parse(output).getroot()
        self.assertEqual(root.find("./integer[@name='smart_fps_value']").text, "165")
        self.assertEqual(
            [int(item.text) for item in root.find("./integer-array[@name='fpsList']")],
            [165, 144, 120, 90, 60],
        )
        self.assertEqual(
            [
                int(item.text)
                for item in root.find(
                    "./integer-array[@name='screen_resolution_supported']"
                )
            ],
            [1272, 1080, 7104],
        )

    def test_target_filter_collects_only_matching_target(self):
        model, _, output = self.run_tool(self.inputs(), target_filter="canoe")
        self.assertEqual(model["panels"], [[1272, 2772]])
        self.assertEqual(model["widths"], [1272, 1080])
        root = ET.parse(output).getroot()
        self.assertEqual(
            [
                int(item.text)
                for item in root.find(
                    "./integer-array[@name='screen_resolution_supported']"
                )
            ],
            [1272, 1080],
        )

    def test_target_filter_without_match_fails(self):
        inputs = self.inputs()
        model = self.root / "model.json"
        result = subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--vendor-prop",
                str(inputs["vendor"]),
                "--init-script",
                str(inputs["init"]),
                "--advanced-xml",
                str(inputs["advanced"]),
                "--resolution-xml",
                str(inputs["resolution"]),
                "--target-filter",
                "nonexistent",
                "--model-output",
                str(model),
            ],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("没有 Target 'nonexistent'", result.stderr)
        self.assertIn("canoe、anorak", result.stderr)

    def test_feature_patch_is_idempotent(self):
        inputs = self.inputs()
        _, _, first_output = self.run_tool(inputs)
        first_text = first_output.read_text(encoding="utf-8")
        inputs["feature"] = first_output
        _, _, second_output = self.run_tool(inputs)
        self.assertEqual(second_output.read_text(encoding="utf-8"), first_text)

    def test_missing_resolution_input_only_updates_fps(self):
        inputs = self.inputs()
        feature = self.write(
            "feature-with-resolution.xml",
            """
            <features>
                <integer name="smart_fps_value">120</integer>
                <integer-array name="fpsList"><item>120</item></integer-array>
                <integer-array name="screen_resolution_supported">
                    <item>999</item>
                </integer-array>
            </features>
            """,
        )
        model = self.root / "no-resolution-model.json"
        output = self.root / "no-resolution-output.xml"
        subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--vendor-prop",
                str(inputs["vendor"]),
                "--init-script",
                str(inputs["init"]),
                "--advanced-xml",
                str(inputs["advanced"]),
                "--model-output",
                str(model),
                "--feature-input",
                str(feature),
                "--feature-output",
                str(output),
            ],
            check=True,
        )
        root = ET.parse(output).getroot()
        self.assertEqual(root.find("./integer[@name='smart_fps_value']").text, "165")
        self.assertEqual(
            [
                int(item.text)
                for item in root.find(
                    "./integer-array[@name='screen_resolution_supported']"
                )
            ],
            [999],
        )

    def test_rejects_multiple_target_versions_for_one_platform(self):
        inputs = self.inputs("5,6")
        model = self.root / "model.json"
        result = subprocess.run(
            [
                "python3",
                str(SCRIPT),
                "--vendor-prop",
                str(inputs["vendor"]),
                "--init-script",
                str(inputs["init"]),
                "--advanced-xml",
                str(inputs["advanced"]),
                "--model-output",
                str(model),
            ],
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("对应多个 target.version", result.stderr)

    def test_apply_module_is_idempotent_in_temporary_project(self):
        inputs = self.inputs()
        project = self.root / "project"
        (project / "DNA_config").mkdir(parents=True)
        paths = {
            "vendor_prop": project / "vendor/build.prop",
            "init": project / "vendor/bin/init.qti.display_boot.sh",
            "advanced": project / "vendor/etc/display/advanced_sf_offsets.xml",
            "odm_prop": project / "odm/etc/build.prop",
            "resolution": project / "odm/etc/sdm_display_resolution_extn.xml",
            "source_prop": project / "mi_odm/etc/build.prop",
            "feature": project / "product/etc/device_features/source.xml",
            "odm_policy": project / "display_odm.props",
            "vendor_policy": project / "display_vendor.props",
        }
        for path in paths.values():
            path.parent.mkdir(parents=True, exist_ok=True)
        paths["vendor_prop"].write_text(
            "ro.board.platform=canoe\nro.product.vendor.device=base\n",
            encoding="utf-8",
        )
        paths["init"].write_text(inputs["init"].read_text(), encoding="utf-8")
        paths["advanced"].write_text(inputs["advanced"].read_text(), encoding="utf-8")
        paths["odm_prop"].write_text(
            inputs["odm"].read_text() + "ro.product.odm.device=base\n", encoding="utf-8"
        )
        paths["resolution"].write_text(
            inputs["resolution"].read_text(), encoding="utf-8"
        )
        paths["source_prop"].write_text(
            "ro.product.odm.device=source\n", encoding="utf-8"
        )
        paths["feature"].write_text(inputs["feature"].read_text(), encoding="utf-8")
        paths["odm_policy"].write_text(
            "ro.vendor.display.touch.idle.enable=true\n", encoding="utf-8"
        )
        paths["vendor_policy"].write_text(
            "vendor.display.disable_stc_dimming=1\n", encoding="utf-8"
        )

        environment = os.environ.copy()
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["DISPLAY_POLICY_ODM_PROPERTIES_FILE"] = str(paths["odm_policy"])
        environment["DISPLAY_POLICY_VENDOR_PROPERTIES_FILE"] = str(
            paths["vendor_policy"]
        )
        command = [
            "bash",
            str(PORT_MAIN),
            "--project-dir",
            str(project),
            "common/fix_boot_refresh_rate",
        ]
        first = subprocess.run(
            command, text=True, capture_output=True, env=environment, check=True
        )
        first_props = paths["odm_prop"].read_text(encoding="utf-8")
        first_vendor_props = paths["vendor_prop"].read_text(encoding="utf-8")
        first_feature = paths["feature"].read_text(encoding="utf-8")
        second = subprocess.run(
            command, text=True, capture_output=True, env=environment, check=True
        )
        self.assertEqual(paths["odm_prop"].read_text(encoding="utf-8"), first_props)
        self.assertEqual(
            paths["vendor_prop"].read_text(encoding="utf-8"), first_vendor_props
        )
        self.assertEqual(paths["feature"].read_text(encoding="utf-8"), first_feature)
        self.assertIn("自动识别刷新率：165、144、120、90、60Hz", first.stdout)
        self.assertIn("自动识别刷新率：165、144、120、90、60Hz", second.stdout)
        self.assertIn(
            "ro.vendor.display.dynamic_refresh_rate=165,144,120,90,60,30:100,60,5",
            first_props,
        )
        self.assertIn("ro.vendor.display.touch.idle.enable=true", first_props)
        self.assertIn(
            "vendor.display.disable_stc_dimming=1",
            paths["vendor_prop"].read_text(encoding="utf-8"),
        )
        target_environment = environment.copy()
        target_environment["PORT_DISPLAY_TARGET"] = "canoe"
        third = subprocess.run(
            command, text=True, capture_output=True, env=target_environment, check=True
        )
        self.assertIn(
            "底包分辨率：面板 1272x2772；可切换宽度 1272、1080", third.stdout
        )


if __name__ == "__main__":
    unittest.main()
