-- =============================================
-- 00000000000009_pr_evaluation.sql
-- Peer Review Domain: Final Evaluations (Simplified)
-- =============================================

-- Collaborative evaluations table
CREATE TABLE IF NOT EXISTS pr_evaluations (
  evaluation_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  evaluation_content TEXT NOT NULL, -- Final collaborative assessment text
  is_finalized BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id)
);

COMMENT ON TABLE pr_evaluations IS 'Final collaborative evaluations for peer review activities';
COMMENT ON COLUMN pr_evaluations.evaluation_id IS 'Primary key for the evaluation';
COMMENT ON COLUMN pr_evaluations.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_evaluations.evaluation_content IS 'Final collaborative assessment text';
COMMENT ON COLUMN pr_evaluations.is_finalized IS 'Whether all reviewers have agreed to this evaluation';
COMMENT ON COLUMN pr_evaluations.created_at IS 'When the evaluation was created';
COMMENT ON COLUMN pr_evaluations.updated_at IS 'When the evaluation was last updated';

-- Reviewer finalization status table
CREATE TABLE IF NOT EXISTS pr_finalization_status (
  status_id SERIAL PRIMARY KEY,
  activity_id INTEGER NOT NULL REFERENCES pr_activities(activity_id) ON DELETE CASCADE,
  reviewer_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  is_finalized BOOLEAN DEFAULT false,
  finalized_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(activity_id, reviewer_id)
);

COMMENT ON TABLE pr_finalization_status IS 'Finalization status of reviewers for evaluations';
COMMENT ON COLUMN pr_finalization_status.status_id IS 'Primary key for the status';
COMMENT ON COLUMN pr_finalization_status.activity_id IS 'Foreign key to pr_activities';
COMMENT ON COLUMN pr_finalization_status.reviewer_id IS 'Foreign key to user_accounts (reviewer)';
COMMENT ON COLUMN pr_finalization_status.is_finalized IS 'Whether the reviewer has agreed to the final evaluation';
COMMENT ON COLUMN pr_finalization_status.finalized_at IS 'When the reviewer finalized their agreement';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_evaluations_activity_id ON pr_evaluations (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_evaluations_is_finalized ON pr_evaluations (is_finalized);
CREATE INDEX IF NOT EXISTS idx_pr_evaluations_updated_at ON pr_evaluations (updated_at);

CREATE INDEX IF NOT EXISTS idx_pr_finalization_status_activity_id ON pr_finalization_status (activity_id);
CREATE INDEX IF NOT EXISTS idx_pr_finalization_status_reviewer_id ON pr_finalization_status (reviewer_id);
CREATE INDEX IF NOT EXISTS idx_pr_finalization_status_is_finalized ON pr_finalization_status (is_finalized);

-- Triggers
CREATE TRIGGER update_pr_evaluations_updated_at
  BEFORE UPDATE ON pr_evaluations
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER update_pr_finalization_status_updated_at
  BEFORE UPDATE ON pr_finalization_status
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at(); 