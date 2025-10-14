# PaperStack Database Service

This service manages the Supabase database configuration for the PaperStack platform.

## Structure

- `/supabase/migrations/` - SQL migration files for database schema
- `/scripts/` - Utility scripts for database management

## Local Development

```bash
# Reset local database with migrations
npm run migrate:local

# Generate TypeScript types
npm run generate:types
```

## Production

### Setup

1. Create `.env.production` with your production Supabase credentials
2. Link to production: `supabase link --project-ref your-project-id`

### Commands

```bash
# Push migrations to production
./scripts/production-env.sh supabase db push

# Reset production database (⚠️ requires confirmation)
./scripts/production-env.sh supabase db reset

# Check production status
./scripts/production-env.sh supabase status

# Run any command with production environment
./scripts/production-env.sh [your-command]
```

The script temporarily switches to `.env.production`, runs the command, and restores `.env.local` automatically. 