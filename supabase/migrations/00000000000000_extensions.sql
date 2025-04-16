-- Enable required extensions for PaperStacks

-- Enable pgvector extension for vector similarity search
CREATE EXTENSION IF NOT EXISTS vector;

-- Enable UUID extension (if not already enabled by default)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enable pg_stat_statements for query performance monitoring
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Comment explaining the purpose of this migration
COMMENT ON EXTENSION vector IS 'vector data type and vector similarity search functions';
