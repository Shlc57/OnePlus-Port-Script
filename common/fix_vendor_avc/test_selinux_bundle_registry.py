#!/usr/bin/env python3
"""Validate the unified SELinux bundle registry contract."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parent
PORT = ROOT.parent.parent
REGISTRY = ROOT / "config" / "selinux_bundles.tsv"


def read_tsv(path: Path) -> list[tuple[str, str, str]]:
    records: list[tuple[str, str, str]] = []
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not raw_line or raw_line.startswith("#"):
            continue
        fields = tuple(raw_line.split("\t"))
        assert len(fields) == 3, f"invalid TSV at {path}:{line_number}"
        records.append(fields)  # type: ignore[arg-type]
    return records


def is_safe_relative_path(value: str) -> bool:
    if not value or value.startswith("/") or "\\" in value:
        return False
    if any(character.isspace() for character in value):
        return False
    return all(segment not in {"", ".", ".."} for segment in value.split("/"))


def context_keys(path: Path) -> list[str]:
    keys: list[str] = []
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        assert len(fields) == 2, f"invalid context at {path}:{line_number}"
        keys.append(fields[0].replace("\\", ""))
    assert keys, f"empty context fragment: {path}"
    return keys


def assert_unique_context_owners(
    records: list[tuple[str, str, str]],
) -> None:
    owners: dict[tuple[str, str], str] = {}
    for owner, target, key in records:
        ownership_key = (target, key.replace("\\", ""))
        assert ownership_key not in owners, (
            f"context key collision for {target}:{key}: "
            f"{owners.get(ownership_key)} and {owner}"
        )
        owners[ownership_key] = owner


def test_registry() -> None:
    records = read_tsv(REGISTRY)

    assert records == [
        (
            "fix_mi_account",
            "common/fix_mi_account",
            "config/selinux_bundle.tsv",
        ),
        (
            "fix_nfc",
            "common/fix_nfc",
            "config/selinux_bundle.tsv",
        ),
        (
            "fix_displayfeature_bridge",
            "features/fix_displayfeature_bridge",
            "config/selinux_bundle.tsv",
        ),
        (
            "fix_oplus_double_tap_wake",
            "features/fix_oplus_double_tap_wake",
            "config/selinux_bundle.tsv",
        ),
        (
            "fix_ultrasonic_fingerprint",
            "features/fix_ultrasonic_fingerprint",
            "config/selinux_bundle.tsv",
        ),
        (
            "fix_oplusreserve_context",
            "devices/oneplus15/fix_oplusreserve_context",
            "config/selinux_bundle.tsv",
        ),
    ]
    assert len(records) == len(set(records))
    for name, relative_dir, relative_manifest in records:
        assert name.replace("_", "").isalnum()
        assert is_safe_relative_path(relative_dir)
        assert is_safe_relative_path(relative_manifest)
        bundle_dir = PORT / relative_dir
        manifest = bundle_dir / relative_manifest
        assert bundle_dir.is_dir() and not bundle_dir.is_symlink()
        assert manifest.is_file() and not manifest.is_symlink()
        assert bundle_dir.resolve().is_relative_to(PORT.resolve())
        assert manifest.resolve().is_relative_to(bundle_dir.resolve())


def test_unsafe_registry_paths_are_rejected() -> None:
    for unsafe_path in (
        "",
        ".",
        "..",
        "../outside",
        "features/../../outside",
        "features/./bundle",
        "features//bundle",
        "features/bundle/",
        "/absolute/bundle",
        "features/bundle\\manifest",
        "features/bundle name",
    ):
        assert not is_safe_relative_path(unsafe_path), unsafe_path

    apply_source = (ROOT / "apply.sh").read_text(encoding="utf-8")
    assert '_is_safe_relative_path "$bundle_relative_dir"' in apply_source
    assert '_is_safe_relative_path "$bundle_relative_manifest"' in apply_source
    assert '"$port_dir_real"/*' in apply_source


def test_context_keys_are_unique_across_registered_bundles() -> None:
    owned_keys: list[tuple[str, str, str]] = []
    for owner, relative_dir, relative_manifest in read_tsv(REGISTRY):
        bundle_dir = PORT / relative_dir
        for record_type, target, relative_fragment in read_tsv(
            bundle_dir / relative_manifest
        ):
            if record_type != "contexts":
                continue
            for key in context_keys(bundle_dir / relative_fragment):
                owned_keys.append((owner, target, key))
    assert_unique_context_owners(owned_keys)

    escaped_collision = [
        ("first", "vendor_file_contexts", r"/odm/bin/test\.service"),
        ("second", "vendor_file_contexts", "/odm/bin/test.service"),
    ]
    try:
        assert_unique_context_owners(escaped_collision)
    except AssertionError:
        pass
    else:
        raise AssertionError("escaped/unescaped cross-bundle collision was accepted")

    apply_source = (ROOT / "apply.sh").read_text(encoding="utf-8")
    assert "validate_bundle_context_key_ownership" in apply_source
    assert 'normalized_context_key="${context_key//\\\\/}"' in apply_source


if __name__ == "__main__":
    test_registry()
    test_unsafe_registry_paths_are_rejected()
    test_context_keys_are_unique_across_registered_bundles()
    print("fix_vendor_avc SELinux bundle registry tests passed")
