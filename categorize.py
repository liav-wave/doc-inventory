#!/usr/bin/env python3
"""
Categorize GAM file listing chunks into public-access categories.

Reads CSV chunks from <outdir>/chunks/ and outputs:
  <outdir>/public_internet.csv  → type=anyone, allowFileDiscovery=True
  <outdir>/public_link.csv      → type=anyone, allowFileDiscovery=False
"""

import csv
import glob
import os
import sys

# Characters that can trigger formula execution in Excel/Sheets
_FORMULA_PREFIXES = ("=", "+", "-", "@", "\t", "\r")


def _sanitize_cell(value: str) -> str:
    """Prevent CSV injection by prefixing dangerous values with a single quote."""
    if value and value.startswith(_FORMULA_PREFIXES):
        return f"'{value}"
    return value


def categorize(chunks_dir: str, outdir: str) -> dict:
    internet_file = os.path.join(outdir, "public_internet.csv")
    link_file = os.path.join(outdir, "public_link.csv")

    out_fields = ["Owner", "id", "name", "mimeType", "webViewLink"]

    seen_internet: set[str] = set()
    seen_link: set[str] = set()
    internet_rows: list[dict] = []
    link_rows: list[dict] = []

    chunk_files = sorted(glob.glob(os.path.join(chunks_dir, "chunk_*.csv")))
    total_files = 0
    skipped_chunks = 0

    for chunk_path in chunk_files:
        if os.path.getsize(chunk_path) == 0:
            skipped_chunks += 1
            continue

        with open(chunk_path, "r") as f:
            reader = csv.DictReader(f)

            # Validate header contains expected columns
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

            for row in reader:
                total_files += 1
                file_id = row.get("id", "")

                for key, val in row.items():
                    if key is None or val is None:
                        continue
                    if not (key.endswith(".type") and "permissions" in key):
                        continue
                    if val != "anyone":
                        continue

                    # Found type=anyone. Check allowFileDiscovery.
                    prefix = key.rsplit(".type", 1)[0]
                    discovery = (
                        row.get(prefix + ".allowFileDiscovery", "").strip()
                    )

                    # Sanitize output fields for CSV injection
                    sanitized = {
                        k: _sanitize_cell(row.get(k, "")) for k in out_fields
                    }

                    if discovery in ("True", "true"):
                        if file_id not in seen_internet:
                            seen_internet.add(file_id)
                            internet_rows.append(sanitized)
                    else:
                        if file_id not in seen_link:
                            seen_link.add(file_id)
                            link_rows.append(sanitized)
                    break

    for path, rows in [(internet_file, internet_rows), (link_file, link_rows)]:
        with open(path, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=out_fields)
            w.writeheader()
            w.writerows(rows)

    return {
        "total_files": total_files,
        "public_internet": len(internet_rows),
        "public_link": len(link_rows),
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
    print(
        f"  Publicly discoverable (internet searchable):"
        f" {results['public_internet']}"
    )
    print(f"  Anyone with the link: {results['public_link']}")

    if results["skipped_chunks"] > 0:
        print(
            f"  ⚠ Skipped {results['skipped_chunks']} invalid/empty chunks"
            " — results may be incomplete",
            file=sys.stderr,
        )
