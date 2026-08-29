#!/usr/bin/env python3
"""Host-only structural tests for the OTA-variable Bluetooth APEX repacker."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


MODULE_DIR = Path(__file__).resolve().parents[1]
PROJECT_DIR = MODULE_DIR.parents[2]
REPACKER_PATH = MODULE_DIR / "repack_bt_apex.py"
SPEC = importlib.util.spec_from_file_location("repack_bt_apex", REPACKER_PATH)
assert SPEC is not None and SPEC.loader is not None
REPACKER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = REPACKER
SPEC.loader.exec_module(REPACKER)


def resolve_tool(name: str, candidates: tuple[Path, ...] = ()) -> str:
    resolved = shutil.which(name)
    if resolved:
        return resolved
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    raise unittest.SkipTest(f"missing host tool: {name}")


class LhdcApexContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source_fixture = None
        system_image = PROJECT_DIR / "DNA_input/system.img"
        fsck_erofs = shutil.which("fsck.erofs")
        if system_image.is_file() and fsck_erofs is not None:
            cls.source_fixture = tempfile.TemporaryDirectory(prefix="fix-lhdc-source.")
            extract_root = Path(cls.source_fixture.name)
            subprocess.run(
                [fsck_erofs, f"--extract={extract_root}", str(system_image)],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            cls.source_apex = extract_root / "system/apex/com.android.bt.apex"
        else:
            cls.source_apex = PROJECT_DIR / "system/system/apex/com.android.bt.apex"
        if not cls.source_apex.is_file():
            raise unittest.SkipTest("an input Bluetooth APEX is unavailable")
        try:
            REPACKER.read_preserved_signing_block(cls.source_apex)
        except REPACKER.RepackError as exc:
            raise unittest.SkipTest("an input APEX with an APK Signing Block is unavailable") from exc
        cls.addClassCleanup(
            lambda: cls.source_fixture.cleanup() if cls.source_fixture else None
        )
        cls.prebuilt_dir = MODULE_DIR / "prebuilt/system/apex/com.android.bt/lib64"
        cls.bridge_source = MODULE_DIR / "source/lhdc_cold.cpp"
        cls.avb_key = MODULE_DIR / "keys/com.android.bt.avb.pem"
        if not cls.avb_key.is_file() or cls.avb_key.is_symlink():
            raise unittest.SkipTest("project AVB signing key is unavailable")
        cls.avbtool = resolve_tool("avbtool")
        cls.zipalign = resolve_tool("zipalign")
        cls.debugfs = resolve_tool("debugfs")
        cls.patchelf = resolve_tool("patchelf")
        cls.readelf = resolve_tool("readelf")
        for tool in ("e2fsck", "resize2fs", "truncate"):
            resolve_tool(tool)

    def run_repacker(self, source: Path, output: Path, report: Path) -> str:
        result = subprocess.run(
            [
                sys.executable,
                str(REPACKER_PATH),
                "--input",
                str(source),
                "--output",
                str(output),
                "--prebuilt-dir",
                str(self.prebuilt_dir),
                "--bridge-source",
                str(self.bridge_source),
                "--report",
                str(report),
                "--avbtool",
                self.avbtool,
                "--zipalign",
                self.zipalign,
                "--avb-key",
                str(self.avb_key),
            ],
            check=True,
            text=True,
            capture_output=True,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        return result.stdout.strip()

    def extract_payload(self, apex: Path, output: Path) -> None:
        with zipfile.ZipFile(apex) as archive:
            output.write_bytes(archive.read(REPACKER.PAYLOAD_MEMBER))

    def mutate_payload(
        self,
        source_apex: Path,
        output_apex: Path,
        mutate,
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="fix-lhdc-mutate.") as temporary:
            temp = Path(temporary)
            infos, contents = REPACKER.zip_members(source_apex)
            payload_index = REPACKER.unique_member_index(
                infos, REPACKER.PAYLOAD_MEMBER
            )
            payload = temp / "payload.img"
            payload.write_bytes(contents[payload_index])
            mutate(payload, temp)
            REPACKER.repack_zip(
                infos,
                contents,
                payload,
                temp / "unaligned.apex",
                output_apex,
                self.zipalign,
                signing_block=REPACKER.read_preserved_signing_block(source_apex),
            )

    def test_prebuilts_and_dynamic_v5_contract(self) -> None:
        repacker_source = REPACKER_PATH.read_text(encoding="utf-8")
        self.assertNotIn("SourceState", repacker_source)
        self.assertNotIn("extract_build_id", repacker_source)
        self.assertNotIn("jni_build_id=", repacker_source)
        self.assertNotIn("Build ID:", repacker_source)

        for name in REPACKER.PREBUILT_CONTRACTS:
            path = self.prebuilt_dir / name
            REPACKER.validate_prebuilt(path, name, self.patchelf, self.readelf)

        with tempfile.TemporaryDirectory(prefix="fix-lhdc-prebuilt.") as temporary:
            changed = Path(temporary) / "liblhdcv5.so"
            shutil.copy2(self.prebuilt_dir / changed.name, changed)
            with changed.open("ab") as output:
                output.write(b"non-semantic-trailing-data")
            REPACKER.validate_prebuilt(
                changed, changed.name, self.patchelf, self.readelf
            )

        contract = REPACKER.parse_bridge_contract(self.bridge_source)
        with tempfile.TemporaryDirectory(prefix="fix-lhdc-abi.") as temporary:
            payload = Path(temporary) / "payload.img"
            jni = Path(temporary) / REPACKER.JNI_NAME
            self.extract_payload(self.source_apex, payload)
            REPACKER.extract_debugfs(
                self.debugfs,
                payload,
                f"/lib64/{REPACKER.JNI_NAME}",
                jni,
            )
            match = REPACKER.validate_v5_abi(
                jni.read_bytes(), REPACKER.JNI_NAME, contract
            )
            self.assertIsInstance(match.stub_file_offset, int)
            self.assertIsInstance(match.table_file_offset, int)

            damaged = bytearray(jni.read_bytes())
            damaged[match.stub_file_offset] ^= 1
            with self.assertRaises(REPACKER.RepackError):
                REPACKER.validate_v5_abi(
                    bytes(damaged), REPACKER.JNI_NAME, contract
                )

        with self.assertRaises(REPACKER.RepackError):
            REPACKER.validate_signature_members(
                [
                    REPACKER.PAYLOAD_MEMBER,
                    REPACKER.PUBKEY_MEMBER,
                    "AndroidManifest.xml",
                    "apex_manifest.pb",
                    "META-INF/MANIFEST.MF",
                    "META-INF/OTA.SF",
                    "META-INF/OTHER.RSA",
                ]
            )

    def test_apply_script_declares_idempotent_bt_log_property_step(self) -> None:
        apply_script = (MODULE_DIR / "apply.sh").read_text(encoding="utf-8")
        self.assertIn(
            'system_build_prop="$project_dir/system/system/build.prop"',
            apply_script,
        )
        # The target build.prop is an assembled system file, not a standalone
        # override fragment; unrelated pre-existing duplicate keys must not
        # block this patch's independent log-property update.
        self.assertNotIn(
            'validate_prop_file "$system_build_prop"',
            apply_script,
        )
        self.assertIn(
            'ensure_prop "$system_build_prop" "log.tag.BTAudioSessionAidl" "S"',
            apply_script,
        )

    def test_repack_completed_state_and_member_preservation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fix-lhdc-contract.") as temporary:
            temp = Path(temporary)
            source_with_extra = temp / "source-with-extra.apex"
            first = temp / "first.apex"
            second = temp / "second.apex"
            extra_name = "future/ota-member.bin"
            extra_data = b"OTA-variable-member\x00\xff"

            with zipfile.ZipFile(self.source_apex) as original, zipfile.ZipFile(
                source_with_extra, "w", allowZip64=True
            ) as changed:
                for info in original.infolist():
                    changed.writestr(info, original.read(info))
                changed.writestr(
                    extra_name,
                    extra_data,
                    compress_type=zipfile.ZIP_DEFLATED,
                )
            signing_block_file = temp / "source-signing-block.bin"
            signing_block_file.write_bytes(
                REPACKER.read_preserved_signing_block(self.source_apex)
            )
            REPACKER.load_signing_block_helper().insert_signing_block(
                source_with_extra, signing_block_file
            )

            self.assertEqual(
                self.run_repacker(source_with_extra, first, temp / "first.txt"),
                "original",
            )
            self.assertEqual(
                self.run_repacker(first, second, temp / "second.txt"),
                "completed",
            )
            self.assertEqual(first.read_bytes(), second.read_bytes())
            source_signing_block = REPACKER.read_preserved_signing_block(self.source_apex)
            self.assertEqual(
                REPACKER.read_preserved_signing_block(first), source_signing_block
            )
            self.assertEqual(
                REPACKER.read_preserved_signing_block(second), source_signing_block
            )

            alternate_input = temp / "alternate-input"
            alternate_input.mkdir()
            alternate_prebuilts = {}
            for name in REPACKER.PREBUILT_CONTRACTS:
                copied = alternate_input / name
                shutil.copy2(self.prebuilt_dir / name, copied)
                alternate_prebuilts[name] = copied
            with alternate_prebuilts["liblhdcv5.so"].open("ab") as output:
                output.write(b"non-semantic-trailing-data")
            REPACKER.validate_prebuilt(
                alternate_prebuilts["liblhdcv5.so"],
                "liblhdcv5.so",
                self.patchelf,
                self.readelf,
            )
            mismatch_payload = temp / "mismatch-payload.img"
            mismatch_workspace = temp / "mismatch-workspace"
            mismatch_workspace.mkdir()
            self.extract_payload(first, mismatch_payload)
            with self.assertRaisesRegex(
                REPACKER.RepackError, "differs from the current module input"
            ):
                REPACKER.detect_state(
                    mismatch_payload,
                    self.debugfs,
                    self.patchelf,
                    self.readelf,
                    REPACKER.parse_bridge_contract(self.bridge_source),
                    mismatch_workspace,
                    alternate_prebuilts,
                    prefix="mismatch",
                )

            source_infos, source_contents = REPACKER.zip_members(source_with_extra)
            final_infos, final_contents = REPACKER.zip_members(first)
            self.assertEqual(
                [info.filename for info in source_infos],
                [info.filename for info in final_infos],
            )
            for index, info in enumerate(source_infos):
                if info.filename not in {
                    REPACKER.PAYLOAD_MEMBER,
                    REPACKER.PUBKEY_MEMBER,
                }:
                    self.assertEqual(source_contents[index], final_contents[index])
            with zipfile.ZipFile(first) as archive:
                project_pubkey = temp / "project.avbpubkey"
                REPACKER.extract_avb_public_key(
                    self.avbtool, self.avb_key, project_pubkey
                )
                self.assertEqual(
                    archive.read(REPACKER.PUBKEY_MEMBER),
                    project_pubkey.read_bytes(),
                )
            with zipfile.ZipFile(first) as archive:
                self.assertEqual(archive.read(extra_name), extra_data)

            report = (temp / "first.txt").read_text(encoding="utf-8")
            self.assertIn("input_contract=OTA_STRUCTURAL", report)
            self.assertIn("jni_contract=STRUCTURAL_ABI_AND_DT_NEEDED", report)
            self.assertNotIn("jni_build_id", report)
            self.assertIn("payload_avb_signature=VALID_SELF_SIGNED", report)
            self.assertIn("apk_signing_block=PRESERVED_BYTE_FOR_BYTE", report)

            duplicate_extra = temp / "duplicate-extra.apex"
            with zipfile.ZipFile(source_with_extra) as original, zipfile.ZipFile(
                duplicate_extra, "w", allowZip64=True
            ) as changed:
                for info in original.infolist():
                    changed.writestr(info, original.read(info))
                changed.writestr(
                    extra_name,
                    extra_data,
                    compress_type=zipfile.ZIP_STORED,
                )
            with self.assertRaises(REPACKER.RepackError):
                REPACKER.zip_members(duplicate_extra)

    def test_mixed_states_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory(prefix="fix-lhdc-reject.") as temporary:
            temp = Path(temporary)
            completed = temp / "completed.apex"
            self.assertEqual(
                self.run_repacker(
                    self.source_apex, completed, temp / "completed.txt"
                ),
                "original",
            )

            partial = temp / "partial.apex"

            def remove_one_library(payload: Path, _temp: Path) -> None:
                REPACKER.debugfs_write(
                    self.debugfs,
                    payload,
                    "rm /lib64/liblhdcv5BT_enc.so",
                )

            self.mutate_payload(completed, partial, remove_one_library)
            with self.assertRaises(REPACKER.RepackError):
                infos, contents = REPACKER.zip_members(partial)
                payload = temp / "partial.img"
                payload.write_bytes(
                    contents[
                        REPACKER.unique_member_index(infos, REPACKER.PAYLOAD_MEMBER)
                    ]
                )
                contract = REPACKER.parse_bridge_contract(self.bridge_source)
                REPACKER.detect_state(
                    payload,
                    self.debugfs,
                    self.patchelf,
                    self.readelf,
                    contract,
                    temp,
                    {
                        name: self.prebuilt_dir / name
                        for name in REPACKER.PREBUILT_CONTRACTS
                    },
                    prefix="partial",
                )

            duplicate_needed = temp / "duplicate-needed.apex"

            def add_duplicate_needed(payload: Path, work: Path) -> None:
                source_jni = work / "jni.so"
                patched_jni = work / "jni-duplicate.so"
                REPACKER.extract_debugfs(
                    self.debugfs,
                    payload,
                    f"/lib64/{REPACKER.JNI_NAME}",
                    source_jni,
                )
                shutil.copy2(source_jni, patched_jni)
                subprocess.run(
                    [
                        self.patchelf,
                        "--add-needed",
                        REPACKER.COLD_NEEDED,
                        str(patched_jni),
                    ],
                    check=True,
                )
                REPACKER.delete_if_present(
                    self.debugfs, payload, f"/lib64/{REPACKER.JNI_NAME}"
                )
                REPACKER.debugfs_write(
                    self.debugfs,
                    payload,
                    f"write {patched_jni} /lib64/{REPACKER.JNI_NAME}",
                )

            self.mutate_payload(completed, duplicate_needed, add_duplicate_needed)
            with self.assertRaises(REPACKER.RepackError):
                infos, contents = REPACKER.zip_members(duplicate_needed)
                payload = temp / "duplicate.img"
                payload.write_bytes(
                    contents[
                        REPACKER.unique_member_index(infos, REPACKER.PAYLOAD_MEMBER)
                    ]
                )
                contract = REPACKER.parse_bridge_contract(self.bridge_source)
                REPACKER.detect_state(
                    payload,
                    self.debugfs,
                    self.patchelf,
                    self.readelf,
                    contract,
                    temp,
                    {
                        name: self.prebuilt_dir / name
                        for name in REPACKER.PREBUILT_CONTRACTS
                    },
                    prefix="duplicate",
                )


if __name__ == "__main__":
    unittest.main()
