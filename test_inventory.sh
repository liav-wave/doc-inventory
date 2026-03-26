#!/bin/zsh

# Integration test: verify that the inventory script does NOT remove
# pre-existing shared drive ACLs, cleans up temp ACLs, produces valid
# output, and sanitizes against CSV injection.
#
# Prerequisites:
#   - GAM configured and working
#   - At least one shared drive the admin is already a member of
#
# Usage:
#   GAM_PATH=/path/to/gam GAM_ADMIN=admin@example.com ./test_inventory.sh

set -uo pipefail

GAM="${1:-${GAM_PATH:?Set GAM_PATH or pass GAM binary path as first argument}}"
ADMIN="${2:-${GAM_ADMIN:?Set GAM_ADMIN or pass admin email as second argument}}"

PASS=0
FAIL=0
SCRIPT_DIR="${0:a:h}"

# ── Helpers ──────────────────────────────────────────────────────────────────

green() { print "\033[32m$*\033[0m" }
red()   { print "\033[31m$*\033[0m" }

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label"
        red "    expected: '$expected'"
        red "    actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_nonempty() {
    local label="$1" value="$2"
    if [[ -n "$value" ]]; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label (value was empty)"
        FAIL=$((FAIL + 1))
    fi
}

assert_empty() {
    local label="$1" value="$2"
    if [[ -z "$value" ]]; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label (expected empty, got '$value')"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label (expected to contain '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local label="$1" file="$2"
    if [[ -f "$file" ]]; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label (file not found: $file)"
        FAIL=$((FAIL + 1))
    fi
}

# ── Find a shared drive the admin is already in ─────────────────────────────

print "\n=== Test: Pre-existing ACL preservation ==="
print "Finding a shared drive the admin already has access to..."

DRIVES_CSV=$("$GAM" print teamdrives 2>/dev/null)
TEST_DRIVE_ID=""
TEST_DRIVE_NAME=""

while IFS=, read -r user drive_id name rest; do
    drive_id="${drive_id//\"/}"
    name="${name//\"/}"
    [[ -z "$drive_id" || "$drive_id" == "id" ]] && continue

    # Check if admin can already list files (has access)
    if "$GAM" user "$ADMIN" print filelist select teamdriveid "$drive_id" fields id maxfiles 1 >/dev/null 2>&1; then
        TEST_DRIVE_ID="$drive_id"
        TEST_DRIVE_NAME="$name"
        break
    fi
done <<< "$DRIVES_CSV"

if [[ -z "$TEST_DRIVE_ID" ]]; then
    red "  SKIP: No shared drive found where admin already has access. Cannot test ACL preservation."
    red "  Add the admin to at least one shared drive and re-run."
    exit 1
fi

print "  Using drive: $TEST_DRIVE_NAME ($TEST_DRIVE_ID)"

# Record the admin's current permission — column 7 is permissions.0.emailAddress
BEFORE_PERMS=$("$GAM" print drivefileacls "$TEST_DRIVE_ID" 2>/dev/null | awk -F',' -v admin="$ADMIN" '$7 == admin' || true)
assert_nonempty "Admin has pre-existing access before run" "$BEFORE_PERMS"

# Extract role from before
BEFORE_ROLE=$(echo "$BEFORE_PERMS" | head -1 | awk -F',' '{for(i=1;i<=NF;i++) if($i ~ /^(organizer|fileOrganizer|writer|commenter|reader)$/) print $i}' | head -1)
print "  Admin role before: $BEFORE_ROLE"

# ── Run the inventory script ────────────────────────────────────────────────

print "\nRunning inventory script..."
"$SCRIPT_DIR/gam_inventory.sh" "$GAM" "$ADMIN" > /dev/null 2>&1

# ── Verify admin still has access ───────────────────────────────────────────

print "\nChecking admin access after run..."
AFTER_PERMS=$("$GAM" print drivefileacls "$TEST_DRIVE_ID" 2>/dev/null | awk -F',' -v admin="$ADMIN" '$7 == admin' || true)

assert_nonempty "Admin still has access after inventory run" "$AFTER_PERMS"

AFTER_ROLE=$(echo "$AFTER_PERMS" | head -1 | awk -F',' '{for(i=1;i<=NF;i++) if($i ~ /^(organizer|fileOrganizer|writer|commenter|reader)$/) print $i}' | head -1)
print "  Admin role after: $AFTER_ROLE"

assert_eq "Admin role unchanged after run" "$BEFORE_ROLE" "$AFTER_ROLE"

# ── Test: temp ACL added and removed for non-member drive ────────────────────

print "\n=== Test: Temp ACL cleanup for non-member drives ==="
print "Finding a shared drive the admin does NOT have access to..."

TEMP_DRIVE_ID=""
TEMP_DRIVE_NAME=""

while IFS=, read -r user drive_id name rest; do
    drive_id="${drive_id//\"/}"
    name="${name//\"/}"
    [[ -z "$drive_id" || "$drive_id" == "id" ]] && continue
    [[ "$drive_id" == "$TEST_DRIVE_ID" ]] && continue

    if ! "$GAM" user "$ADMIN" print filelist select teamdriveid "$drive_id" fields id maxfiles 1 >/dev/null 2>&1; then
        TEMP_DRIVE_ID="$drive_id"
        TEMP_DRIVE_NAME="$name"
        break
    fi
done <<< "$DRIVES_CSV"

if [[ -z "$TEMP_DRIVE_ID" ]]; then
    print "  SKIP: No non-member shared drive found. Cannot test temp ACL cleanup."
else
    print "  Using drive: $TEMP_DRIVE_NAME ($TEMP_DRIVE_ID)"

    # Verify admin does NOT appear as a permissioned user after the run
    # Column 7 (permissions.0.emailAddress) is the actual ACL target; column 1 is just who ran the command
    TEMP_AFTER=$("$GAM" print drivefileacls "$TEMP_DRIVE_ID" 2>/dev/null | awk -F',' -v admin="$ADMIN" '$7 == admin' || true)
    assert_empty "Temp ACL removed for non-member drive" "$TEMP_AFTER"
fi

# ── Test: Output files exist and are valid ───────────────────────────────────

print "\n=== Test: Output file validity ==="

OUTDIR="$HOME/doc_inventory"

assert_file_exists "public_internet.csv exists" "$OUTDIR/public_internet.csv"
assert_file_exists "public_link.csv exists" "$OUTDIR/public_link.csv"
assert_file_exists "run.log exists" "$OUTDIR/run.log"

# Check CSV headers (strip trailing whitespace/CR)
INTERNET_HEADER=$(head -1 "$OUTDIR/public_internet.csv" 2>/dev/null | tr -d '\r\n ' || echo "")
LINK_HEADER=$(head -1 "$OUTDIR/public_link.csv" 2>/dev/null | tr -d '\r\n ' || echo "")
EXPECTED_HEADER=$(echo "Owner,id,name,mimeType,webViewLink" | tr -d '\r\n ')

assert_eq "public_internet.csv has correct header" "$EXPECTED_HEADER" "$INTERNET_HEADER"
assert_eq "public_link.csv has correct header" "$EXPECTED_HEADER" "$LINK_HEADER"

# Check file permissions (should be owner-only due to umask 077)
if [[ -f "$OUTDIR/public_link.csv" ]]; then
    PERMS=$(stat -f '%Lp' "$OUTDIR/public_link.csv" 2>/dev/null || stat -c '%a' "$OUTDIR/public_link.csv" 2>/dev/null)
    assert_eq "Output files are owner-only (600)" "600" "$PERMS"
fi

# Verify intermediate files were cleaned up
if [[ -d "$OUTDIR/chunks" ]]; then
    red "  FAIL: chunks/ directory was not cleaned up"
    FAIL=$((FAIL + 1))
else
    green "  PASS: chunks/ directory cleaned up"
    PASS=$((PASS + 1))
fi

# ── Test: CSV injection sanitization ─────────────────────────────────────────

print "\n=== Test: CSV injection sanitization ==="

MOCK_DIR=$(mktemp -d)
MOCK_CHUNKS="$MOCK_DIR/chunks"
mkdir -p "$MOCK_CHUNKS"

cat > "$MOCK_CHUNKS/chunk_1.csv" << 'EOF'
Owner,id,name,mimeType,webViewLink,permissions.0.type,permissions.0.allowFileDiscovery
evil@test.com,abc123,=CMD('calc'),application/vnd.google-apps.document,https://example.com,anyone,false
evil@test.com,def456,+normal-looking,application/vnd.google-apps.document,https://example.com,anyone,true
evil@test.com,ghi789,-1+1,application/vnd.google-apps.document,https://example.com,anyone,false
evil@test.com,jkl012,@SUM(A1),application/vnd.google-apps.document,https://example.com,anyone,false
safe@test.com,mno345,Normal Doc Name,application/vnd.google-apps.document,https://example.com,anyone,false
EOF

python3 "$SCRIPT_DIR/categorize.py" "$MOCK_DIR" > /dev/null 2>&1

LINK_CONTENT=$(cat "$MOCK_DIR/public_link.csv" 2>/dev/null || echo "")
INTERNET_CONTENT=$(cat "$MOCK_DIR/public_internet.csv" 2>/dev/null || echo "")

assert_contains "= prefix escaped" "'=CMD" "$LINK_CONTENT"
assert_contains "+ prefix escaped" "'+normal" "$INTERNET_CONTENT"
assert_contains "- prefix escaped" "'-1+1" "$LINK_CONTENT"
assert_contains "@ prefix escaped" "'@SUM" "$LINK_CONTENT"

# Normal names should NOT be escaped
NORMAL_LINE=$(grep "mno345" "$MOCK_DIR/public_link.csv" 2>/dev/null || echo "")
assert_contains "Normal names not escaped" "Normal Doc Name" "$NORMAL_LINE"

rm -rf "$MOCK_DIR"

# ── Test: run.log contains timestamps ────────────────────────────────────────

print "\n=== Test: Audit log format ==="

RUN_LOG_CONTENT=$(cat "$OUTDIR/run.log" 2>/dev/null || echo "")
assert_contains "Run log has timestamps" "[2026-" "$RUN_LOG_CONTENT"
assert_contains "Run log records start" "Run started" "$RUN_LOG_CONTENT"
assert_contains "Run log records completion" "Run complete" "$RUN_LOG_CONTENT"
assert_contains "Run log records GAM binary path" "$GAM" "$RUN_LOG_CONTENT"
assert_contains "Run log records admin user" "$ADMIN" "$RUN_LOG_CONTENT"

# ── Summary ──────────────────────────────────────────────────────────────────

print "\n════════════════════════════════"
if [[ $FAIL -eq 0 ]]; then
    green "All $PASS tests passed!"
else
    print "$(green "$PASS passed"), $(red "$FAIL failed")"
fi
print "════════════════════════════════"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
