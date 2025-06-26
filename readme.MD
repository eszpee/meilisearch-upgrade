# Meilisearch Docker Compose Upgrade Script

A simple bash script to safely upgrade self-hosted [Meilisearch](https://www.meilisearch.com/) instances running in Docker Compose. Meilisearch databases are only compatible with the version of Meilisearch used to create them, so the recommended upgrade method is to create a full data dump and reload it into the engine after upgrading. [See more here.](https://www.meilisearch.com/docs/learn/update_and_migration/updating#updating-a-self-hosted-meilisearch-instance)

This script automates this upgrade process for Meilisearch instances running in a Docker Compose environment.

## Features

- **Safe upgrades** with automatic database backups
- **Dump-based migration** ensures data integrity across versions
- **Recovery mode** for fixing broken upgrades
- **Silent monitoring** for cron/email notifications
- **Docker Compose integration** with automatic service management

## Prerequisites

- Docker and Docker Compose
- Running Meilisearch instance in Docker Compose
- `.env` file with configuration

## Setup

1. Download the script:
```bash
wget https://raw.githubusercontent.com/eszpee/meilisearch-upgrade/main/upgrade-meilisearch.sh
chmod +x upgrade-meilisearch.sh
```

2. Create `.env` file (the below is an example):
```bash
MEILISEARCH_URL=http://localhost:7700
MEILI_MASTER_KEY=your_master_key_here
```

3. Ensure your `docker-compose.yml` has a meilisearch service pinned to a working version, like this:
```yaml
services:
  meilisearch:
    image: getmeili/meilisearch:v1.15.0
    volumes:
      - meili_data:/meili_data
    # ... other config
```

## Usage

### Interactive Upgrade
```bash
./upgrade-meilisearch.sh
```
- Checks for new versions
- Creates data dump
- Backs up database 
- Updates to latest version
- Imports data

### Recovery Mode
```bash
./upgrade-meilisearch.sh --recover
```
Use when stuck with version incompatibility. Restores previous version and database backup.

### Silent Check (for monitoring)
```bash
./upgrade-meilisearch.sh --silentcheck
```
- Outputs upgrade info only if available
- Silent when no upgrades
- Usable for cron jobs that only send email if STDOUT was not empty

Example crontab:

```bash
# Check daily at 9 AM
0 9 * * * /path/to/upgrade-meilisearch.sh --silentcheck
```

## How It Works

1. **Version Check**: Compares current version with GitHub releases
2. **Data Safety**: Creates dump via Meilisearch API
3. **Database Backup**: Renames existing database with timestamp
4. **Clean Upgrade**: Removes old database, updates Docker image
5. **Data Restore**: Imports dump into new version
6. **Verification**: Waits for service health check

## File Structure

The script creates timestamped backups, these are persisted outside of the container:
```
/var/lib/docker/volumes/your_meili_data/_data/
├── dumps/
│   └── 20240626_1340_v1.15.0.dump
├── data.ms_20240626_1340_v1.15.0.backup
└── data.ms (current database)
```

Feel free to manually delete old backups if necessary.

## Configuration

Edit these variables at the top of the script if needed:
- `COMPOSE_FILE` (default: docker-compose.yml)
- `MEILISEARCH_SERVICE` (default: meilisearch)
- `VOLUME_NAME` (default: meili_data)

## Troubleshooting

**Container won't start after upgrade:**
```bash
./upgrade-meilisearch.sh --recover
```

**Script can't find volume:**
Check your Docker Compose volume configuration matches the script's `VOLUME_NAME`.

**Permission errors:**
Ensure the script can access Docker without sudo.

## Safety Features

- **Non-destructive**: Always creates backups before changes
- **Rollback capable**: Recovery mode restores previous state  
- **Health checks**: Verifies service is running before/after
- **Error handling**: Exits safely on any failure

## Requirements

- Bash 4+
- Docker Compose v2
- curl
- jq (optional, for better JSON parsing)

## License

MIT License - feel free to modify and distribute.

## Contributing

Issues and pull requests welcome! Please test thoroughly before submitting changes.
