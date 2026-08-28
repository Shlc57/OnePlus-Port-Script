#!/usr/bin/env python3
"""Static contract tests for the LTPO property/context patch."""

from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path


PATCH_DIR = Path(__file__).resolve().parent
CONFIG_DIR = PATCH_DIR / "config"
PORT_DIR = PATCH_DIR.parents[1]
RUS_XML = PORT_DIR / "devices/oneplus15/config/adfr2minfps.xml"
APOLLO_ASSET = (
    PORT_DIR
    / "devices/oneplus15/config"
    / "display_apollo_list_AD296_P_3_A0020_dsc_cmd_mode_panel.xml.gz.b64"
)
APOLLO_XML_SHA256 = "0d151bb437896d6bb7eaa2d3f9f6df9339499ab97858bfdb269b80b087717234"


def active_lines(path: Path) -> list[str]:
    return [
        line.strip()
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def test_context_fragments() -> None:
    assert active_lines(CONFIG_DIR / "odm_property_contexts") == [
        "persist.oplus.display.vrr.adfr u:object_r:exported_system_prop:s0"
    ]
    assert active_lines(CONFIG_DIR / "odm_metadata_contexts") == [
        "/odm/etc/selinux/odm_property_contexts u:object_r:property_contexts_file:s0"
    ]
    assert active_lines(CONFIG_DIR / "odm_fsconfig") == [
        "odm/etc/selinux/odm_property_contexts 0 0 0644"
    ]


def test_apply_keeps_early_context_and_runtime_boundaries() -> None:
    source = (PATCH_DIR / "apply.sh").read_text(encoding="utf-8")
    for required in (
        'get_part_contexts_path odm',
        'get_part_fsconfig_path odm',
        'merge_contexts_file "$property_context_fragment"',
        'merge_contexts_file "$metadata_context_fragment"',
        'merge_fsconfig_file "$metadata_fsconfig_fragment"',
        'debug.sf.enable_vrr_config 1',
        'vendor.display.enable_hal_self_refresh 1',
        'ro.vendor.mi_sf.enable_automode_for_maxfps_setting true',
        'ro.vendor.mi_sf.supported_automode_maxfps_list 60,90,120,144,165',
        'replace_file_if_different "$temporary_property_contexts"',
        'remove_prop "$temporary_odm_build_prop" ro.vendor.mi_sf.ltpo.support',
        'remove_prop "$temporary_odm_build_prop" ro.vendor.mi_sf.enable_tp_idle_automode',
    ):
        assert required in source, required
    assert "enable_tp_idle_automode" in source
    assert 'ensure_prop "$temporary_vendor_build_prop" vendor.display.enable_qsync_idle 1' not in source
    assert 'ensure_prop "$temporary_odm_build_prop" ro.vendor.mi_sf.enable_tp_idle_automode true' not in source
    assert "allow vendor_init" not in source
    assert 'ensure_prop "$temporary_odm_build_prop" ro.vendor.mi_sf.ltpo.support true' not in source
    assert "idle_default_fps" not in source


def test_oneplus_adfr_rus_payload_and_jar_patcher_contract() -> None:
    module_spec = importlib.util.spec_from_file_location(
        "fix_ltpo_adfr_rus", PATCH_DIR / "adfr_rus.py"
    )
    assert module_spec is not None and module_spec.loader is not None
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)

    payload = module.build_payload(RUS_XML)
    assert len(payload) == 225
    assert payload[18:24] == [4, 50, 30, 20, 10, 0]
    assert payload[48:61] == [10, 1, 1, 30, 1, 120, 1, 120, 10, 120, 10, 0, 0]
    assert payload[186:199] == [10, 33, 33, 165, 33, 165, 33, 165, 33, 165, 33, 0, 0]
    helper = module.emit_smali_method(payload)
    assert 'const/16 v4, 0xea' in helper
    assert 'const/4 v4, 0x2' in helper
    assert '.method public sendOplusAdfrRusConfig()V' in helper
    assert module.LOADER_MARKER in helper
    assert "OPLUS_ADFR_RUS_LOADER_ASYNC_V1" in helper
    assert "IDisplayPanelFeature/default" in helper
    assert "sha256" not in helper

    shell_patcher = (PATCH_DIR / "patch_miui_services_adfr.sh").read_text(
        encoding="utf-8"
    )
    python_patcher = (PATCH_DIR / "patch_miui_services_adfr.py").read_text(
        encoding="utf-8"
    )
    patcher_spec = importlib.util.spec_from_file_location(
        "fix_ltpo_miui_services_patcher", PATCH_DIR / "patch_miui_services_adfr.py"
    )
    assert patcher_spec is not None and patcher_spec.loader is not None
    patcher = importlib.util.module_from_spec(patcher_spec)
    patcher_spec.loader.exec_module(patcher)
    assert patcher.extract_loader_payload(helper) == payload
    assert patcher.full_aod_patch_state(patcher.AOD_ORIGINAL_METHOD) == "original"
    replay_fixture = patcher.AOD_REPLAY_METHOD
    assert patcher.full_aod_patch_state(replay_fixture) == "patched"
    assert patcher.normalized_smali_method(replay_fixture) == patcher.normalized_smali_method(
        replay_fixture.replace(":oplus_full_aod_replay_done", ":done").replace(
            ":oplus_full_aod_replay_loop", ":loop"
        )
    )
    with tempfile.TemporaryDirectory(prefix="ltpo-aod-contract-") as temporary_dir:
        replay_path = Path(temporary_dir) / "DisplayFeatureManagerServiceImpl.smali"
        replay_path.write_text(replay_fixture, encoding="utf-8")
        assert patcher.remove_full_aod_smali(replay_path, "patched") is True
        assert patcher.full_aod_patch_state(replay_path.read_text(encoding="utf-8")) == "original"
    legacy_marker = "OPLUS_ADFR_RUS_LOADER " + ("a" * 64)
    legacy_async_helper = helper.replace(patcher.LOADER_MARKER, legacy_marker, 1)
    legacy_async_helper = legacy_async_helper.replace(
        patcher.HELPER_SIGNATURE, patcher.LEGACY_HELPER_SIGNATURE, 1
    )
    legacy_body = (
        legacy_async_helper
        + "\n"
        + patcher.BOOT_BLOCK
        + "\n"
        + patcher.RUNNABLE_CALL_DIRECT
    )
    private_body = legacy_async_helper.replace(
        patcher.LEGACY_HELPER_SIGNATURE,
        patcher.LEGACY_PRIVATE_HELPER_SIGNATURE,
        1,
    ) + "\n" + patcher.BOOT_BLOCK + "\n" + patcher.RUNNABLE_CALL_VIRTUAL
    assert patcher.smali_patch_state(legacy_body) == "patched_unsafe"
    assert patcher.smali_patch_state(private_body) == "patched_private"
    sync_helper = legacy_async_helper.replace(
        f'\n    const-string/jumbo v5, "{patcher.ASYNC_MARKER}"', "", 1
    )
    legacy_sync = sync_helper + "\n" + patcher.BOOT_CALL_LINE
    assert patcher.smali_patch_state(legacy_sync) == "legacy_sync"
    assert patcher.smali_patch_state(helper + "\n" + patcher.BOOT_BLOCK + "\n" + patcher.RUNNABLE_CALL_VIRTUAL) == "patched"
    apply_source = (PATCH_DIR / "apply.sh").read_text(encoding="utf-8")
    assert "patch_miui_services_adfr.py" in shell_patcher
    for required in (
        "DisplayManagerServiceImpl.smali",
        "DisplayFeatureManagerServiceImpl.smali",
        "sendOplusAdfrRusConfig",
        "onBootCompleted",
        "OPLUS_ADFR_RUS_LOADER_V2",
        "RUNNABLE_CLASS",
        "BOOT_BLOCK",
        "AOD_REPLAY_METHOD",
        "AOD_ORIGINAL_METHOD",
        "remove_full_aod_smali",
        "full_aod_patch_state",
        "LEGACY_HELPER_SIGNATURE",
        "LEGACY_PRIVATE_HELPER_SIGNATURE",
        "invoke-virtual {v0}",
        "ZIP_STORED",
        "archive_content_snapshot",
        "classes.dex",
    ):
        assert required in python_patcher, required
    assert "patch_full_aod_smali" not in python_patcher
    for required in (
        "OPLUS_ADFR_RUS_XML_FILE",
        "patch_miui_services_adfr.sh",
        "framework/miui-services.jar.fsv_meta",
        "framework/oat/$abi/miui-services.$variant.$extension",
        "remove_part_metadata_prefix system_ext",
    ):
        assert required in apply_source, required


def test_oneplus_apollo_panel_nit_contract() -> None:
    module_spec = importlib.util.spec_from_file_location(
        "fix_ltpo_apollo_panel_nit", PATCH_DIR / "patch_apollo_panel_nit.py"
    )
    assert module_spec is not None and module_spec.loader is not None
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)

    library_path = PORT_DIR / ".codex_tmp/libsdmcore_live.so"
    if library_path.is_file():
        library = library_path.read_bytes()
        _layout, candidate, sites = module.inspect_library(library)
        assert candidate.form in {"new-padded", "new-short"}
        assert sites.state == "complete"
        assert module.apply_library_patch(library) == library

    xml_bytes = module.decode_asset(APOLLO_ASSET, APOLLO_XML_SHA256)
    assert module.sha256_file(APOLLO_ASSET) != APOLLO_XML_SHA256
    assert len(xml_bytes) == 533567
    assert module.OLD_PREFIX == b"/my_product/vendor/etc/display_apollo_list_"
    assert module.NEW_PREFIX == b"/vendor/etc/display_apollo_list_"
    assert len(module.NEW_PREFIX) < len(module.OLD_PREFIX)
    assert module.PARSE_SYMBOL_SUFFIX == "ApolloXmlParser12parseXmlFileEv"

    apply_source = (PATCH_DIR / "apply.sh").read_text(encoding="utf-8")
    op15_source = (PORT_DIR / "OP15_port.sh").read_text(encoding="utf-8")
    for required in (
        "patch_apollo_panel_nit.py",
        "OPLUS_APOLLO_PANEL_CONFIG_ASSET",
        "OPLUS_APOLLO_PANEL_CONFIG_RELATIVE_PATH",
        "OPLUS_APOLLO_PANEL_CONFIG_SHA256",
        "vendor_configs_file",
        "prepare_apollo_panel_nit",
        "inspect_library",
        "ApolloXmlParser::parseXmlFile",
    ):
        assert required in apply_source or required in op15_source or required in (
            PATCH_DIR / "patch_apollo_panel_nit.py"
        ).read_text(encoding="utf-8"), required
    assert "OPLUS_APOLLO_SDMCORE_INPUT_SHA256" not in op15_source
    assert "OPLUS_APOLLO_SDMCORE_OUTPUT_SHA256" not in op15_source


if __name__ == "__main__":
    test_context_fragments()
    test_apply_keeps_early_context_and_runtime_boundaries()
    test_oneplus_adfr_rus_payload_and_jar_patcher_contract()
    test_oneplus_apollo_panel_nit_contract()
    print("LTPO property/context contract tests passed")
