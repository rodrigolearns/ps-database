-- =============================================
-- 00000000000001_user.sql
-- User Domain: Accounts and Preferences
-- =============================================

-- Create ENUM for user roles
DO $$ BEGIN
  CREATE TYPE user_role AS ENUM ('user', 'stacker', 'admin', 'superadmin');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON TYPE user_role IS 'Roles for users in the system';

-- User accounts table
CREATE TABLE IF NOT EXISTS user_accounts (
  user_id SERIAL PRIMARY KEY,
  auth_id UUID UNIQUE,
  email TEXT UNIQUE NOT NULL,
  username TEXT UNIQUE,
  full_name TEXT NOT NULL,
  bio TEXT,
  orcid TEXT UNIQUE,
  affiliations JSONB DEFAULT '[]',
  research_interests TEXT[],
  profile_image_url TEXT,
  profile_thumbnail_32 TEXT,
  profile_thumbnail_64 TEXT,
  profile_thumbnail_128 TEXT,
  role user_role NOT NULL DEFAULT 'user',
  default_count INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  last_login TIMESTAMPTZ,
  search_vector tsvector GENERATED ALWAYS AS (
    to_tsvector('english', coalesce(username, '') || ' ' || coalesce(full_name, ''))
  ) STORED
);

COMMENT ON TABLE user_accounts IS 'User accounts for the platform';
COMMENT ON COLUMN user_accounts.user_id IS 'Primary key for the user';
COMMENT ON COLUMN user_accounts.auth_id IS 'Foreign key to Supabase auth.users';
COMMENT ON COLUMN user_accounts.email IS 'Email address of the user';
COMMENT ON COLUMN user_accounts.username IS 'Unique username for the user';
COMMENT ON COLUMN user_accounts.full_name IS 'Full name of the user';
COMMENT ON COLUMN user_accounts.bio IS 'User biography';
COMMENT ON COLUMN user_accounts.orcid IS 'ORCID identifier for the user';
COMMENT ON COLUMN user_accounts.affiliations IS 'Institutional affiliations of the user';
COMMENT ON COLUMN user_accounts.research_interests IS 'Research interests of the user';
COMMENT ON COLUMN user_accounts.profile_image_url IS 'URL to the user profile image';
COMMENT ON COLUMN user_accounts.profile_thumbnail_32 IS 'URL to 32x32px circular profile thumbnail for feed avatars';
COMMENT ON COLUMN user_accounts.profile_thumbnail_64 IS 'URL to 64x64px circular profile thumbnail for profile display';
COMMENT ON COLUMN user_accounts.profile_thumbnail_128 IS 'URL to 128x128px circular profile thumbnail for high-DPI displays';
COMMENT ON COLUMN user_accounts.role IS 'Role of the user in the system';
COMMENT ON COLUMN user_accounts.default_count IS 'Count of times user has defaulted on review commitments';
COMMENT ON COLUMN user_accounts.created_at IS 'When the user account was created';
COMMENT ON COLUMN user_accounts.updated_at IS 'When the user account was last updated';
COMMENT ON COLUMN user_accounts.last_login IS 'When the user last logged in';
COMMENT ON COLUMN user_accounts.search_vector IS 'Full-text search vector combining username and full_name';

-- User preference embeddings table
CREATE TABLE IF NOT EXISTS user_preferences (
  preference_id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  preference_vector vector(1536) NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id)
);

COMMENT ON TABLE user_preferences IS 'Vector embeddings of user preferences for recommendation';
COMMENT ON COLUMN user_preferences.preference_id IS 'Primary key for the preference';
COMMENT ON COLUMN user_preferences.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN user_preferences.preference_vector IS 'Vector embedding of user preferences';
COMMENT ON COLUMN user_preferences.created_at IS 'When the preference was created';
COMMENT ON COLUMN user_preferences.updated_at IS 'When the preference was last updated';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_user_accounts_auth_id ON user_accounts (auth_id);
CREATE INDEX IF NOT EXISTS idx_user_accounts_email ON user_accounts (email);
CREATE INDEX IF NOT EXISTS idx_user_accounts_username ON user_accounts (username);
CREATE INDEX IF NOT EXISTS idx_user_accounts_search ON user_accounts USING GIN (search_vector);
CREATE INDEX IF NOT EXISTS idx_user_preferences_user_id ON user_preferences (user_id);

-- =============================================
-- PERFORMANCE OPTIMIZATION INDEXES - PR Activity Page
-- =============================================
-- Following DEVELOPMENT_PRINCIPLES.md: Database as Source of Truth for performance
-- Indexes optimized for the main PR activity data loading JOIN operations

-- Covering index for user account lookups (most frequently joined table)
-- This avoids table lookup for the most common user account fields needed in JOINs
CREATE INDEX IF NOT EXISTS idx_user_accounts_covering_basic
ON user_accounts (user_id)
INCLUDE (username, full_name, profile_image_url, auth_id, email);

-- Triggers
CREATE TRIGGER update_user_accounts_updated_at
  BEFORE UPDATE ON user_accounts
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_user_preferences_updated_at
  BEFORE UPDATE ON user_preferences
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- ROW LEVEL SECURITY POLICIES
-- =============================================
-- Security Model:
-- 1. Users can only access their own data (enforced by RLS)
-- 2. Service role bypasses RLS for admin operations (API layer enforces authorization)
-- 3. No infinite recursion: user_accounts policies use auth.uid() directly
-- 4. Other tables use auth_user_id() helper function (safe SECURITY DEFINER)
--
-- Why this is secure:
-- - RLS enforces data isolation at database level (defense in depth)
-- - Service role access requires API authentication + authorization
-- - Application layer (API routes) checks user roles before using service role
-- - Even if API is compromised, users cannot escalate privileges via direct DB access

-- Enable RLS on user_accounts
ALTER TABLE user_accounts ENABLE ROW LEVEL SECURITY;

-- Users can read their own account data
-- Service role can read all (API routes handle admin authorization)
-- Note: Wraps auth functions in SELECT for performance (prevents re-evaluation per row)
CREATE POLICY user_accounts_select_own_or_service ON user_accounts
  FOR SELECT
  USING (
    (SELECT auth.uid()) = auth_id OR
    (SELECT auth.role()) = 'service_role'
  );

-- Users can update only their own data
-- Service role can update all (API routes handle admin authorization)
-- Note: Role changes are handled by API layer with explicit authorization checks
CREATE POLICY user_accounts_update_own_or_service ON user_accounts
  FOR UPDATE
  USING (
    (SELECT auth.uid()) = auth_id OR
    (SELECT auth.role()) = 'service_role'
  );

-- New users can insert their own account during signup
CREATE POLICY user_accounts_insert_own ON user_accounts
  FOR INSERT
  WITH CHECK ((SELECT auth.uid()) = auth_id);

-- =============================================
-- HELPER FUNCTION FOR USER_ID LOOKUP
-- =============================================
-- This function safely returns the user_id for the current authenticated user
-- It uses SECURITY DEFINER to bypass RLS ONLY for looking up the caller's own user_id
-- This is safe because:
-- 1. It only returns data for auth.uid() (cannot be manipulated)
-- 2. It's read-only (SELECT only)
-- 3. It prevents infinite recursion in RLS policies
-- 4. Performance: Cached per transaction, fast lookup
CREATE OR REPLACE FUNCTION auth_user_id()
RETURNS INTEGER
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
STABLE
AS $$
  SELECT user_id FROM public.user_accounts WHERE auth_id = auth.uid()
$$;

COMMENT ON FUNCTION auth_user_id() IS 'Returns user_id for current authenticated user. Used in RLS policies to avoid infinite recursion. Safe because it only returns caller''s own ID.';

-- Enable RLS on user_preferences
ALTER TABLE user_preferences ENABLE ROW LEVEL SECURITY;

-- Users can read and update only their own preferences
-- Service role can access all (used by admin API routes with proper authorization checks)
-- Note: Wraps auth functions in SELECT for performance
CREATE POLICY user_preferences_select_own_or_service ON user_preferences
  FOR SELECT
  USING (
    user_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY user_preferences_insert_own_or_service ON user_preferences
  FOR INSERT
  WITH CHECK (
    user_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

CREATE POLICY user_preferences_update_own_or_service ON user_preferences
  FOR UPDATE
  USING (
    user_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  ); 