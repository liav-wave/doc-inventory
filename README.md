# Google Workspace Public Document Inventory

Finds all publicly accessible documents across a Google Workspace domain — both shared drives and personal drives — using [GAMADV-XTD3 / GAM 7](https://github.com/GAM-team/GAM).

## Output

Results are written to `~/doc_inventory/`:

| File | Description |
|------|-------------|
| `public_internet.csv` | Files discoverable via internet search (`type=anyone`, `allowFileDiscovery=True`) |
| `public_link.csv` | Files accessible to anyone with the link (`type=anyone`, `allowFileDiscovery=False`) |
| `run.log` | Timestamped audit log of the entire run |
| `gam_errors.log` | GAM stderr output (only present if errors occurred) |

Each output CSV contains: `Owner`, `id`, `name`, `mimeType`, `webViewLink`.

## Prerequisites

- **zsh** — required (default on macOS; install via package manager on Linux)
- [GAM 7 (GAMADV-XTD3)](https://github.com/GAM-team/GAM) installed and configured
- OAuth client credentials created (`gam oauth create`)
- Service account with domain-wide delegation authorized, including Drive scopes (`gam user <admin> check serviceaccount` — all scopes should PASS)
- Python 3.8+

## Setup

1. Clone this repo and ensure the script is executable:

   ```sh
   chmod +x gam_inventory.sh
   ```

2. Install and configure [GAM 7](https://github.com/GAM-team/GAM/wiki) if not already present:

   ```sh
   # Create OAuth credentials
   gam oauth create

   # Create and authorize the service account for domain-wide delegation
   gam create project
   gam user admin@clientdomain.com check serviceaccount
   ```

   All scopes must show **PASS**, especially the Drive scopes. If any fail, follow the prompts to authorize them in the Google Admin Console under **Security > API Controls > Domain-wide Delegation**.

3. Set the required environment variables:

   ```sh
   export GAM_PATH="/path/to/gam"
   export GAM_ADMIN="admin@clientdomain.com"
   ```

   `GAM_ADMIN` must be a **super-admin** account. The script uses this identity to enumerate all shared drives, list all users, and temporarily access drives the admin isn't a member of.

   Or pass them as positional arguments (see Usage below).

## Usage

```sh
# Using environment variables
GAM_PATH=/path/to/gam GAM_ADMIN=admin@example.com ./gam_inventory.sh

# Or using positional arguments
./gam_inventory.sh /path/to/gam admin@example.com
```

The script runs in three phases:

1. **Shared Drives** — enumerates all shared drives and lists their files
2. **Personal Drives** — enumerates all users and lists their files
3. **Categorize** — filters for public permissions and writes output CSVs

Intermediate data (raw file listings, user/drive lists) is automatically cleaned up after categorization. Only the final output CSVs and logs are retained.

### Re-categorize without re-fetching

If you need to re-process existing chunk data before cleanup runs (e.g., during development), you can run the categorizer directly:

```sh
python3 categorize.py ~/doc_inventory
```

## Files

| File | Purpose |
|------|---------|
| `gam_inventory.sh` | Main script — collects file metadata via GAM |
| `categorize.py` | Processes raw GAM CSV chunks and filters for public files |

## How it works

GAM produces CSV output where each file's permissions are flattened into columns like `permissions.0.type`, `permissions.0.allowFileDiscovery`, `permissions.1.type`, etc. Different files have different numbers of permissions, so column counts vary across rows.

To handle this, the script writes each GAM call to a separate CSV chunk file. The categorizer processes each chunk independently with its own header, avoiding column misalignment.

A file is considered publicly shared when any `permissions.N.type` column equals `anyone`. The `allowFileDiscovery` flag on that same permission distinguishes internet-searchable files from link-only files.

## Important: Shared Drive ACL behavior

For shared drives the admin is **not** already a member of, the script temporarily grants **organizer** access, scans the drive, then immediately removes the access. This is tracked and cleaned up automatically, including on script interruption (SIGINT/SIGTERM).

**Communicate this to the client before running.** The temporary ACL grants will appear in the Google Admin audit log. If the script crashes hard enough that the trap doesn't fire (e.g., `kill -9`, power loss), orphaned ACLs may remain. Check for these with:

```sh
# List ACLs on a specific shared drive
gam print drivefileacls <drive_id> | grep "$GAM_ADMIN"
```

To remove an orphaned ACL manually:

```sh
gam delete drivefileacl <drive_id> admin@clientdomain.com
```

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
