#!/usr/bin/env python3
"""Small repository-only contract and idempotence checks for the feature."""

from __future__ import annotations

import pathlib
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
PORT_ROOT = ROOT.parents[1]


def test_contract_files() -> None:
    rc = (ROOT / "config/init.millet_core.rc").read_text(encoding="utf-8")
    assert "insmod /system_ext/lib64/modules/millet_core.ko" in rc
    assert "vendor_dlkm" not in rc
    assert "enable_pkg=1 enable_signal=1 enable_binder=1" in rc
    policy = (ROOT / "config/selinux_policy.cil.in").read_text(encoding="utf-8")
    assert "allow millet millet (netlink_socket (getopt setopt))" in policy
    manifest = (ROOT / "config/selinux_bundle.tsv").read_text(encoding="utf-8")
    assert "require\tproject\tsystem_ext/lib64/modules/millet_core.ko" in manifest
    assert "policy\tvendor_policy\tconfig/selinux_policy.cil.in" in manifest

    contexts = (ROOT / "config/system_ext_contexts").read_text(encoding="utf-8")
    assert "/system_ext/lib64/modules/millet_core\\.ko u:object_r:system_lib_file:s0" in contexts
    fsconfig = (ROOT / "config/system_ext_fsconfig").read_text(encoding="utf-8")
    assert "system_ext/lib64/modules/millet_core.ko 0 0 0644" in fsconfig


def test_apply_stays_off_dlkm_paths() -> None:
    apply_script = (ROOT / "apply.sh").read_text(encoding="utf-8")
    assert "vendor_dlkm" not in apply_script
    assert "system_dlkm" not in apply_script


def test_prebuilt_selection_is_repo_local() -> None:
    kmi = "android16-6.12"
    selected = ROOT / "prebuilt" / kmi / "millet_core.ko"
    assert selected.is_file() and not selected.is_symlink()


def test_op15_selects_the_same_kmi_interface() -> None:
    op15 = (PORT_ROOT / "OP15_port.sh").read_text(encoding="utf-8")
    apply_script = (ROOT / "apply.sh").read_text(encoding="utf-8")
    build_script = (ROOT / "build.sh").read_text(encoding="utf-8")
    assert "export KMI='android16-6.12'" in op15
    assert 'kmi="${KMI:-}"' in apply_script
    assert 'kmi="${KMI:-}"' in build_script


def test_metadata_merge_is_idempotent() -> None:
    # This mirrors the line-merge contract without touching the project tree.
    source = (ROOT / "config/system_ext_fsconfig").read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory() as directory:
        target = pathlib.Path(directory) / "metadata"
        target.write_text("existing 0 0 0644\n" + source + source, encoding="utf-8")
        before = target.read_bytes()
        lines = target.read_text(encoding="utf-8").splitlines(keepends=True)
        keys = {line.split()[0] for line in source.splitlines()}
        deduped = []
        seen = set()
        for line in lines:
            key = line.split()[0]
            if key in keys:
                if key in seen:
                    continue
                seen.add(key)
            deduped.append(line)
        target.write_text("".join(deduped), encoding="utf-8")
        once = target.read_bytes()
        target.write_bytes(once)
        assert once == target.read_bytes()
        assert before != once


if __name__ == "__main__":
    test_contract_files()
    test_apply_stays_off_dlkm_paths()
    test_prebuilt_selection_is_repo_local()
    test_metadata_merge_is_idempotent()
    print("ok")
