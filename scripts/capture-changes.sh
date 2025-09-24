#!/bin/bash

# capture-changes.sh - Script to capture database changes made via dashboard
# Usage: ./scripts/capture-changes.sh [migration-name]

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if migration name is provided
if [ $# -eq 0 ]; then
    echo -e "${RED}Error: Please provide a migration name${NC}"
    echo "Usage: $0 <migration-name>"
    echo "Example: $0 add_new_column_to_users"
    exit 1
fi

MIGRATION_NAME=$1
TIMESTAMP=$(date +%Y%m%d%H%M%S)

echo -e "${BLUE}🔍 Capturing database changes...${NC}"

# Generate diff between local schema and remote database
echo -e "${YELLOW}Generating diff...${NC}"
supabase db diff --use-migra --schema public,auth,storage > "temp_diff_${TIMESTAMP}.sql"

# Check if there are any changes
if [ ! -s "temp_diff_${TIMESTAMP}.sql" ]; then
    echo -e "${GREEN}✅ No changes detected between local and remote database${NC}"
    rm "temp_diff_${TIMESTAMP}.sql"
    exit 0
fi

echo -e "${GREEN}📄 Changes detected! Creating migration file...${NC}"

# Find the next migration number
LAST_MIGRATION=$(ls supabase/migrations/ | grep -E '^[0-9]+' | sort -V | tail -1)
if [ -z "$LAST_MIGRATION" ]; then
    NEXT_NUMBER="00000000000001"
else
    CURRENT_NUMBER=$(echo "$LAST_MIGRATION" | grep -o '^[0-9]*')
    NEXT_NUMBER=$(printf "%014d" $((10#$CURRENT_NUMBER + 1)))
fi

MIGRATION_FILE="supabase/migrations/${NEXT_NUMBER}_${MIGRATION_NAME}.sql"

# Create the migration file with header
cat > "$MIGRATION_FILE" << EOF
-- Migration: $MIGRATION_NAME
-- Created: $(date '+%Y-%m-%d %H:%M:%S')
-- Source: Dashboard changes captured via supabase db diff

EOF

# Append the diff content
cat "temp_diff_${TIMESTAMP}.sql" >> "$MIGRATION_FILE"

# Clean up temp file
rm "temp_diff_${TIMESTAMP}.sql"

echo -e "${GREEN}✅ Migration created: ${MIGRATION_FILE}${NC}"
echo -e "${BLUE}📝 Please review the migration file before applying${NC}"

# Optional: Show the diff for review
echo -e "${YELLOW}Preview of changes:${NC}"
echo "----------------------------------------"
head -50 "$MIGRATION_FILE"
echo "----------------------------------------"

echo -e "${BLUE}💡 Next steps:${NC}"
echo "1. Review the migration file: $MIGRATION_FILE"
echo "2. Test locally: supabase db reset"
echo "3. If satisfied, commit the migration to version control"
