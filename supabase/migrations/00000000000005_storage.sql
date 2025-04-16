-- =============================================
-- 00000000000005_storage.sql
-- Migration for File Storage for Papers and Visual Abstracts
-- =============================================

-- Create the File_Storage table for storing file references related to papers.
CREATE TABLE IF NOT EXISTS "File_Storage" (
  file_id SERIAL PRIMARY KEY,
  paper_id INTEGER NOT NULL REFERENCES "Papers"(paper_id) ON DELETE CASCADE,
  file_type TEXT NOT NULL CHECK (file_type IN ('paper', 'visual_abstract')), -- Type of file being stored
  storage_reference TEXT NOT NULL, -- URL or path to the stored file, expected to follow conventions like {type}/{user_id}/{year}/{month}/{paper_id}/{filename}
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
COMMENT ON TABLE "File_Storage" IS 'Storage for files associated with papers, including the paper file and the visual abstract image';
COMMENT ON COLUMN "File_Storage".file_id IS 'Primary key for file storage entries';
COMMENT ON COLUMN "File_Storage".paper_id IS 'Foreign key referencing the Papers table';
COMMENT ON COLUMN "File_Storage".file_type IS 'Type of file; either "paper" or "visual_abstract"';
COMMENT ON COLUMN "File_Storage".storage_reference IS 'URL or path to the stored file, expected to follow conventions like {type}/{user_id}/{year}/{month}/{paper_id}/{filename}';
COMMENT ON COLUMN "File_Storage".created_at IS 'When the file record was created';
COMMENT ON COLUMN "File_Storage".updated_at IS 'When the file record was last updated';

-- Create function to update updated_at on file storage updates
CREATE OR REPLACE FUNCTION update_file_storage_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_file_storage_updated_at_trigger ON "File_Storage";
CREATE TRIGGER update_file_storage_updated_at_trigger
BEFORE UPDATE ON "File_Storage"
FOR EACH ROW
EXECUTE FUNCTION update_file_storage_updated_at();
