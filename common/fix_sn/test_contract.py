#!/usr/bin/env python3
"""Static contract tests for the common Xiaomi Phone SN fallback."""

import os
import stat
import subprocess
import tempfile
from pathlib import Path


MODULE = Path(__file__).resolve().parent
APPLY = MODULE / "apply.sh"
TEMPLATE = MODULE / "config/init_psno_fallback.rc"
README = MODULE / "README.md"
OP15 = MODULE.parents[1] / "OP15_port.sh"
PORT_MAIN = MODULE.parents[1] / "port_main.sh"

EXPECTED_TEMPLATE = """# BEGIN common xiaomi psno fallback
# Display fallback for Xiaomi DeviceInfoQR Phone SN.
# It only fills an empty Xiaomi Phone SN field after boot from the target
# serial number; it does not claim a Xiaomi OEM NV PSNO and does not alter
# IMEI, PCB SN, or Factory ID.
on property:sys.boot_completed=1 && property:ro.ril.oem.psno=
    setprop ro.ril.oem.psno ${ro.serialno}
# END common xiaomi psno fallback
"""


def test_template_contract() -> None:
    assert TEMPLATE.read_text(encoding="utf-8") == EXPECTED_TEMPLATE


def test_script_contract() -> None:
    source = APPLY.read_text(encoding="utf-8")
    assert "check_part_exists system_ext" in source
    assert "system_ext_property_contexts" in source
    assert "ro.ril.oem.psno" in source
    assert "u:object_r:sno_prop:s0" in source
    assert "_install_generated_file" in source
    assert "PYTHONDONTWRITEBYTECODE=1 python3" in source
    for forbidden in (
        "setenforce",
        "mount ",
        "service ",
        "ro.ril.oem.sno",
        "ro.ril.factory_id",
        "ro.ril.miui.imei",
        "secinfo",
    ):
        assert forbidden not in source


def test_entry_order() -> None:
    source = OP15.read_text(encoding="utf-8")
    mi_account = source.index("common/fix_mi_account")
    psno = source.index("common/fix_sn")
    vendor_avc = source.index("common/fix_vendor_avc")
    assert mi_account < psno < vendor_avc


def test_readme_boundary() -> None:
    text = README.read_text(encoding="utf-8")
    assert "不是 Xiaomi modem PSNO" in text
    assert "ro.ril.oem.sno" in text
    assert "ro.ril.factory_id" in text
    assert "冷启动" in text


def test_temporary_project_integration() -> None:
    def write_fixture(path: Path, content: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    with tempfile.TemporaryDirectory(prefix="fix-xiaomi-psno-") as temporary_dir:
        project = Path(temporary_dir)
        (project / "DNA_config").mkdir()
        write_fixture(project / "vendor/build.prop", "ro.product.device=OP60FFL1\n")
        write_fixture(project / "odm/etc/build.prop", "ro.product.device=OP60FFL1\n")
        write_fixture(project / "mi_odm/etc/build.prop", "ro.product.device=nezha\n")
        target_rc = project / "system_ext/etc/init/init.miui.ext.rc"
        write_fixture(
            target_rc,
            "on property:sys.boot_completed=1\n"
            "    start miui-post-boot\n",
        )
        target_rc.chmod(0o640)
        write_fixture(
            project / "system_ext/etc/selinux/system_ext_property_contexts",
            "ro.ril.oem.psno u:object_r:sno_prop:s0\n",
        )

        command = [
            "bash",
            str(PORT_MAIN),
            "--project-dir",
            str(project),
            "common/fix_sn",
        ]
        environment = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}
        subprocess.run(command, cwd=MODULE.parents[1], env=environment, check=True)
        first_result = target_rc.read_text(encoding="utf-8")
        assert first_result.count("# BEGIN common xiaomi psno fallback") == 1
        assert "    setprop ro.ril.oem.psno ${ro.serialno}" in first_result
        assert stat.S_IMODE(target_rc.stat().st_mode) == 0o640

        subprocess.run(command, cwd=MODULE.parents[1], env=environment, check=True)
        assert target_rc.read_text(encoding="utf-8") == first_result


if __name__ == "__main__":
    test_template_contract()
    test_script_contract()
    test_entry_order()
    test_readme_boundary()
    test_temporary_project_integration()
    print("Common Xiaomi PSNO fallback contract passed")
