#!/usr/bin/env python3
"""
Categorize GAM file listing chunks into a single permission inventory.

Reads CSV chunks from <outdir>/chunks/ and outputs:
  <outdir>/filelistperms.csv  → one row per non-owner permission

Output columns match V1 format:
  Owner, id, name, mimeType, permission.allowFileDiscovery,
  permission.deleted, permission.displayName, permission.domain,
  permission.emailAddress, permission.id, permission.role, permission.type
"""

import csv
import glob
import os
import re
import sys

# Characters that can trigger formula execution in Excel/Sheets
_FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r")

# Output columns — must match V1 format exactly
OUT_FIELDS = [
    "Owner",
    "id",
    "name",
    "mimeType",
    "permission.allowFileDiscovery",
    "permission.deleted",
    "permission.displayName",
    "permission.domain",
    "permission.emailAddress",
    "permission.id",
    "permission.role",
    "permission.type",
]

# File-level fields (copied directly from the GAM row)
_FILE_FIELDS = ["Owner", "id", "name", "mimeType"]

# Permission sub-fields that GAM outputs as permissions.N.<field>
_PERM_SUBFIELDS = [
    "allowFileDiscovery",
    "deleted",
    "displayName",
    "domain",
    "emailAddress",
    "id",
    "role",
    "type",
]

# Regex to find permission index groups in GAM headers
_PERM_IDX_RE = re.compile(r"^permissions\.(\d+)\.")


def _sanitize_cell(value: str) -> str:
    """Prevent CSV injection by prefixing dangerous values with a single quote."""
    if value and value.startswith(_FORMULA_PREFIXES):
        return f"'{value}"
    return value


def _find_permission_indices(fieldnames: list[str]) -> list[int]:
    """Return sorted unique permission indices found in the CSV header."""
    indices: set[int] = set()
    for fn in fieldnames:
        if fn is None:
            continue
        m = _PERM_IDX_RE.match(fn)
        if m:
            indices.add(int(m.group(1)))
    return sorted(indices)


def categorize(chunks_dir: str, outdir: str) -> dict:
    out_file = os.path.join(outdir, "filelistperms.csv")

    rows: list[dict] = []
    total_files = 0
    total_permissions = 0
    skipped_chunks = 0

    chunk_files = sorted(glob.glob(os.path.join(chunks_dir, "chunk_*.csv")))

    for chunk_path in chunk_files:
        if os.path.getsize(chunk_path) == 0:
            skipped_chunks += 1
            continue

        with open(chunk_path, "r") as f:
            reader = csv.DictReader(f)

            if reader.fieldnames is None or "id" not in reader.fieldnames:
                print(
                    f"  WARNING: Skipping {os.path.basename(chunk_path)}"
                    " — missing expected headers",
                    file=sys.stderr,
                )
                skipped_chunks += 1
                continue

            has_permissions = any(
                "permissions" in fn for fn in reader.fieldnames if fn
            )
            if not has_permissions:
                print(
                    f"  WARNING: Skipping {os.path.basename(chunk_path)}"
                    " — no permissions columns",
                    file=sys.stderr,
                )
                skipped_chunks += 1
                continue

            perm_indices = _find_permission_indices(reader.fieldnames)

            for gam_row in reader:
                total_files += 1

                # Extract file-level fields once
                file_data = {
                    k: _sanitize_cell(gam_row.get(k, "")) for k in _FILE_FIELDS
                }

                # Iterate through each permission on this file
                for idx in perm_indices:
                    prefix = f"permissions.{idx}"
                    role = gam_row.get(f"{prefix}.role", "")

                    # Skip empty permission slots and owner permissions
                    if not role or role == "owner":
                        continue

                    # Build output row: file fields + permission fields
                    out_row = dict(file_data)
                    for subfield in _PERM_SUBFIELDS:
                        gam_key = f"{prefix}.{subfield}"
                        out_row[f"permission.{subfield}"] = _sanitize_cell(
                            gam_row.get(gam_key, "")
                        )

                    rows.append(out_row)
                    total_permissions += 1

    with open(out_file, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=OUT_FIELDS)
        w.writeheader()
        w.writerows(rows)

    return {
        "total_files": total_files,
        "total_permissions": total_permissions,
        "skipped_chunks": skipped_chunks,
    }


if __name__ == "__main__":
    base = (
        sys.argv[1] if len(sys.argv) > 1
        else os.path.expanduser("~/doc_inventory")
    )
    chunks = os.path.join(base, "chunks")

    if not os.path.isdir(chunks):
        print(
            f"ERROR: Chunks directory not found: {chunks}", file=sys.stderr
        )
        sys.exit(1)

    results = categorize(chunks, base)

    print(f"  Total files scanned: {results['total_files']}")
    print(f"  Non-owner permissions found: {results['total_permissions']}")

    if results["skipped_chunks"] > 0:
        print(
            f"  ⚠ Skipped {results['skipped_chunks']} invalid/empty chunks"
            " — results may be incomplete",
            file=sys.stderr,
        )
