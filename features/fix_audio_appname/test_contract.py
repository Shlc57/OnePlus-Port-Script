#!/usr/bin/env python3
"""Host-side contract tests for semantic audio appname patching."""

from __future__ import annotations

import importlib.util
from dataclasses import fields
from pathlib import Path
import sys
import tempfile
import unittest


MODULE_DIR = Path(__file__).resolve().parent
PATCHER_PATH = MODULE_DIR / "patch_audio_appname.py"
SPEC = importlib.util.spec_from_file_location("patch_audio_appname", PATCHER_PATH)
assert SPEC is not None and SPEC.loader is not None
PATCHER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PATCHER
SPEC.loader.exec_module(PATCHER)


class AudioAppnamePatchContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.project_dir = MODULE_DIR.parents[2]
        cls.library_dir = cls.project_dir / "system_ext/lib64"
        missing = [
            name for name in PATCHER.LIBRARIES if not (cls.library_dir / name).is_file()
        ]
        if missing:
            raise unittest.SkipTest(
                "current project libraries are unavailable: " + ", ".join(missing)
            )

    def _read(self, library_name: str) -> bytes:
        return (self.library_dir / library_name).read_bytes()

    def _original_fixture(self, library_name: str, spec: object) -> bytes:
        data = bytearray(self._read(library_name))
        inspection = PATCHER._locate_sites(data, spec, library_name)
        if inspection.state == "patched":
            for site in inspection.sites:
                data[site.offset : site.offset + 4] = PATCHER.BLR_X8
        self.assertEqual(PATCHER.inspect_data(bytes(data), spec), "original")
        return bytes(data)

    def test_contract_has_exact_eight_sites_and_no_file_allowlist(self) -> None:
        self.assertEqual(
            PATCHER.LIBRARIES["libaudiopolicymanagerimpl.so"].site_count, 3
        )
        self.assertEqual(
            PATCHER.LIBRARIES["libmiaudiopolicymanager.so"].site_count, 5
        )
        self.assertEqual(sum(spec.site_count for spec in PATCHER.LIBRARIES.values()), 8)
        self.assertEqual(
            tuple(field.name for field in fields(PATCHER.LibrarySpec)),
            ("filename", "functions"),
        )
        for spec in PATCHER.LIBRARIES.values():
            self.assertFalse(hasattr(spec, "size"))

    def test_patch_changes_only_eight_declared_instructions_and_is_idempotent(self) -> None:
        for library_name, spec in PATCHER.LIBRARIES.items():
            with self.subTest(library=library_name), tempfile.TemporaryDirectory() as temp:
                staged = Path(temp) / library_name
                staged.write_bytes(self._original_fixture(library_name, spec))
                before = staged.read_bytes()
                original_inspection = PATCHER.inspect_file(staged, spec)
                self.assertEqual(original_inspection.state, "original")
                original_sites = {site.offset for site in original_inspection.sites}
                self.assertEqual(len(original_sites), spec.site_count)

                PATCHER.patch_file(staged, spec)
                after = staged.read_bytes()
                patched_inspection = PATCHER.inspect_file(staged, spec)
                self.assertEqual(patched_inspection.state, "patched")
                self.assertEqual(
                    {site.offset for site in patched_inspection.sites}, original_sites
                )
                changed_indexes = {
                    index for index, (old, new) in enumerate(zip(before, after)) if old != new
                }
                expected_indexes = {
                    index
                    for offset in original_sites
                    for index in range(offset, offset + len(PATCHER.ARM64_NOP))
                }
                self.assertEqual(changed_indexes, expected_indexes)
                first_patched = after
                PATCHER.patch_file(staged, spec)
                self.assertEqual(staged.read_bytes(), first_patched)

    def test_appended_nonsemantic_tail_and_length_change_are_allowed(self) -> None:
        for library_name, spec in PATCHER.LIBRARIES.items():
            with self.subTest(library=library_name), tempfile.TemporaryDirectory() as temp:
                staged = Path(temp) / library_name
                original = self._original_fixture(library_name, spec)
                # Bytes beyond the last PT_LOAD/section data do not participate
                # in any semantic anchor; their presence must not become a
                # hidden file-size allow-list.
                staged.write_bytes(original + b"contract-tail-padding")
                before = staged.read_bytes()
                inspection = PATCHER.inspect_file(staged, spec)
                self.assertEqual(inspection.state, "original")
                offsets = {site.offset for site in inspection.sites}
                PATCHER.patch_file(staged, spec)
                after = staged.read_bytes()
                self.assertEqual(PATCHER.inspect_file(staged, spec).state, "patched")
                self.assertEqual(after[len(original) :], before[len(original) :])
                changed_indexes = {
                    index for index, (old, new) in enumerate(zip(before, after)) if old != new
                }
                self.assertEqual(
                    changed_indexes,
                    {
                        index
                        for offset in offsets
                        for index in range(offset, offset + len(PATCHER.ARM64_NOP))
                    },
                )

    def test_mixed_state_is_rejected_without_writing(self) -> None:
        for library_name, spec in PATCHER.LIBRARIES.items():
            with self.subTest(library=library_name), tempfile.TemporaryDirectory() as temp:
                staged = Path(temp) / library_name
                staged.write_bytes(self._original_fixture(library_name, spec))
                inspection = PATCHER.inspect_file(staged, spec)
                data = bytearray(staged.read_bytes())
                data[inspection.sites[0].offset : inspection.sites[0].offset + 4] = PATCHER.ARM64_NOP
                staged.write_bytes(data)
                before = staged.read_bytes()
                with self.assertRaises(PATCHER.PatchError):
                    PATCHER.patch_file(staged, spec)
                self.assertEqual(staged.read_bytes(), before)

    def test_unknown_call_instruction_is_rejected_without_writing(self) -> None:
        for library_name, spec in PATCHER.LIBRARIES.items():
            with self.subTest(library=library_name), tempfile.TemporaryDirectory() as temp:
                staged = Path(temp) / library_name
                staged.write_bytes(self._original_fixture(library_name, spec))
                inspection = PATCHER.inspect_file(staged, spec)
                data = bytearray(staged.read_bytes())
                data[inspection.sites[0].offset : inspection.sites[0].offset + 4] = b"\0\0\0\0"
                staged.write_bytes(data)
                before = staged.read_bytes()
                with self.assertRaises(PATCHER.PatchError):
                    PATCHER.patch_file(staged, spec)
                self.assertEqual(staged.read_bytes(), before)

    def test_wrong_architecture_is_rejected(self) -> None:
        for library_name, spec in PATCHER.LIBRARIES.items():
            with self.subTest(library=library_name), tempfile.TemporaryDirectory() as temp:
                staged = Path(temp) / library_name
                data = bytearray(self._original_fixture(library_name, spec))
                data[18:20] = (62).to_bytes(2, "little")  # EM_X86_64.
                staged.write_bytes(data)
                with self.assertRaises(PATCHER.PatchError):
                    PATCHER.inspect_file(staged, spec)


if __name__ == "__main__":
    unittest.main()
