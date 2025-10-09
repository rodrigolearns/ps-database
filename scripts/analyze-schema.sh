#!/bin/bash

# analyze-schema.sh - Analyze current database schema
# Provides readable summaries of your database structure

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}📊 PaperStack Database Schema Analysis${NC}"
echo "========================================"

# Check if supabase is running
if ! supabase status | grep -q "API URL"; then
    echo -e "${RED}❌ Supabase is not running. Please start it first with 'supabase start'${NC}"
    exit 1
fi

echo -e "${CYAN}📋 Tables Overview${NC}"
echo "===================="

# Get table information
psql "postgresql://postgres:postgres@localhost:54321/postgres" -c "
SELECT 
    schemaname,
    tablename,
    tableowner
FROM pg_tables 
WHERE schemaname IN ('public', 'auth', 'storage')
ORDER BY schemaname, tablename;
" 2>/dev/null || echo -e "${RED}Could not connect to local database${NC}"

echo -e "\n${CYAN}🔗 Foreign Key Relationships${NC}"
echo "================================"

psql "postgresql://postgres:postgres@localhost:54321/postgres" -c "
SELECT 
    tc.table_name, 
    kcu.column_name, 
    ccu.table_name AS foreign_table_name,
    ccu.column_name AS foreign_column_name 
FROM 
    information_schema.table_constraints AS tc 
    JOIN information_schema.key_column_usage AS kcu
      ON tc.constraint_name = kcu.constraint_name
      AND tc.table_schema = kcu.table_schema
    JOIN information_schema.constraint_column_usage AS ccu
      ON ccu.constraint_name = tc.constraint_name
      AND ccu.table_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY' 
    AND tc.table_schema = 'public'
ORDER BY tc.table_name, kcu.column_name;
" 2>/dev/null || echo -e "${RED}Could not retrieve foreign key information${NC}"

echo -e "\n${CYAN}🔢 Table Row Counts${NC}"
echo "====================="

psql "postgresql://postgres:postgres@localhost:54321/postgres" -c "
SELECT 
    schemaname,
    tablename,
    n_tup_ins as \"Rows Inserted\",
    n_tup_upd as \"Rows Updated\",
    n_tup_del as \"Rows Deleted\"
FROM pg_stat_user_tables 
WHERE schemaname = 'public'
ORDER BY n_tup_ins DESC;
" 2>/dev/null || echo -e "${RED}Could not retrieve row count information${NC}"

echo -e "\n${CYAN}🔍 Recent Migrations${NC}"
echo "======================"
echo "Last 5 migration files:"
ls -la supabase/migrations/ | tail -6

echo -e "\n${CYAN}⚠️  Migration Status${NC}"
echo "====================="
echo "Checking for differences between local and remote..."

# Create a temporary diff to check status
TEMP_DIFF=$(mktemp)
supabase db diff --use-migra --schema public,auth,storage > "$TEMP_DIFF" 2>/dev/null || true

if [ -s "$TEMP_DIFF" ]; then
    echo -e "${YELLOW}⚠️  Differences detected between local and remote database${NC}"
    echo -e "${BLUE}Run 'npm run capture <migration-name>' to create a migration${NC}"
    echo "Preview of differences:"
    head -20 "$TEMP_DIFF"
    if [ $(wc -l < "$TEMP_DIFF") -gt 20 ]; then
        echo "... (truncated, $(wc -l < "$TEMP_DIFF") total lines)"
    fi
else
    echo -e "${GREEN}✅ Local and remote databases are in sync${NC}"
fi

rm "$TEMP_DIFF"

echo -e "\n${BLUE}💡 Quick Actions${NC}"
echo "=================="
echo "• View differences: npm run diff"
echo "• Capture changes: npm run capture <name>"
echo "• Reset local DB: npm run migrate:local"
echo "• Full schema dump: npm run schema:dump"
