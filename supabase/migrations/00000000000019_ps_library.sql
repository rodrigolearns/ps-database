-- Migration: PaperStack Library
-- Create tables for the PaperStack Library functionality
-- This allows completed peer-reviewed activities to be submitted to the platform's own journal

-- Create ps_library_papers table to store papers in the PaperStack Library
CREATE TABLE ps_library_papers (
    id SERIAL PRIMARY KEY,
    activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
    title VARCHAR(500) NOT NULL,
    abstract TEXT,
    keywords TEXT[], -- Array of keywords
    authors JSONB NOT NULL, -- JSON array of author objects with name, affiliation, etc.
    published_date TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    
    -- Peer review transparency fields
    review_process_summary TEXT,
    total_reviewers INTEGER,
    review_duration_days INTEGER,
    
    -- Access and visibility
    is_public BOOLEAN DEFAULT true,
    view_count INTEGER DEFAULT 0,
    download_count INTEGER DEFAULT 0,
    
    -- Categorization
    subject_area VARCHAR(200),
    research_type VARCHAR(100), -- e.g., "Empirical Study", "Review", "Meta-Analysis"
    
    -- Metadata
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    
    -- Ensure one paper per activity
    UNIQUE(activity_id)
);

-- Create ps_library_reviews table to store anonymized review data
CREATE TABLE ps_library_reviews (
    id SERIAL PRIMARY KEY,
    paper_id INTEGER NOT NULL REFERENCES ps_library_papers(id) ON DELETE CASCADE,
    reviewer_pseudonym VARCHAR(100) NOT NULL, -- e.g., "Reviewer A", "Reviewer B"
    review_round INTEGER NOT NULL DEFAULT 1,
    
    -- Review content (anonymized)
    significance_score INTEGER, -- 1-5 scale
    methodology_score INTEGER, -- 1-5 scale
    clarity_score INTEGER, -- 1-5 scale
    overall_score INTEGER, -- 1-5 scale
    
    review_text TEXT, -- Anonymized review text
    recommendation VARCHAR(50), -- e.g., "Accept", "Minor Revision", "Major Revision", "Reject"
    
    -- Timing
    submitted_at TIMESTAMP WITH TIME ZONE,
    review_duration_hours INTEGER,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create ps_library_author_responses table to store author responses
CREATE TABLE ps_library_author_responses (
    id SERIAL PRIMARY KEY,
    paper_id INTEGER NOT NULL REFERENCES ps_library_papers(id) ON DELETE CASCADE,
    review_round INTEGER NOT NULL DEFAULT 1,
    
    response_text TEXT NOT NULL,
    changes_made TEXT, -- Summary of changes made to the paper
    
    submitted_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create ps_library_files table to store associated files
CREATE TABLE ps_library_files (
    id SERIAL PRIMARY KEY,
    paper_id INTEGER NOT NULL REFERENCES ps_library_papers(id) ON DELETE CASCADE,
    file_type VARCHAR(50) NOT NULL, -- e.g., "manuscript", "supplementary", "data", "code"
    file_name VARCHAR(255) NOT NULL,
    file_path VARCHAR(500) NOT NULL,
    file_size_bytes BIGINT,
    mime_type VARCHAR(100),
    download_count INTEGER DEFAULT 0,
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create ps_library_citations table to track citations
CREATE TABLE ps_library_citations (
    id SERIAL PRIMARY KEY,
    paper_id INTEGER NOT NULL REFERENCES ps_library_papers(id) ON DELETE CASCADE,
    citing_paper_id INTEGER REFERENCES ps_library_papers(id) ON DELETE CASCADE,
    citation_text TEXT,
    citation_context TEXT, -- Where/how the paper was cited
    
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create ps_library_metrics table to track paper metrics
CREATE TABLE ps_library_metrics (
    id SERIAL PRIMARY KEY,
    paper_id INTEGER NOT NULL REFERENCES ps_library_papers(id) ON DELETE CASCADE UNIQUE,
    
    -- View and download metrics
    total_views INTEGER DEFAULT 0,
    total_downloads INTEGER DEFAULT 0,
    unique_views INTEGER DEFAULT 0,
    unique_downloads INTEGER DEFAULT 0,
    
    -- Engagement metrics
    citation_count INTEGER DEFAULT 0,
    altmetric_score INTEGER DEFAULT 0,
    
    -- Time-based metrics
    last_viewed_at TIMESTAMP WITH TIME ZONE,
    last_downloaded_at TIMESTAMP WITH TIME ZONE,
    
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes for better performance
CREATE INDEX idx_ps_library_papers_published_date ON ps_library_papers(published_date DESC);
CREATE INDEX idx_ps_library_papers_subject_area ON ps_library_papers(subject_area);
CREATE INDEX idx_ps_library_papers_keywords ON ps_library_papers USING GIN(keywords);
CREATE INDEX idx_ps_library_papers_authors ON ps_library_papers USING GIN(authors);
CREATE INDEX idx_ps_library_papers_public ON ps_library_papers(is_public) WHERE is_public = true;

CREATE INDEX idx_ps_library_reviews_paper_id ON ps_library_reviews(paper_id);
CREATE INDEX idx_ps_library_reviews_round ON ps_library_reviews(review_round);

CREATE INDEX idx_ps_library_files_paper_id ON ps_library_files(paper_id);
CREATE INDEX idx_ps_library_files_type ON ps_library_files(file_type);

CREATE INDEX idx_ps_library_citations_paper_id ON ps_library_citations(paper_id);
CREATE INDEX idx_ps_library_citations_citing_paper_id ON ps_library_citations(citing_paper_id);

-- Create triggers for updating timestamps
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

CREATE TRIGGER update_ps_library_papers_updated_at 
    BEFORE UPDATE ON ps_library_papers 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_ps_library_metrics_updated_at 
    BEFORE UPDATE ON ps_library_metrics 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Create function to increment view count
CREATE OR REPLACE FUNCTION increment_paper_view_count(paper_id_param INTEGER)
RETURNS VOID AS $$
BEGIN
    -- Update paper view count
    UPDATE ps_library_papers 
    SET view_count = view_count + 1 
    WHERE id = paper_id_param;
    
    -- Update metrics
    INSERT INTO ps_library_metrics (paper_id, total_views, unique_views, last_viewed_at)
    VALUES (paper_id_param, 1, 1, CURRENT_TIMESTAMP)
    ON CONFLICT (paper_id) DO UPDATE SET
        total_views = ps_library_metrics.total_views + 1,
        last_viewed_at = CURRENT_TIMESTAMP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

-- Create function to increment download count
CREATE OR REPLACE FUNCTION increment_paper_download_count(paper_id_param INTEGER)
RETURNS VOID AS $$
BEGIN
    -- Update paper download count
    UPDATE ps_library_papers 
    SET download_count = download_count + 1 
    WHERE id = paper_id_param;
    
    -- Update metrics
    INSERT INTO ps_library_metrics (paper_id, total_downloads, unique_downloads, last_downloaded_at)
    VALUES (paper_id_param, 1, 1, CURRENT_TIMESTAMP)
    ON CONFLICT (paper_id) DO UPDATE SET
        total_downloads = ps_library_metrics.total_downloads + 1,
        last_downloaded_at = CURRENT_TIMESTAMP;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

-- Create function to submit activity to PaperStack Library
CREATE OR REPLACE FUNCTION submit_activity_to_library(
    activity_id_param INTEGER,
    title_param VARCHAR(500),
    abstract_param TEXT,
    keywords_param TEXT[],
    authors_param JSONB,
    subject_area_param VARCHAR(200),
    research_type_param VARCHAR(100)
)
RETURNS INTEGER AS $$
DECLARE
    paper_id INTEGER;
    review_count INTEGER;
    review_duration INTEGER;
BEGIN
    -- Get review statistics
    SELECT COUNT(DISTINCT reviewer_id), 
           EXTRACT(EPOCH FROM (MAX(submitted_at) - MIN(created_at))) / 86400
    INTO review_count, review_duration
    FROM pr_review_submissions 
    WHERE activity_id = activity_id_param;
    
    -- Insert into ps_library_papers
    INSERT INTO ps_library_papers (
        activity_id, title, abstract, keywords, authors,
        total_reviewers, review_duration_days, subject_area, research_type,
        review_process_summary
    ) VALUES (
        activity_id_param, title_param, abstract_param, keywords_param, authors_param,
        review_count, review_duration, subject_area_param, research_type_param,
        'This paper underwent peer review on the PaperStack platform with ' || review_count || ' reviewers over ' || review_duration || ' days.'
    ) RETURNING id INTO paper_id;
    
    -- Copy anonymized reviews
    INSERT INTO ps_library_reviews (
        paper_id, reviewer_pseudonym, review_round,
        review_text, submitted_at, review_duration_hours
    )
    SELECT 
        paper_id,
        'Reviewer ' || ROW_NUMBER() OVER (ORDER BY created_at),
        round_number,
        review_content,
        submitted_at,
        EXTRACT(EPOCH FROM (submitted_at - created_at)) / 3600
    FROM pr_review_submissions
    WHERE activity_id = activity_id_param;
    
    -- Copy author responses if any
    INSERT INTO ps_library_author_responses (
        paper_id, review_round, response_text, submitted_at
    )
    SELECT 
        paper_id,
        round_number,
        response_content,
        submitted_at
    FROM pr_author_responses
    WHERE activity_id = activity_id_param;
    
    -- Initialize metrics
    INSERT INTO ps_library_metrics (paper_id)
    VALUES (paper_id);
    
    RETURN paper_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

-- Create view for public library papers with metrics
CREATE VIEW ps_library_public_papers AS
SELECT 
    p.id,
    p.activity_id,
    p.title,
    p.abstract,
    p.keywords,
    p.authors,
    p.published_date,
    p.review_process_summary,
    p.total_reviewers,
    p.review_duration_days,
    p.subject_area,
    p.research_type,
    p.view_count,
    p.download_count,
    COALESCE(m.citation_count, 0) as citation_count,
    COALESCE(m.altmetric_score, 0) as altmetric_score,
    COUNT(r.id) as review_count
FROM ps_library_papers p
LEFT JOIN ps_library_metrics m ON p.id = m.paper_id
LEFT JOIN ps_library_reviews r ON p.id = r.paper_id
WHERE p.is_public = true
GROUP BY p.id, m.citation_count, m.altmetric_score
ORDER BY p.published_date DESC;

-- Create journal_submissions table to track journal submissions
CREATE TABLE journal_submissions (
    id SERIAL PRIMARY KEY,
    activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
    journal_id VARCHAR(50) NOT NULL,
    journal_name VARCHAR(200) NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'submitted',
    submitted_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    external_url VARCHAR(500),
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    
    -- Ensure one submission per journal per activity
    UNIQUE(activity_id, journal_id)
);

-- Create index for journal submissions
CREATE INDEX idx_journal_submissions_activity_id ON journal_submissions(activity_id);
CREATE INDEX idx_journal_submissions_journal_id ON journal_submissions(journal_id);
CREATE INDEX idx_journal_submissions_status ON journal_submissions(status);

-- Add trigger for journal submissions
CREATE TRIGGER update_journal_submissions_updated_at 
    BEFORE UPDATE ON journal_submissions 
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Add comment to the migration
COMMENT ON TABLE ps_library_papers IS 'Stores papers published in the PaperStack Library with full peer review transparency';
COMMENT ON TABLE ps_library_reviews IS 'Stores anonymized peer review data for library papers';
COMMENT ON TABLE ps_library_author_responses IS 'Stores author responses to peer reviews for library papers';
COMMENT ON TABLE ps_library_files IS 'Stores files associated with library papers';
COMMENT ON TABLE ps_library_citations IS 'Tracks citations between library papers';
COMMENT ON TABLE ps_library_metrics IS 'Tracks engagement and impact metrics for library papers'; 
COMMENT ON TABLE journal_submissions IS 'Tracks journal submissions for peer review activities'; 