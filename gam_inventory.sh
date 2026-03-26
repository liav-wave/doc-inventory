#!/bin/zsh

# Find all publicly shared documents across a Google Workspace
# (both shared drives and personal drives) using GAM 7.
#
# Prerequisites:
#   - GAM 7 (GAMADV-XTD3) installed and configured
#   - zsh (default on macOS; install on Linux if needed)
#
# Required environment variables or arguments:
#   GAM_PATH   — path to the GAM binary
#   GAM_ADMIN  — Workspace super-admin email address
#
# Usage:
#   GAM_PATH=/path/to/gam GAM_ADMIN=admin@example.com ./gam_inventory.sh
#   ./gam_inventory.sh /path/to/gam admin@example.com
#
# Outputs (in ~/doc_inventory/):
#   public_internet.csv  — type=anyone, allowFileDiscovery=True
#   public_link.csv      — type=anyone, allowFileDiscovery=False
#   run.log              — timestamped audit log of the run

set -euo pipefail
setopt noglob 2>/dev/null || true
umask 077

# ── Configuration ────────────────────────────────────────────────────────────

GAM="${1:-${GAM_PATH:?Set GAM_PATH or pass GAM binary path as first argument}}"
ADMIN="${2:-${GAM_ADMIN:?Set GAM_ADMIN or pass admin email as second argument}}"

if [[ ! -x "$GAM" ]]; then
    print "ERROR: GAM binary not found or not executable: $GAM" >&2
    exit 1
fi

# Validate admin email format
if [[ ! "$ADMIN" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    print "ERROR: Invalid admin email format: $ADMIN" >&2
    exit 1
fi

OUTDIR="$HOME/doc_inventory"
CHUNKS_DIR="$OUTDIR/chunks"
ERROR_LOG="$OUTDIR/gam_errors.log"
RUN_LOG="$OUTDIR/run.log"
SCRIPT_DIR="${0:a:h}"
LOCKFILE="$OUTDIR/.inventory.lock"

# Validate output directory is not a symlink
if [[ -L "$OUTDIR" ]]; then
    print "ERROR: Output directory is a symlink — refusing to write: $OUTDIR" >&2
    exit 1
fi

mkdir -p "$CHUNKS_DIR"

# ── Concurrency lock ────────────────────────────────────────────────────────

if ! mkdir "$LOCKFILE" 2>/dev/null; then
    print "ERROR: Another instance is running (lockfile: $LOCKFILE)" >&2
    print "  If this is stale, remove it: rm -rf $LOCKFILE" >&2
    exit 1
fi

# ── Cleanup trap ─────────────────────────────────────────────────────────────

# Track drives where we added temp ACLs so we can clean up on interrupt
typeset -A pending_acl_removals  # drive_id -> name

cleanup_intermediate() {
    rm -rf "$CHUNKS_DIR"
    rm -f "$OUTDIR/shareddrives.csv" "$OUTDIR/users.csv"
}

cleanup_on_exit() {
    local exit_code=$?

    # Remove any temp ACLs we added but haven't cleaned up yet
    for drive_id in ${(k)pending_acl_removals}; do
        local name="${pending_acl_removals[$drive_id]}"
        log_error "TRAP: Removing orphaned temp ACL on '$name' ($drive_id)"
        "$GAM" delete drivefileacl "$drive_id" "$ADMIN" >>"$ERROR_LOG" 2>&1 || {
            log_error "TRAP: FAILED to remove ACL on '$name' ($drive_id) — MANUAL CLEANUP REQUIRED"
        }
    done

    # Clean intermediate files
    cleanup_intermediate

    # Release lock
    rm -rf "$LOCKFILE"

    exit $exit_code
}

trap cleanup_on_exit EXIT INT TERM HUP

# ── Clean previous run artifacts ─────────────────────────────────────────────

rm -f "$OUTDIR/public_internet.csv" "$OUTDIR/public_link.csv"
rm -f "$CHUNKS_DIR"/*.csv 2>/dev/null || true
rm -f "$ERROR_LOG"

# ── Logging helpers ──────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    print "$msg"
    print "$msg" >> "$RUN_LOG"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*"
    print "$msg" >&2
    print "$msg" >> "$RUN_LOG"
}

# ── Start ────────────────────────────────────────────────────────────────────

log "=== Run started ==="
log "GAM binary: $GAM"
log "Admin user: $ADMIN"
log "Output dir: $OUTDIR"

chunk_num=0
gam_failures=0
acl_cleanup_failures=0

# ── Validate expected CSV columns in a chunk ─────────────────────────────────

validate_chunk() {
    local chunk="$1"
    if [[ ! -s "$chunk" ]]; then
        return 1
    fi
    local header
    header=$(head -1 "$chunk")
    # Check for comma-separated "id" as a distinct column name
    if [[ ",$header," != *",id,"* ]] || [[ "$header" != *"permissions."*".type"* ]]; then
        return 1
    fi
    return 0
}

# ── Validate a drive ID looks like one ───────────────────────────────────────

validate_drive_id() {
    local id="$1"
    # GAM drive IDs are alphanumeric with hyphens and underscores
    if [[ "$id" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 0
    fi
    return 1
}

# ── Run a GAM filelist command and save as a validated chunk ──────────────────

run_gam_filelist() {
    local label="$1"
    shift
    chunk_num=$((chunk_num + 1))
    local chunk_file="$CHUNKS_DIR/chunk_${chunk_num}.csv"

    local gam_exit=0
    "$GAM" "$@" > "$chunk_file" 2>>"$ERROR_LOG" || gam_exit=$?

    # Exit code 60 = no results found (not an error)
    if [[ $gam_exit -eq 60 ]]; then
        log "$label: 0 files (empty)"
        rm -f "$chunk_file"
        return
    elif [[ $gam_exit -ne 0 ]]; then
        log_error "$label: GAM exited with code $gam_exit"
        gam_failures=$((gam_failures + 1))
        rm -f "$chunk_file"
        return
    fi

    if ! validate_chunk "$chunk_file"; then
        log_error "$label: GAM output missing expected CSV headers — discarding"
        gam_failures=$((gam_failures + 1))
        rm -f "$chunk_file"
        return
    fi

    local row_count=$(( $(wc -l < "$chunk_file") - 1 ))
    log "$label: collected $row_count files"
}

# ── Phase 1: Shared Drives ──────────────────────────────────────────────────

log "=== Phase 1: Shared Drives ==="

DRIVES_CSV="$OUTDIR/shareddrives.csv"
"$GAM" print teamdrives > "$DRIVES_CSV" 2>>"$ERROR_LOG" || {
    log_error "Failed to retrieve shared drives list"
    gam_failures=$((gam_failures + 1))
}

if [[ -s "$DRIVES_CSV" ]]; then
    tail -n +2 "$DRIVES_CSV" | while IFS=, read -r user drive_id name rest; do
        drive_id="${drive_id//\"/}"
        name="${name//\"/}"
        [[ -z "$drive_id" ]] && continue

        if ! validate_drive_id "$drive_id"; then
            log_error "Skipping invalid drive ID: $drive_id"
            continue
        fi

        # Check if admin already has access to this drive
        already_member=false
        if "$GAM" user "$ADMIN" print filelist select teamdriveid "$drive_id" fields id maxfiles 1 >/dev/null 2>&1; then
            already_member=true
        fi

        # Grant temporary organizer access if not already a member
        acl_added=false
        if ! $already_member; then
            if "$GAM" add drivefileacl "$drive_id" user "$ADMIN" role organizer >>"$ERROR_LOG" 2>&1; then
                acl_added=true
                pending_acl_removals[$drive_id]="$name"
                log "Shared Drive: $name ($drive_id): granted temp organizer access"
            else
                log "Shared Drive: $name ($drive_id): temp ACL add failed — trying anyway"
            fi
        else
            log "Shared Drive: $name ($drive_id): admin already has access"
        fi

        run_gam_filelist "Shared Drive: $name ($drive_id)" \
            user "$ADMIN" print filelist \
            select teamdriveid "$drive_id" \
            fields id,name,mimeType,webViewLink,permissions

        # Only remove access if we added it
        if $acl_added; then
            if "$GAM" delete drivefileacl "$drive_id" "$ADMIN" >>"$ERROR_LOG" 2>&1; then
                unset "pending_acl_removals[$drive_id]"
                log "Shared Drive: $name ($drive_id): removed temp organizer access"
            else
                log_error "Shared Drive: $name ($drive_id): FAILED to remove temp organizer access — clean up manually!"
                acl_cleanup_failures=$((acl_cleanup_failures + 1))
            fi
        fi
    done
else
    log "No shared drives found."
fi

# ── Phase 2: Personal Drives ────────────────────────────────────────────────

log "=== Phase 2: Personal Drives ==="

USERS_CSV="$OUTDIR/users.csv"
"$GAM" print users fields primaryEmail > "$USERS_CSV" 2>>"$ERROR_LOG" || {
    log_error "Failed to retrieve user list"
    gam_failures=$((gam_failures + 1))
}

if [[ ! -s "$USERS_CSV" ]]; then
    log_error "User list is empty — cannot scan personal drives."
else
    tail -n +2 "$USERS_CSV" | while IFS=, read -r email rest; do
        email="${email//\"/}"
        [[ -z "$email" || "$email" == "primaryEmail" ]] && continue

        run_gam_filelist "User: $email" \
            user "$email" print filelist \
            fields id,name,mimeType,webViewLink,permissions
    done
fi

# ── Phase 3: Categorize ─────────────────────────────────────────────────────

log "=== Categorizing results ==="

python3 "$SCRIPT_DIR/categorize.py" "$OUTDIR" | tee -a "$RUN_LOG"

# ── Cleanup intermediate data ────────────────────────────────────────────────
# (also runs via trap on exit, but explicit call here for clarity)

log "Cleaning up intermediate files..."
cleanup_intermediate

# ── Summary ──────────────────────────────────────────────────────────────────

if [[ -s "$ERROR_LOG" ]]; then
    log "⚠ GAM reported errors during this run — results may be incomplete."
    log "  Review: $ERROR_LOG"
    log "  Failed GAM calls: $gam_failures"
fi

if [[ $acl_cleanup_failures -gt 0 ]]; then
    log "⚠ CRITICAL: $acl_cleanup_failures ACL removal(s) failed — admin may still have access to shared drives."
    log "  Search run.log for 'FAILED to remove temp organizer access' for affected drives."
fi

log "=== Run complete ==="
log "Results in $OUTDIR/"
ls -lh "$OUTDIR/public_internet.csv" "$OUTDIR/public_link.csv" 2>/dev/null

# Exit non-zero if any ACL cleanup failed
[[ $acl_cleanup_failures -eq 0 ]]
