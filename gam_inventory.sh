#!/bin/zsh

# Find all publicly shared documents across a Google Workspace
# (both shared drives and personal drives) using GAM 7.
#
# Outputs:
#   ~/doc_inventory/public_internet.csv  → type=anyone, allowFileDiscovery=True
#   ~/doc_inventory/public_link.csv      → type=anyone, allowFileDiscovery=False

set -uo pipefail

GAM="/Users/liav/bin/gam7/gam"
ADMIN="liav.test@wavefronttesting.com"

OUTDIR="$HOME/doc_inventory"
CHUNKS_DIR="$OUTDIR/chunks"
mkdir -p "$CHUNKS_DIR"

PUBLIC_INTERNET_CSV="$OUTDIR/public_internet.csv"
PUBLIC_LINK_CSV="$OUTDIR/public_link.csv"

rm -f "$PUBLIC_INTERNET_CSV" "$PUBLIC_LINK_CSV"
rm -f "$CHUNKS_DIR"/*.csv

chunk_num=0

# ── Phase 1: Shared Drives ──────────────────────────────────────────────────

print "=== Phase 1: Shared Drives ==="

DRIVES_CSV="$OUTDIR/shareddrives.csv"
$GAM print teamdrives 2>/dev/null > "$DRIVES_CSV"

if [[ -s "$DRIVES_CSV" ]]; then
    tail -n +2 "$DRIVES_CSV" | while IFS=, read -r user drive_id name rest; do
        drive_id="${drive_id//\"/}"
        name="${name//\"/}"
        [[ -z "$drive_id" ]] && continue

        print "  Shared Drive: $name"
        chunk_num=$((chunk_num + 1))

        $GAM user "$ADMIN" print filelist \
            select teamdriveid "$drive_id" \
            fields id,name,mimeType,webViewLink,permissions \
            > "$CHUNKS_DIR/chunk_${chunk_num}.csv" 2>/dev/null || true
    done
else
    print "  No shared drives found."
fi

# ── Phase 2: Personal Drives ────────────────────────────────────────────────

print "\n=== Phase 2: Personal Drives ==="

USERS_CSV="$OUTDIR/users.csv"
$GAM print users fields primaryEmail 2>/dev/null > "$USERS_CSV"

if [[ ! -s "$USERS_CSV" ]]; then
    print "ERROR: Could not retrieve user list."
    exit 1
fi

tail -n +2 "$USERS_CSV" | while IFS=, read -r email rest; do
    email="${email//\"/}"
    [[ -z "$email" || "$email" == "primaryEmail" ]] && continue

    print "  User: $email"
    chunk_num=$((chunk_num + 1))

    $GAM user "$email" print filelist \
        fields id,name,mimeType,webViewLink,permissions \
        > "$CHUNKS_DIR/chunk_${chunk_num}.csv" 2>/dev/null || true
done

# ── Phase 3: Process each chunk independently ───────────────────────────────

print "\n=== Categorizing results ==="

SCRIPT_DIR="${0:a:h}"
python3 "$SCRIPT_DIR/categorize.py" "$OUTDIR"

print "\nDone. Results in $OUTDIR/"
ls -lh "$PUBLIC_INTERNET_CSV" "$PUBLIC_LINK_CSV" 2>/dev/null
