-- =============================================
-- 00000000000000_extensions.sql
-- Extensions and Utility Functions
-- =============================================

-- Create dedicated schema for extensions
CREATE SCHEMA IF NOT EXISTS extensions;

-- Enable required extensions in dedicated schema
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "vector" WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA extensions;

-- Grant selective access to extensions
GRANT USAGE ON SCHEMA extensions TO authenticated;
GRANT EXECUTE ON FUNCTION extensions.uuid_generate_v4() TO authenticated;

-- Enable Row Level Security by default
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Generic utility function for updating timestamps
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION set_updated_at() IS 'Generic trigger function to update updated_at timestamp'; 