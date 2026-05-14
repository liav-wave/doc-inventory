# Google Workspace Public Document Inventory (V2)

Finds all publicly accessible documents across a Google Workspace domain — both shared drives and personal drives — using [GAM 7](https://github.com/GAM-team/GAM).

This is the **V2** tool. It extends V1 by also scanning **shared drives**, not just user-owned drives. Both versions use the same GAM installation and can be run independently. See the main setup guide for GAM installation and V1 instructions.

## Output

Results are written to `~/doc_inventory/`:

| File | Description |
|------|-------------|
| `filelistperms.csv` | One row per non-owner permission across all files (shared and personal drives) |
| `run.log` | Timestamped audit log of the entire run |
| `gam_errors.log` | GAM stderr output (only present if errors occurred) |

Output CSV columns (matches V1 format for Google Sheet ingestion):

`Owner`, `id`, `name`, `mimeType`, `permission.allowFileDiscovery`, `permission.deleted`, `permission.displayName`, `permission.domain`, `permission.emailAddress`, `permission.id`, `permission.role`, `permission.type`

## Prerequisites

These should already be in place if you followed the main setup guide:

- **GAM 7** installed and configured (project created, OAuth credentials set up, service account authorized)
- All Drive scopes **PASS** when running `gam user <admin> check serviceaccount`
- **zsh** — required (default on macOS; install via package manager on Linux)
- **Python 3.8+** — required for the categorization step

## Usage

1. Make the script executable (first time only):

   ```sh
   chmod +x gam_inventory.sh
   ```

2. Run it, replacing the paths with your actual GAM binary path and admin email:

   ```sh
   GAM_PATH=/path/to/gam GAM_ADMIN=admin@yourdomain.com ./gam_inventory.sh
   ```

   To find your GAM binary path, run `which gam` or check the alias the installer added to your shell profile.

   `GAM_ADMIN` must be a **super-admin** account. The script uses this identity to enumerate all shared drives, list all users, and temporarily access drives the admin is not a member of.

The script runs in three phases:

1. **Shared Drives** — enumerates all shared drives and lists their files
2. **Personal Drives** — enumerates all users and lists their files
3. **Categorize** — filters for public permissions and writes output CSVs

Intermediate data (raw file listings, user/drive lists) is automatically cleaned up after categorization. Only the final output CSVs and logs are retained.

## Files

| File | Purpose |
|------|---------|
| `gam_inventory.sh` | Main script — collects file metadata via GAM, then calls `categorize.py` |
| `categorize.py` | Processes raw GAM CSV chunks and filters for public files (called automatically) |

## How it works

GAM produces CSV output where each file's permissions are flattened into columns like `permissions.0.type`, `permissions.0.allowFileDiscovery`, `permissions.1.type`, etc. Different files have different numbers of permissions, so column counts vary across rows.

To handle this, the script writes each GAM call to a separate CSV chunk file. The categorizer processes each chunk independently with its own header, avoiding column misalignment.

The categorizer expands each file's permissions into one row per non-owner permission, mapping GAM's indexed `permissions.N.field` columns to the flat `permission.field` format used by V1. Owner permissions are excluded (matching V1's `pm not role owner` filter).

## Shared Drive ACL behavior

For shared drives the admin is **not** already a member of, the script temporarily grants **organizer** access, scans the drive, then immediately removes the access. This is tracked and cleaned up automatically, including on script interruption (SIGINT/SIGTERM).

**Communicate this to the client before running.** The temporary ACL grants will appear in the Google Admin audit log. If the script crashes hard enough that the trap doesn't fire (e.g., `kill -9`, power loss), orphaned ACLs may remain. Check for these with:

```sh
gam print drivefileacls <drive_id> | grep "admin@yourdomain.com"
```

To remove an orphaned ACL manually:

```sh
gam delete drivefileacl <drive_id> admin@yourdomain.com
```

## V1 vs V2 comparison

| | V1 | V2 |
|---|---|---|
| **Scans user-owned drives** | Yes | Yes |
| **Scans shared drives** | No | Yes |
| **Output format** | Raw CSV (use with spreadsheet tool) | `filelistperms.csv` — same column format as V1, compatible with the same Google Sheet |
| **Maturity** | Battle-tested | Internally tested |
| **GAM version** | GAM 7 | GAM 7 |

## Running tests

Run the integration tests against a **test/staging Workspace**, not production:

```sh
GAM_PATH=/path/to/gam GAM_ADMIN=admin@testdomain.com ./test_inventory.sh
```

The tests require at least one shared drive the admin **is** a member of, and ideally one they are **not** a member of (to test temp ACL cleanup). Tests run against live data — they call `gam_inventory.sh` end-to-end.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Another instance is running` | Stale lockfile from a crashed run | `rm -rf ~/doc_inventory/.inventory.lock` |
| `Output directory is a symlink` | `~/doc_inventory` is a symlink | Remove the symlink; the script creates the directory itself |
| Output CSVs are empty | GAM can't access drives (scope/delegation issue) | Run `gam user <admin> check serviceaccount` and fix any FAIL scopes |
| `FAILED to remove temp organizer access` | ACL cleanup failed for a shared drive | Remove manually (see ACL section above); check `run.log` for the drive ID |
| `GAM exited with code 60` | No files found on a drive | Normal — means the drive is empty, not an error |

## Security considerations

- **File permissions**: The script sets `umask 077` so all output files are readable only by the running user.
- **Intermediate data cleanup**: Raw file listings contain metadata for every file in the Workspace (not just public ones). These are deleted automatically after categorization.
- **Error visibility**: GAM errors are logged to `gam_errors.log` and surfaced in the run summary. If GAM fails on any drive or user, the script warns that results may be incomplete rather than silently reporting zero findings.
- **CSV injection protection**: Output CSVs are sanitized to prevent formula injection when opened in Excel or Google Sheets.
- **Audit trail**: Every run produces a timestamped `run.log` recording which drives/users were scanned, file counts, errors, and warnings.
- **No hardcoded credentials**: GAM path and admin email must be provided at runtime via environment variables or arguments.
