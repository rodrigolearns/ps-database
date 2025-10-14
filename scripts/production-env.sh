#!/bin/bash

# PaperStack Platform Production Environment Runner
# Usage: ./scripts/production-env.sh [any command]
# 
# Temporarily switches to .env.production for ONE command only
# Always restores .env.local afterward, even on errors

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Check if command provided
if [ $# -eq 0 ]; then
    echo -e "${RED}❌ Error: No command provided${NC}"
    echo -e "${YELLOW}Usage: ./scripts/production-env.sh [command]${NC}"
    echo -e "${YELLOW}Example: ./scripts/production-env.sh supabase db reset${NC}"
    exit 1
fi

# Check if .env.production exists
if [ ! -f "$PROJECT_DIR/.env.production" ]; then
    echo -e "${RED}❌ Error: .env.production not found!${NC}"
    echo -e "${YELLOW}💡 Create .env.production with your production Supabase credentials${NC}"
    exit 1
fi

# Backup current .env if it exists
BACKUP_NEEDED=false
if [ -f "$PROJECT_DIR/.env" ]; then
    cp "$PROJECT_DIR/.env" "$PROJECT_DIR/.env.backup"
    BACKUP_NEEDED=true
fi

# Function to restore environment (called on exit)
restore_env() {
    echo -e "${BLUE}🔄 Restoring local environment...${NC}"
    if [ "$BACKUP_NEEDED" = true ]; then
        mv "$PROJECT_DIR/.env.backup" "$PROJECT_DIR/.env"
    else
        rm -f "$PROJECT_DIR/.env"
    fi
    
    # Always ensure .env.local is the active environment
    if [ -f "$PROJECT_DIR/.env.local" ]; then
        cp "$PROJECT_DIR/.env.local" "$PROJECT_DIR/.env"
        echo -e "${GREEN}✅ Restored to local development environment${NC}"
    else
        echo -e "${YELLOW}⚠️  Warning: .env.local not found, removed .env${NC}"
    fi
}

# Set trap to restore environment on ANY exit (success, error, interrupt)
trap restore_env EXIT

# Switch to production environment
echo -e "${YELLOW}🌍 Switching to PRODUCTION environment...${NC}"
cp "$PROJECT_DIR/.env.production" "$PROJECT_DIR/.env"

# Special safety check for destructive database operations
if [[ "$*" == *"supabase db reset"* ]]; then
    echo -e "${RED}⚠️  DANGER: This will COMPLETELY WIPE your production database!${NC}"
    echo -e "${YELLOW}All data will be permanently lost!${NC}"
    read -p "Type 'DELETE_PRODUCTION_DATA' to confirm: " confirm
    if [ "$confirm" != "DELETE_PRODUCTION_DATA" ]; then
        echo -e "${RED}❌ Production reset cancelled${NC}"
        exit 1
    fi
fi

# Run the command with production environment
cd "$PROJECT_DIR"
echo -e "${YELLOW}🚀 Running PRODUCTION: $*${NC}"

# For database operations, add --linked flag to operate on remote project
if [[ "$*" == *"supabase db"* ]]; then
    # Replace the command to add --linked flag
    modified_cmd=$(echo "$*" | sed 's/supabase db/supabase db/g')
    eval "$modified_cmd --linked"
else
    eval "$@"
fi

echo -e "${GREEN}✅ Production command completed successfully${NC}"

