#!/usr/bin/env python3
"""One-shot: LCMP/Lcmp/lcmp → LACMP/Lacmp/lacmp in this repo (content + filenames)."""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

SKIP_DIR_NAMES = {
    ".git",
    "vendor",
    "node_modules",
    ".phpunit.cache",
}
SKIP_DIR_PAIRS = {
    ("storage", "framework"),
    ("bootstrap", "cache"),
    ("storage", "logs"),
}
SKIP_SCRIPT_NAMES = {
    "rename_lcmp_to_lacmp.py",
    "rename_lacmp_to_lacmp.py",
}
SKIP_FILE_NAMES = {
    ".phpunit.result.cache",
    ".env",
}
REPLACEMENTS = (
    ("LCMP", "LACMP"),
    ("Lcmp", "Lacmp"),
    ("lcmp", "lacmp"),
)


def skip_dir(path: Path, root: Path) -> bool:
    try:
        rel = path.relative_to(root)
    except ValueError:
        return True
    parts = rel.parts
    if any(p in SKIP_DIR_NAMES for p in parts):
        return True
    for i in range(len(parts) - 1):
        if (parts[i], parts[i + 1]) in SKIP_DIR_PAIRS:
            return True
    return False


def is_binary(data: bytes) -> bool:
    if b"\0" in data[:8192]:
        return True
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return True
    return False


def rewrite_text(text: str) -> str:
    for old, new in REPLACEMENTS:
        text = text.replace(old, new)
    return text


def rewrite_name(name: str) -> str:
    return rewrite_text(name)


def iter_files(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        d = Path(dirpath)
        if skip_dir(d, root):
            dirnames[:] = []
            continue
        dirnames[:] = [n for n in dirnames if not skip_dir(d / n, root)]
        for name in filenames:
            if name in SKIP_FILE_NAMES:
                continue
            yield d / name


def collect_rename_targets(root: Path) -> list[Path]:
    targets: list[Path] = []
    for dirpath, dirnames, filenames in os.walk(root, topdown=False):
        d = Path(dirpath)
        if skip_dir(d, root):
            continue
        for name in filenames:
            p = d / name
            if name in SKIP_SCRIPT_NAMES or name in SKIP_FILE_NAMES:
                continue
            if rewrite_name(name) != name:
                targets.append(p)
        for name in dirnames:
            p = d / name
            if skip_dir(p, root):
                continue
            if rewrite_name(name) != name:
                targets.append(p)
    targets.sort(key=lambda p: len(p.parts), reverse=True)
    return targets


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print edits and renames; write nothing",
    )
    parser.add_argument(
        "--root",
        type=Path,
        default=None,
        help="Repo root (default: parent of tools/)",
    )
    args = parser.parse_args()
    root = (args.root or Path(__file__).resolve().parent.parent).resolve()
    if not root.is_dir():
        print(f"Not a directory: {root}", file=sys.stderr)
        return 2

    edited: list[str] = []
    for path in iter_files(root):
        if path.name in SKIP_SCRIPT_NAMES:
            continue
        try:
            data = path.read_bytes()
        except OSError as e:
            print(f"skip unreadable {path}: {e}", file=sys.stderr)
            continue
        if is_binary(data):
            continue
        text = data.decode("utf-8")
        new = rewrite_text(text)
        if new == text:
            continue
        rel = str(path.relative_to(root))
        edited.append(rel)
        if not args.dry_run:
            path.write_text(new, encoding="utf-8")

    renamed: list[str] = []
    for path in collect_rename_targets(root):
        dest = path.with_name(rewrite_name(path.name))
        if dest == path:
            continue
        rel_from = str(path.relative_to(root))
        rel_to = str(dest.relative_to(root))
        renamed.append(f"{rel_from} -> {rel_to}")
        if not args.dry_run:
            if dest.exists():
                print(f"rename collision: {dest}", file=sys.stderr)
                return 1
            path.rename(dest)

    prefix = "DRY-RUN " if args.dry_run else ""
    print(f"{prefix}edited {len(edited)} files")
    for rel in edited:
        print(f"  edit {rel}")
    print(f"{prefix}renamed {len(renamed)} paths")
    for line in renamed:
        print(f"  mv {line}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
