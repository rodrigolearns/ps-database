#!/bin/bash

# PaperStacks Database Development Workflow Script
# Usage: ./scripts/dev-workflow.sh [command]
# Commands: reset, push, types, watch, help

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

# Function to generate types for paperstacks app
generate_all_types() {
    print_info "Generating TypeScript types for paperstacks app..."
    
    # Generate types for main paperstacks app only
    print_info "→ Generating types for paperstacks app..."
    supabase gen types typescript --local > ../paperstacks/src/types/supabase.ts
    
    print_status "Types generated successfully for paperstacks app"
}

# Function to reset local database and regenerate types
reset_and_sync() {
    print_info "Resetting local database and syncing types..."
    
    supabase db reset
    generate_all_types
    
    print_status "Database reset and types synced"
}

# Function to push to remote and regenerate types
push_and_sync() {
    print_info "Pushing migrations to remote and syncing types..."
    
    supabase db push
    generate_all_types
    
    print_status "Migrations pushed and types synced"
}

# Function to watch for changes
watch_changes() {
    print_info "Starting development watch mode..."
    print_info "This will watch for migration file changes and auto-regenerate types"
    print_warning "Press Ctrl+C to stop watching"
    
    # Initial sync
    reset_and_sync
    
    # Watch for changes (requires fswatch: brew install fswatch)
    if command -v fswatch &> /dev/null; then
        fswatch -o supabase/migrations/ | while read; do
            print_info "📝 Migration change detected, regenerating types..."
            generate_all_types
        done
    else
        print_warning "fswatch not installed. Install with: brew install fswatch"
        print_info "Falling back to manual type generation"
    fi
}

# Function to show help
show_help() {
    echo ""
    echo "PaperStacks Database Development Workflow"
    echo "========================================"
    echo ""
    echo "Usage: ./scripts/dev-workflow.sh [command]"
    echo ""
    echo "Commands:"
    echo "  reset     Reset local database and regenerate types"
    echo "  push      Push migrations to remote and regenerate types"
    echo "  types     Generate TypeScript types for paperstacks app"
    echo "  watch     Watch for migration changes and auto-regenerate types"
    echo "  help      Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./scripts/dev-workflow.sh reset    # Reset local DB + generate types"
    echo "  ./scripts/dev-workflow.sh push     # Push to remote + generate types"
    echo "  ./scripts/dev-workflow.sh types    # Just regenerate types"
    echo "  ./scripts/dev-workflow.sh watch    # Watch mode for development"
    echo ""
}

# Main command handling
case "${1:-help}" in
    "reset")
        reset_and_sync
        ;;
    "push")
        push_and_sync
        ;;
    "types")
        generate_all_types
        ;;
    "watch")
        watch_changes
        ;;
    "help"|*)
        show_help
        ;;
esac
