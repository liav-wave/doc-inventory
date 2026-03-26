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

2. Set the required environment variables:

   ```sh
   export GAM_PATH="/path/to/gam"
   export GAM_ADMIN="admin@yourdomain.com"
   ```

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

## Security considerations

- **File permissions**: The script sets `umask 077` so all output files are readable only by the running user.
- **Intermediate data cleanup**: Raw file listings contain metadata for every file in the Workspace (not just public ones). These are deleted automatically after categorization.
- **Error visibility**: GAM errors are logged to `gam_errors.log` and surfaced in the run summary. If GAM fails on any drive or user, the script warns that results may be incomplete rather than silently reporting zero findings.
- **CSV injection protection**: Output CSVs are sanitized to prevent formula injection when opened in Excel or Google Sheets.
- **Audit trail**: Every run produces a timestamped `run.log` recording which drives/users were scanned, file counts, errors, and warnings.
- **No hardcoded credentials**: GAM path and admin email must be provided at runtime via environment variables or arguments.
