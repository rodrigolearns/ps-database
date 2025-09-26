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

-- Triggers
CREATE TRIGGER update_user_accounts_updated_at
  BEFORE UPDATE ON user_accounts
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_user_preferences_updated_at
  BEFORE UPDATE ON user_preferences
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at(); 