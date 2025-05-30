-- =============================================
-- 00000000000005_storage.sql
-- Migration for File Storage for Papers and Visual Abstracts
-- =============================================

-- Create storage buckets for papers and visual abstracts
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES 
  ('paper-submissions', 'paper-submissions', true, 52428800, -- 50MB limit
   ARRAY['application/pdf', 'application/xml', 'text/xml', 'image/jpeg', 'image/png']::text[])
ON CONFLICT (id) DO NOTHING;

-- Create RLS policy for the paper-submissions bucket - enable public read
CREATE POLICY "Public Read Access"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'paper-submissions');

-- Create RLS policy for the paper-submissions bucket - enable authenticated uploads
CREATE POLICY "Authenticated User Upload Access"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (bucket_id = 'paper-submissions');

-- Create the file_storage table for storing file references related to papers.
CREATE TABLE IF NOT EXISTS file_storage (
  file_id SERIAL PRIMARY KEY,
  paper_id INTEGER NOT NULL REFERENCES papers(paper_id) ON DELETE CASCADE,
  file_type TEXT NOT NULL CHECK (file_type IN ('paper', 'visual_abstract')), -- Type of file being stored
  storage_reference TEXT NOT NULL, -- URL or path to the stored file, expected to follow conventions like {type}/{user_id}/{year}/{month}/{paper_id}/{filename}
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
COMMENT ON TABLE file_storage IS 'Storage for files associated with papers, including the paper file and the visual abstract image';
COMMENT ON COLUMN file_storage.file_id IS 'Primary key for file storage entries';
COMMENT ON COLUMN file_storage.paper_id IS 'Foreign key referencing the papers table';
COMMENT ON COLUMN file_storage.file_type IS 'Type of file; either "paper" or "visual_abstract"';
COMMENT ON COLUMN file_storage.storage_reference IS 'URL or path to the stored file, expected to follow conventions like {type}/{user_id}/{year}/{month}/{paper_id}/{filename}';
COMMENT ON COLUMN file_storage.created_at IS 'When the file record was created';
COMMENT ON COLUMN file_storage.updated_at IS 'When the file record was last updated';

-- Function update_file_storage_updated_at removed, using generic set_updated_at
DROP TRIGGER IF EXISTS update_file_storage_updated_at_trigger ON file_storage;
CREATE TRIGGER update_file_storage_updated_at_trigger
BEFORE UPDATE ON file_storage
FOR EACH ROW
EXECUTE FUNCTION public.set_updated_at();
