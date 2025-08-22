#!/bin/bash

# Meilisearch Upgrade Script
# Usage: ./upgrade-meilisearch.sh [--recover|--silentcheck]
# 
# Prerequisites:
# - Create .env file with MEILISEARCH_URL and MEILI_MASTER_KEY
# - Ensure docker-compose.yml contains meilisearch service
# 
# This script will:
# 1. Check for newer version and ask for confirmation
# 2. Create a dump of current data
# 3. Stop meilisearch, backup database, update version
# 4. Import dump and restart with new version
#
# Recovery mode (--recover):
# Use when stuck with version incompatibility - will restore previous version
# and database backup to allow normal upgrade process
#
# Silent check mode (--silentcheck):
# Checks for available upgrades and prints them (for cron/email notifications)
# Outputs nothing if no upgrade available

set -e

# Configuration
COMPOSE_FILE="../docker-compose.yml"
MEILISEARCH_SERVICE="meilisearch"
VOLUME_NAME="docker_meili_data"

# Load environment variables
if [[ -f ".env" ]]; then
    source .env
else
    echo "Error: .env file not found"
    echo "Please create a .env file with:"
    echo "MEILISEARCH_URL=http://localhost:7700"
    echo "MEILI_MASTER_KEY=your_master_key_here"
    exit 1
fi

# Check for silent check mode
if [[ "$1" == "--silentcheck" ]]; then
    # Check if docker-compose.yml exists
    if [[ ! -f "$COMPOSE_FILE" ]]; then
        exit 1
    fi
    
    # Get current version
    CURRENT_VERSION=$(grep -oP 'getmeili/meilisearch:\K[v0-9.]+' "$COMPOSE_FILE" | head -1)
    if [[ -z "$CURRENT_VERSION" ]]; then
        exit 1
    fi
    
    # Get latest version from GitHub API
    LATEST_VERSION=$(curl -s "https://api.github.com/repos/meilisearch/meilisearch/releases/latest" | grep -oP '"tag_name": "\K[^"]+' 2>/dev/null)
    
    if [[ -z "$LATEST_VERSION" ]]; then
        exit 1
    fi
    
    # Check if upgrade is available
    if [[ "$CURRENT_VERSION" != "$LATEST_VERSION" ]]; then
        echo "Meilisearch upgrade available: $CURRENT_VERSION -> $LATEST_VERSION"
    fi
    
    # Exit silently if no upgrade (no output)
    exit 0
fi

# Check for recovery mode
if [[ "$1" == "--recover" ]]; then
    echo "=== RECOVERY MODE ==="
    echo "This will restore the previous version and database backup"
    read -p "Continue with recovery? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Recovery cancelled."
        exit 0
    fi
    
    # Find volume
    PROJECT_NAME=$(basename "$(pwd)")
    FULL_VOLUME_NAME="${PROJECT_NAME}_${VOLUME_NAME}"
    
    if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
        ACTUAL_VOLUME_NAME="$VOLUME_NAME"
    elif docker volume inspect "$FULL_VOLUME_NAME" >/dev/null 2>&1; then
        ACTUAL_VOLUME_NAME="$FULL_VOLUME_NAME"
    else
        # Try to find any volume containing meili_data
        FOUND_VOLUME=$(docker volume ls --format "{{.Name}}" | grep "${VOLUME_NAME}" | head -1)
        if [[ -n "$FOUND_VOLUME" ]]; then
            ACTUAL_VOLUME_NAME="$FOUND_VOLUME"
        else
            echo "Error: Could not find volume"
            exit 1
        fi
    fi
    
    # Find the most recent backup
    echo "Looking for database backup..."
    echo "Available files matching pattern:"
    docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "ls -la /meili_data/data.ms_*.backup 2>/dev/null || echo 'No backup files found'"
    
    BACKUP_FILE=$(docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "ls -t /meili_data/data.ms_*.backup 2>/dev/null | grep -E 'data\.ms_[0-9_]+_[v][0-9]+\.[0-9]+\.[0-9]+\.backup$' | head -1" || echo "")
    
    if [[ -z "$BACKUP_FILE" ]]; then
        echo "No automatic database backup found."
        echo "Checking for existing database..."
        
        # Check if there's a current database that might be incompatible
        HAS_DB=$(docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "[ -d /meili_data/data.ms ] && echo 'exists' || echo 'not_found'")
        
        if [[ "$HAS_DB" == "exists" ]]; then
            echo "Found existing database. Checking docker-compose.yml for version..."
            CURRENT_VERSION=$(grep -oP 'getmeili/meilisearch:\K[v0-9.]+' "$COMPOSE_FILE" | head -1)
            echo "Current version in compose file: $CURRENT_VERSION"
            
            # Check for available dumps
            echo "Checking for available dump files..."
            AVAILABLE_DUMPS=$(docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "ls -t /meili_data/dumps/*.dump 2>/dev/null | head -5" || echo "")
            
            if [[ -n "$AVAILABLE_DUMPS" ]]; then
                echo "Found dump files. Would you like to:"
                echo "1. Restore from the most recent dump file"
                echo "2. Enter a specific version to revert to"
                echo "3. Cancel recovery"
                echo ""
                read -p "Choose option (1/2/3): " RECOVERY_OPTION
                
                if [[ "$RECOVERY_OPTION" == "1" ]]; then
                    # Show available dumps and let user choose
                    echo "Available dump files:"
                    docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "ls -lt /meili_data/dumps/*.dump 2>/dev/null | head -10"
                    
                    echo ""
                    echo "Please choose a dump file:"
                    echo "1. Use most recent dump (may be from newer version)"
                    echo "2. Use dump with matching version (if available)"
                    echo "3. Enter specific dump filename"
                    echo "4. Cancel"
                    echo ""
                    read -p "Choose option (1/2/3/4): " DUMP_CHOICE
                    
                    if [[ "$DUMP_CHOICE" == "1" ]]; then
                        LATEST_DUMP=$(docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "ls -t /meili_data/dumps/*.dump 2>/dev/null | head -1" || echo "")
                        DUMP_FILENAME=$(basename "$LATEST_DUMP")
                    elif [[ "$DUMP_CHOICE" == "2" ]]; then
                        # Try to find a dump with matching version
                        CURRENT_VERSION=$(grep -oP 'getmeili/meilisearch:\K[v0-9.]+' "$COMPOSE_FILE" | head -1)
                        MATCHING_DUMP=$(docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "ls -t /meili_data/dumps/*${CURRENT_VERSION}*.dump 2>/dev/null | head -1" || echo "")
                        if [[ -n "$MATCHING_DUMP" ]]; then
                            DUMP_FILENAME=$(basename "$MATCHING_DUMP")
                            echo "Found matching dump: $DUMP_FILENAME"
                        else
                            echo "No dump found for version $CURRENT_VERSION, using most recent..."
                            LATEST_DUMP=$(docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "ls -t /meili_data/dumps/*.dump 2>/dev/null | head -1" || echo "")
                            DUMP_FILENAME=$(basename "$LATEST_DUMP")
                        fi
                    elif [[ "$DUMP_CHOICE" == "3" ]]; then
                        read -p "Enter dump filename: " DUMP_FILENAME
                    else
                        echo "Recovery cancelled."
                        exit 1
                    fi
                    
                    if [[ -n "$DUMP_FILENAME" ]]; then
                        echo "Using dump file: $DUMP_FILENAME"
                        
                        # Extract version from dump filename if possible
                        DUMP_VERSION=$(echo "$DUMP_FILENAME" | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
                        if [[ -n "$DUMP_VERSION" ]]; then
                            echo "Detected version from dump: $DUMP_VERSION"
                            REVERT_VERSION="$DUMP_VERSION"
                        else
                            echo "Could not detect version from dump filename."
                            read -p "Enter version to use (e.g., v1.15.0): " REVERT_VERSION
                        fi
                        
                        # Add 'v' prefix if not provided
                        if [[ ! "$REVERT_VERSION" =~ ^v ]]; then
                            REVERT_VERSION="v$REVERT_VERSION"
                        fi
                        
                        echo "Reverting to $REVERT_VERSION and importing dump..."
                        sed -i "s|getmeili/meilisearch:[v0-9.]*|getmeili/meilisearch:$REVERT_VERSION|g" "$COMPOSE_FILE"
                        
                        # Remove current database and import dump
                        docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "rm -rf /meili_data/data.ms"
                        
                        echo "Starting meilisearch with $REVERT_VERSION and importing dump..."
                        echo "Note: This may take several minutes depending on dump size..."
                        
                        # Try to import with timeout, but allow longer for large dumps
                        timeout 600 docker compose run --rm meilisearch \
                            meilisearch --import-dump "/meili_data/dumps/$DUMP_FILENAME" --master-key="$MEILI_MASTER_KEY" || {
                            echo "Import process completed (or timed out after 10 minutes)"
                            echo "Checking if import was successful..."
                        }
                        
                        echo "Starting meilisearch service..."
                        docker compose up -d meilisearch
                        
                        echo ""
                        echo "Recovery completed!"
                        echo "- Reverted to: $REVERT_VERSION"
                        echo "- Imported from dump: $DUMP_FILENAME"
                        echo "- You can now run the upgrade script normally"
                        exit 0
                    fi
                elif [[ "$RECOVERY_OPTION" == "2" ]]; then
                    read -p "Enter version to revert to (e.g., v1.15.0): " REVERT_VERSION
                    
                    if [[ "$REVERT_VERSION" == "cancel" || -z "$REVERT_VERSION" ]]; then
                        echo "Recovery cancelled."
                        exit 1
                    fi
                    
                    # Add 'v' prefix if not provided
                    if [[ ! "$REVERT_VERSION" =~ ^v ]]; then
                        REVERT_VERSION="v$REVERT_VERSION"
                    fi
                    
                    echo "Reverting to $REVERT_VERSION..."
                    sed -i "s|getmeili/meilisearch:[v0-9.]*|getmeili/meilisearch:$REVERT_VERSION|g" "$COMPOSE_FILE"
                    
                    echo "Starting meilisearch with $REVERT_VERSION..."
                    docker compose up -d meilisearch
                    
                    echo ""
                    echo "Recovery completed!"
                    echo "- Reverted to: $REVERT_VERSION"
                    echo "- Kept existing database"
                    echo "- You can now run the upgrade script normally"
                    exit 0
                else
                    echo "Recovery cancelled."
                    exit 1
                fi
            else
                echo "No dump files found. Available options:"
                echo "1. Enter a specific version (e.g., v1.15.0)"
                echo "2. Cancel recovery"
                echo ""
                read -p "Enter version to revert to (or 'cancel'): " REVERT_VERSION
                
                if [[ "$REVERT_VERSION" == "cancel" || -z "$REVERT_VERSION" ]]; then
                    echo "Recovery cancelled."
                    exit 1
                fi
                
                # Add 'v' prefix if not provided
                if [[ ! "$REVERT_VERSION" =~ ^v ]]; then
                    REVERT_VERSION="v$REVERT_VERSION"
                fi
                
                echo "Reverting to $REVERT_VERSION..."
                sed -i "s|getmeili/meilisearch:[v0-9.]*|getmeili/meilisearch:$REVERT_VERSION|g" "$COMPOSE_FILE"
                
                echo "Starting meilisearch with $REVERT_VERSION..."
                docker compose up -d meilisearch
                
                echo ""
                echo "Recovery completed!"
                echo "- Reverted to: $REVERT_VERSION"
                echo "- Kept existing database"
                echo "- You can now run the upgrade script normally"
                exit 0
            fi
        else
            echo "No database found either. You may need to restore from a dump file."
            echo "Available dump files:"
            docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "ls -la /meili_data/dumps/ 2>/dev/null || echo 'No dumps directory found'"
            exit 1
        fi
    fi
    
    echo "Found backup: $BACKUP_FILE"
    
    # Extract version from backup filename
    PREVIOUS_VERSION=$(echo "$BACKUP_FILE" | grep -oP 'data\.ms_[0-9_]+_\K[v0-9.]+' || echo "")
    
    if [[ -z "$PREVIOUS_VERSION" ]]; then
        echo "Error: Could not determine previous version from backup filename"
        exit 1
    fi
    
    echo "Previous version: $PREVIOUS_VERSION"
    
    # Stop meilisearch
    echo "Stopping meilisearch..."
    docker compose stop meilisearch || true
    
    # Remove current database and restore backup
    echo "Restoring database backup..."
    docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "
        rm -rf /meili_data/data.ms 2>/dev/null || true
        mv $BACKUP_FILE /meili_data/data.ms
    "
    
    # Restore previous version in docker-compose.yml
    echo "Restoring previous version in docker-compose.yml..."
    sed -i "s|getmeili/meilisearch:[v0-9.]*|getmeili/meilisearch:$PREVIOUS_VERSION|g" "$COMPOSE_FILE"
    
    # Start meilisearch
    echo "Starting meilisearch with previous version..."
    docker compose up -d meilisearch
    
    echo ""
    echo "Recovery completed!"
    echo "- Restored version: $PREVIOUS_VERSION"
    echo "- Database restored from backup"
    echo "- You can now run the upgrade script normally"
    
    exit 0
fi

# Check if docker-compose.yml exists
if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "Error: $COMPOSE_FILE not found"
    exit 1
fi

# Get meilisearch current version
CURRENT_VERSION=$(grep -oP 'getmeili/meilisearch:\K[v0-9.]+' "$COMPOSE_FILE" | head -1)
if [[ -z "$CURRENT_VERSION" ]]; then
    echo "Error: Could not find meilisearch version in $COMPOSE_FILE"
    exit 1
fi

echo "Current version: $CURRENT_VERSION"

# Get latest version from GitHub API
echo "Checking for latest version..."
LATEST_VERSION=$(curl -s "https://api.github.com/repos/meilisearch/meilisearch/releases/latest" | grep -oP '"tag_name": "\K[^"]+')

if [[ -z "$LATEST_VERSION" ]]; then
    echo "Error: Could not fetch latest version"
    exit 1
fi

echo "Latest version: $LATEST_VERSION"

# Check if upgrade is needed
if [[ "$CURRENT_VERSION" == "$LATEST_VERSION" ]]; then
    echo "Already on latest version. Nothing to do."
    exit 0
fi

# Ask user if they want to upgrade
echo ""
echo "Upgrade available: $CURRENT_VERSION -> $LATEST_VERSION"
read -p "Do you want to upgrade? (y/N): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Upgrade cancelled."
    exit 0
fi

echo ""
echo "Starting upgrade process..."

# Check if meilisearch is running
echo "Checking if meilisearch is running..."
if ! curl -s "$MEILISEARCH_URL/health" > /dev/null 2>&1; then
    echo "Error: Meilisearch is not running or not accessible at $MEILISEARCH_URL"
    echo "Please start meilisearch first: docker compose up -d meilisearch"
    exit 1
fi

# Create dump
echo "Creating dump..."
DUMP_DATE=$(date +%Y%m%d_%H%M)
DUMP_RESPONSE=$(curl -s -X POST "$MEILISEARCH_URL/dumps" \
    -H "Authorization: Bearer $MEILI_MASTER_KEY")

TASK_UID=$(echo "$DUMP_RESPONSE" | grep -oP '"taskUid":\s*\K[0-9]+')
if [[ -z "$TASK_UID" ]]; then
    echo "Error: Failed to create dump"
    echo "Response: $DUMP_RESPONSE"
    exit 1
fi

echo "Dump task created with UID: $TASK_UID"

# Wait for dump to complete
echo "Waiting for dump to complete..."
while true; do
    TASK_STATUS=$(curl -s "$MEILISEARCH_URL/tasks/$TASK_UID" \
        -H "Authorization: Bearer $MEILI_MASTER_KEY" | \
        grep -oP '"status":\s*"\K[^"]+')
    
    if [[ "$TASK_STATUS" == "succeeded" ]]; then
        echo "Dump completed successfully"
        break
    elif [[ "$TASK_STATUS" == "failed" ]]; then
        echo "Error: Dump creation failed"
        exit 1
    else
        echo "Dump status: $TASK_STATUS"
        sleep 5
    fi
done

# Get dump filename
DUMP_DETAILS=$(curl -s "$MEILISEARCH_URL/tasks/$TASK_UID" \
    -H "Authorization: Bearer $MEILI_MASTER_KEY")
DUMP_UID=$(echo "$DUMP_DETAILS" | grep -oP '"dumpUid":\s*"\K[^"]+')
DUMP_FILENAME="$DUMP_UID.dump"

# Create new dump filename with date and version
NEW_DUMP_FILENAME="${DUMP_DATE}_${CURRENT_VERSION}.dump"
echo "Dump file: $DUMP_FILENAME -> $NEW_DUMP_FILENAME"

# Stop meilisearch container
echo "Stopping meilisearch container..."
docker compose stop meilisearch

# Backup database using named volume
echo "Backing up database..."
# Docker Compose prefixes volume names with project directory name
PROJECT_NAME=$(basename "$(pwd)")
FULL_VOLUME_NAME="${PROJECT_NAME}_${VOLUME_NAME}"

# Try to find the actual volume name - check multiple possibilities
if docker volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    ACTUAL_VOLUME_NAME="$VOLUME_NAME"
elif docker volume inspect "$FULL_VOLUME_NAME" >/dev/null 2>&1; then
    ACTUAL_VOLUME_NAME="$FULL_VOLUME_NAME"
else
    # Try to find any volume containing meili_data
    FOUND_VOLUME=$(docker volume ls --format "{{.Name}}" | grep "${VOLUME_NAME}" | head -1)
    if [[ -n "$FOUND_VOLUME" ]]; then
        ACTUAL_VOLUME_NAME="$FOUND_VOLUME"
        echo "Found volume: $ACTUAL_VOLUME_NAME"
    else
        echo "Error: Could not find volume. Tried: $VOLUME_NAME and $FULL_VOLUME_NAME"
        echo "Available volumes:"
        docker volume ls | grep meili
        echo ""
        echo "Please update the VOLUME_NAME variable in the script to match your actual volume name."
        echo "Based on the output above, try setting: VOLUME_NAME=\"docker_meili_data\""
        exit 1
    fi
fi

echo "Using volume: $ACTUAL_VOLUME_NAME"

# Use docker run to check and backup the database from inside a container
echo "Checking for existing database..."
DB_EXISTS=$(docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "[ -d /meili_data/data.ms ] && echo 'exists' || echo 'not_found'")

if [[ "$DB_EXISTS" == "exists" ]]; then
    echo "Backing up existing database..."
    docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "mv /meili_data/data.ms /meili_data/data.ms_${DUMP_DATE}_${CURRENT_VERSION}.backup"
    echo "Database backed up to: data.ms_${DUMP_DATE}_${CURRENT_VERSION}.backup"
else
    echo "No existing database found (this is normal for first-time setup)"
fi

# Rename dump file to include date and version
echo "Renaming dump file..."
DUMP_EXISTS=$(docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "[ -f /meili_data/dumps/$DUMP_FILENAME ] && echo 'exists' || echo 'not_found'")

if [[ "$DUMP_EXISTS" == "exists" ]]; then
    docker run --rm -v "$ACTUAL_VOLUME_NAME":/meili_data alpine sh -c "mv /meili_data/dumps/$DUMP_FILENAME /meili_data/dumps/$NEW_DUMP_FILENAME"
    echo "Renamed dump file to: $NEW_DUMP_FILENAME"
else
    echo "Warning: Could not find dump file at /meili_data/dumps/$DUMP_FILENAME"
fi

# Update docker-compose.yml
echo "Updating docker-compose.yml..."
sed -i "s|getmeili/meilisearch:$CURRENT_VERSION|getmeili/meilisearch:$LATEST_VERSION|g" "$COMPOSE_FILE"

# Start meilisearch with import (this will exit after import)
echo "Starting meilisearch and importing dump..."
echo "Note: This may take several minutes depending on dump size..."
timeout 600 docker compose run --rm meilisearch \
    meilisearch --import-dump "/meili_data/dumps/$NEW_DUMP_FILENAME" --master-key="$MEILI_MASTER_KEY" || {
    echo "Import process completed (or timed out after 10 minutes)"
    echo "Checking if import was successful..."
}

echo "Import process completed."

# Full restart to ensure networking works properly (especially for tunnels)
echo "Restarting full stack to ensure proper networking..."
echo "Stopping all services..."
docker compose down

echo "Starting all services..."
docker compose up -d

# Wait for service to be ready
echo "Waiting for meilisearch to be ready..."
echo "This may take a moment for the new version to start and establish networking..."
for i in {1..30}; do
    if curl -s "$MEILISEARCH_URL/health" > /dev/null 2>&1; then
        echo "Meilisearch is ready and accessible!"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 2
done

# Final connectivity check
if ! curl -s "$MEILISEARCH_URL/health" > /dev/null 2>&1; then
    echo "Warning: Meilisearch may not be accessible externally yet."
    echo "Try checking: docker compose ps"
    echo "And: docker compose logs meilisearch"
fi

echo ""
echo "Upgrade completed successfully!"
echo "- From: $CURRENT_VERSION"
echo "- To: $LATEST_VERSION"
echo "- Database backup: data.ms_${DUMP_DATE}_${CURRENT_VERSION}.backup"
echo "- Dump file kept: $NEW_DUMP_FILENAME"