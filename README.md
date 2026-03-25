# Google Workspace Public Document Inventory

Finds all publicly accessible documents across a Google Workspace domain — both shared drives and personal drives — using [GAMADV-XTD3 / GAM 7](https://github.com/GAM-team/GAM).

## Output

Results are written to `~/doc_inventory/`:

| File | Description |
|------|-------------|
| `public_internet.csv` | Files discoverable via internet search (`type=anyone`, `allowFileDiscovery=True`) |
| `public_link.csv` | Files accessible to anyone with the link (`type=anyone`, `allowFileDiscovery=False`) |

Each CSV contains: `Owner`, `id`, `name`, `mimeType`, `webViewLink`.

## Prerequisites

- [GAM 7 (GAMADV-XTD3)](https://github.com/GAM-team/GAM) installed and configured
- OAuth client credentials created (`gam oauth create`)
- Service account with domain-wide delegation authorized, including Drive scopes (`gam user <admin> check serviceaccount` — all scopes should PASS)
- Python 3.8+

## Setup

1. Clone this repo and ensure the scripts are executable:

   ```sh
   chmod +x gam_inventory.sh
   ```

2. Edit `gam_inventory.sh` to set your environment:

   ```sh
   GAM="/path/to/gam"                  # Path to your GAM binary
   ADMIN="admin@yourdomain.com"        # Workspace admin account
   ```

## Usage

```sh
./gam_inventory.sh
```

The script runs in three phases:

1. **Shared Drives** — enumerates all shared drives and lists their files
2. **Personal Drives** — enumerates all users and lists their files
3. **Categorize** — filters for public permissions and writes output CSVs

### Re-categorize without re-fetching

If you want to re-process existing data (e.g., after tweaking the categorizer):

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
