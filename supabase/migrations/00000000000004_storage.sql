-- =============================================
-- 00000000000004_storage.sql
-- Storage Domain: File Storage and Buckets
-- =============================================

-- =============================================
-- Storage Buckets
-- =============================================
-- Create storage bucket for paper submissions
INSERT INTO storage.buckets (id, name)
VALUES 
  ('paper-submissions', 'paper-submissions')
ON CONFLICT (id) DO NOTHING;

-- Note: storage.buckets is a system table, can't add comments to it

-- Storage bucket RLS policies
CREATE POLICY "Authenticated users can read paper submissions"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (bucket_id = 'paper-submissions');

CREATE POLICY "Authenticated users can upload paper submissions"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (bucket_id = 'paper-submissions');

CREATE POLICY "Authenticated users can update their own uploads"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (bucket_id = 'paper-submissions' AND owner = auth.uid());

CREATE POLICY "Authenticated users can delete their own uploads"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (bucket_id = 'paper-submissions' AND owner = auth.uid());

-- =============================================
-- File Storage Metadata Table
-- =============================================
CREATE TABLE IF NOT EXISTS file_storage (
  file_id SERIAL PRIMARY KEY,
  file_name TEXT NOT NULL,
  file_path TEXT NOT NULL UNIQUE,
  file_size BIGINT NOT NULL,
  mime_type TEXT NOT NULL,
  uploaded_by INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  related_paper_id INTEGER REFERENCES papers(paper_id) ON DELETE CASCADE,
  related_activity_id INTEGER,  -- Polymorphic: could be pr_activities or jc_activities
  related_activity_uuid UUID,
  file_category TEXT NOT NULL DEFAULT 'general',
  is_public BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE file_storage IS 'File storage metadata and references';
COMMENT ON COLUMN file_storage.file_id IS 'Primary key for the file';
COMMENT ON COLUMN file_storage.file_name IS 'Original name of the file';
COMMENT ON COLUMN file_storage.file_path IS 'Path to the file in storage bucket';
COMMENT ON COLUMN file_storage.file_size IS 'Size of the file in bytes';
COMMENT ON COLUMN file_storage.mime_type IS 'MIME type of the file';
COMMENT ON COLUMN file_storage.uploaded_by IS 'User who uploaded the file';
COMMENT ON COLUMN file_storage.related_paper_id IS 'Related paper (if applicable)';
COMMENT ON COLUMN file_storage.related_activity_id IS 'Related activity ID (polymorphic - pr_activities or jc_activities)';
COMMENT ON COLUMN file_storage.related_activity_uuid IS 'Related activity UUID for cross-type lookups';
COMMENT ON COLUMN file_storage.file_category IS 'Category: paper, review, visual_abstract, supplementary, etc.';
COMMENT ON COLUMN file_storage.is_public IS 'Whether the file is publicly accessible';
COMMENT ON COLUMN file_storage.created_at IS 'When the file was uploaded';
COMMENT ON COLUMN file_storage.updated_at IS 'When the file metadata was last updated';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_file_storage_uploaded_by ON file_storage (uploaded_by);
CREATE INDEX IF NOT EXISTS idx_file_storage_paper_id ON file_storage (related_paper_id) WHERE related_paper_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_file_storage_activity_id ON file_storage (related_activity_id) WHERE related_activity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_file_storage_activity_uuid ON file_storage (related_activity_uuid) WHERE related_activity_uuid IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_file_storage_category ON file_storage (file_category);
CREATE INDEX IF NOT EXISTS idx_file_storage_created_at ON file_storage (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_file_storage_file_path ON file_storage (file_path);
CREATE INDEX IF NOT EXISTS idx_file_storage_public ON file_storage (is_public) WHERE is_public = true;

-- =============================================
-- Triggers
-- =============================================
CREATE TRIGGER update_file_storage_updated_at
  BEFORE UPDATE ON file_storage
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- =============================================
-- Row Level Security Policies
-- =============================================

ALTER TABLE file_storage ENABLE ROW LEVEL SECURITY;

-- Users can read files they uploaded, public files, or files in activities they participate in
-- Note: Activity participant access will be extended in PR/JC migrations after permissions tables exist
CREATE POLICY file_storage_select_own_or_public_or_service ON file_storage
  FOR SELECT
  USING (
    uploaded_by = (SELECT auth_user_id()) OR
    is_public = true OR
    (SELECT auth.role()) = 'service_role'
  );

-- Users can upload files
CREATE POLICY file_storage_insert_own_or_service ON file_storage
  FOR INSERT
  WITH CHECK (
    uploaded_by = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Users can update their own files
CREATE POLICY file_storage_update_own_or_service ON file_storage
  FOR UPDATE
  USING (
    uploaded_by = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  )
  WITH CHECK (
    uploaded_by = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can delete files (managed by cleanup workflows)
CREATE POLICY file_storage_delete_service_role_only ON file_storage
  FOR DELETE
  USING ((SELECT auth.role()) = 'service_role');

COMMENT ON POLICY file_storage_select_own_or_public_or_service ON file_storage IS
  'Users see files they uploaded or public files (activity access extended in PR/JC migrations)';

