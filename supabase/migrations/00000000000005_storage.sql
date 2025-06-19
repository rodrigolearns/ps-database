-- =============================================
-- 00000000000005_storage.sql
-- Storage Domain: File Storage Management
-- =============================================

-- File storage table
CREATE TABLE IF NOT EXISTS file_storage (
  file_id SERIAL PRIMARY KEY,
  file_name TEXT NOT NULL,
  file_path TEXT NOT NULL UNIQUE,
  file_size BIGINT NOT NULL,
  mime_type TEXT NOT NULL,
  uploaded_by INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  related_paper_id INTEGER REFERENCES papers(paper_id) ON DELETE CASCADE,
  related_activity_id INTEGER,
  related_activity_uuid UUID,
  file_category TEXT NOT NULL DEFAULT 'general',
  is_public BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE file_storage IS 'File storage metadata and references';
COMMENT ON COLUMN file_storage.file_id IS 'Primary key for the file';
COMMENT ON COLUMN file_storage.file_name IS 'Original name of the file';
COMMENT ON COLUMN file_storage.file_path IS 'Path to the file in storage';
COMMENT ON COLUMN file_storage.file_size IS 'Size of the file in bytes';
COMMENT ON COLUMN file_storage.mime_type IS 'MIME type of the file';
COMMENT ON COLUMN file_storage.uploaded_by IS 'User who uploaded the file';
COMMENT ON COLUMN file_storage.related_paper_id IS 'Related papers (if applicable)';
COMMENT ON COLUMN file_storage.related_activity_id IS 'Related activity ID (if applicable)';
COMMENT ON COLUMN file_storage.related_activity_uuid IS 'Related activity UUID (if applicable)';
COMMENT ON COLUMN file_storage.file_category IS 'Category of the file (papers, review, visual_abstract, etc.)';
COMMENT ON COLUMN file_storage.is_public IS 'Whether the file is publicly accessible';
COMMENT ON COLUMN file_storage.created_at IS 'When the file was uploaded';
COMMENT ON COLUMN file_storage.updated_at IS 'When the file metadata was last updated';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_file_storage_uploaded_by ON file_storage (uploaded_by);
CREATE INDEX IF NOT EXISTS idx_file_storage_paper_id ON file_storage (related_paper_id);
CREATE INDEX IF NOT EXISTS idx_file_storage_activity_id ON file_storage (related_activity_id);
CREATE INDEX IF NOT EXISTS idx_file_storage_activity_uuid ON file_storage (related_activity_uuid);
CREATE INDEX IF NOT EXISTS idx_file_storage_category ON file_storage (file_category);
CREATE INDEX IF NOT EXISTS idx_file_storage_created_at ON file_storage (created_at);
CREATE INDEX IF NOT EXISTS idx_file_storage_file_path ON file_storage (file_path);

-- Triggers
CREATE TRIGGER update_file_storage_updated_at
  BEFORE UPDATE ON file_storage
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at(); 