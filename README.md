# PaperStacks Database Service

This service manages the Supabase database configuration for the PaperStacks platform.

## Structure

- `/supabase/migrations/` - SQL migration files for database schema
- `/supabase/seed/` - Seed data for development and testing
- `/docs/` - Database documentation and ERD diagrams

## Usage

The migrations in this service define the database structure used by all PaperStacks microservices. Each microservice accesses only the tables relevant to its domain.

## Local Development

1. Set up a local Supabase instance or use the Supabase cloud service
2. Run migrations to set up your schema
3. Seed the database with test data if needed

## Documentation

The `/docs` folder contains detailed information about the database schema, relationships, and usage guidelines for other services. 