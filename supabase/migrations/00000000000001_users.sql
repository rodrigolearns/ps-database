-- =============================================
-- 00000000000001_users.sql
-- User Accounts and User Preference Embeddings
-- =============================================

-- Create an ENUM type for user roles
DO $$ BEGIN
  CREATE TYPE user_role AS ENUM ('user', 'editor', 'admin', 'superadmin');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON TYPE user_role IS 'Roles for users in the system';

-- Create User_Accounts table
CREATE TABLE IF NOT EXISTS "User_Accounts" (
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
  role user_role NOT NULL DEFAULT 'user',
  default_count INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  last_login TIMESTAMPTZ,
  search_vector tsvector GENERATED ALWAYS AS (
    to_tsvector('english', coalesce(username, '') || ' ' || coalesce(full_name, ''))
  ) STORED
);
COMMENT ON TABLE "User_Accounts" IS 'User accounts for the platform. Users can view and update their own account (limited to full_name, affiliations, and bio)';
COMMENT ON COLUMN "User_Accounts".user_id IS 'Primary key for the user';
COMMENT ON COLUMN "User_Accounts".auth_id IS 'Foreign key to Supabase auth.users';
COMMENT ON COLUMN "User_Accounts".email IS 'Email address of the user';
COMMENT ON COLUMN "User_Accounts".username IS 'Unique username for the user';
COMMENT ON COLUMN "User_Accounts".full_name IS 'Full name of the user';
COMMENT ON COLUMN "User_Accounts".bio IS 'User biography';
COMMENT ON COLUMN "User_Accounts".orcid IS 'ORCID identifier for the user';
COMMENT ON COLUMN "User_Accounts".affiliations IS 'Institutional affiliations of the user';
COMMENT ON COLUMN "User_Accounts".research_interests IS 'Research interests of the user';
COMMENT ON COLUMN "User_Accounts".profile_image_url IS 'URL to the user''s profile image';
COMMENT ON COLUMN "User_Accounts".role IS 'Role of the user in the system';
COMMENT ON COLUMN "User_Accounts".default_count IS 'Count of times user has defaulted on review commitments';
COMMENT ON COLUMN "User_Accounts".created_at IS 'When the user account was created';
COMMENT ON COLUMN "User_Accounts".updated_at IS 'When the user account was last updated';
COMMENT ON COLUMN "User_Accounts".last_login IS 'When the user last logged in';
COMMENT ON COLUMN "User_Accounts".search_vector IS 'Full-text search vector combining username and full_name';

-- Create User_Preference_Embeddings table
CREATE TABLE IF NOT EXISTS "User_Preference_Embeddings" (
  embedding_id SERIAL PRIMARY KEY,
  user_id INTEGER REFERENCES "User_Accounts"(user_id) ON DELETE CASCADE,
  preference_vector vector(1536) NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id)
);
COMMENT ON TABLE "User_Preference_Embeddings" IS 'Vector embeddings of user preferences for recommendation';
COMMENT ON COLUMN "User_Preference_Embeddings".embedding_id IS 'Primary key for the embedding';
COMMENT ON COLUMN "User_Preference_Embeddings".user_id IS 'Foreign key to User_Accounts';
COMMENT ON COLUMN "User_Preference_Embeddings".preference_vector IS 'Vector embedding of user preferences';
COMMENT ON COLUMN "User_Preference_Embeddings".created_at IS 'When the embedding was created';
COMMENT ON COLUMN "User_Preference_Embeddings".updated_at IS 'When the embedding was last updated';

-- Trigger: update updated_at on User_Accounts before update
DROP TRIGGER IF EXISTS update_user_accounts_updated_at ON "User_Accounts";
CREATE TRIGGER update_user_accounts_updated_at
BEFORE UPDATE ON "User_Accounts"
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();
