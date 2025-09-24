-- =============================================
-- 00000000000018_pr_deadlines.sql
-- Template-Driven Deadline System
-- =============================================

-- Deadline configuration table
CREATE TABLE IF NOT EXISTS pr_deadlines (
  deadline_id SERIAL PRIMARY KEY,
  template_id INTEGER NOT NULL REFERENCES pr_templates(template_id) ON DELETE CASCADE,
  state_name public.activity_state NOT NULL,
  deadline_days INTEGER NOT NULL,
  warning_days INTEGER DEFAULT 3,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(template_id, state_name)
);

COMMENT ON TABLE pr_deadlines IS 'Template-specific deadline configuration for PR activity states';
COMMENT ON COLUMN pr_deadlines.deadline_id IS 'Primary key for the deadline configuration';
COMMENT ON COLUMN pr_deadlines.template_id IS 'Foreign key to pr_templates';
COMMENT ON COLUMN pr_deadlines.state_name IS 'Activity state this deadline applies to';
COMMENT ON COLUMN pr_deadlines.deadline_days IS 'Number of days from state entry to deadline';
COMMENT ON COLUMN pr_deadlines.warning_days IS 'Days before deadline to send warning notification';
COMMENT ON COLUMN pr_deadlines.created_at IS 'When the deadline config was created';
COMMENT ON COLUMN pr_deadlines.updated_at IS 'When the deadline config was last updated';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_pr_deadlines_template_id ON pr_deadlines (template_id);
CREATE INDEX IF NOT EXISTS idx_pr_deadlines_state_name ON pr_deadlines (state_name);

-- Trigger for updated_at
CREATE TRIGGER update_pr_deadlines_updated_at
  BEFORE UPDATE ON pr_deadlines
  FOR EACH ROW
  EXECUTE FUNCTION set_updated_at();

-- Seed deadline data for existing templates
INSERT INTO pr_deadlines (template_id, state_name, deadline_days, warning_days)
SELECT 
  t.template_id,
  d.state_name::public.activity_state,
  d.deadline_days,
  3 as warning_days
FROM pr_templates t
CROSS JOIN (
  VALUES 
    ('review_round_1', 28),
    ('review_round_2', 28),
    ('assessment', 14),
    ('awarding', 7)
) AS d(state_name, deadline_days)
ON CONFLICT (template_id, state_name) DO UPDATE
  SET deadline_days = EXCLUDED.deadline_days,
      warning_days = EXCLUDED.warning_days,
      updated_at = NOW();

-- Function to get activities approaching deadlines
CREATE OR REPLACE FUNCTION get_activities_approaching_deadline(p_warning_days INTEGER DEFAULT 3)
RETURNS TABLE (
  activity_id INTEGER,
  activity_uuid UUID,
  current_state public.activity_state,
  stage_deadline TIMESTAMPTZ,
  days_until_deadline NUMERIC,
  template_name TEXT,
  paper_title TEXT,
  creator_id INTEGER
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    pa.activity_id,
    pa.activity_uuid,
    pa.current_state,
    pa.stage_deadline,
    EXTRACT(DAY FROM (pa.stage_deadline - NOW())) as days_until_deadline,
    pt.name as template_name,
    p.title as paper_title,
    pa.creator_id
  FROM pr_activities pa
  JOIN pr_templates pt ON pa.template_id = pt.template_id
  JOIN papers p ON pa.paper_id = p.paper_id
  WHERE pa.stage_deadline IS NOT NULL
    AND pa.stage_deadline > NOW()
    AND pa.stage_deadline <= NOW() + (p_warning_days || ' days')::INTERVAL
    AND pa.current_state != 'completed'
  ORDER BY pa.stage_deadline ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

-- Function to get activities with expired deadlines
CREATE OR REPLACE FUNCTION get_activities_with_expired_deadlines()
RETURNS TABLE (
  activity_id INTEGER,
  activity_uuid UUID,
  current_state public.activity_state,
  stage_deadline TIMESTAMPTZ,
  days_overdue NUMERIC,
  template_name TEXT,
  paper_title TEXT,
  creator_id INTEGER
) AS $$
BEGIN
  RETURN QUERY
  SELECT 
    pa.activity_id,
    pa.activity_uuid,
    pa.current_state,
    pa.stage_deadline,
    EXTRACT(DAY FROM (NOW() - pa.stage_deadline)) as days_overdue,
    pt.name as template_name,
    p.title as paper_title,
    pa.creator_id
  FROM pr_activities pa
  JOIN pr_templates pt ON pa.template_id = pt.template_id
  JOIN papers p ON pa.paper_id = p.paper_id
  WHERE pa.stage_deadline IS NOT NULL
    AND pa.stage_deadline < NOW()
    AND pa.current_state != 'completed'
  ORDER BY pa.stage_deadline ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

-- Function to set deadline when activity state changes
CREATE OR REPLACE FUNCTION set_activity_deadline(
  p_activity_id INTEGER,
  p_state public.activity_state
) RETURNS BOOLEAN AS $$
DECLARE
  v_template_id INTEGER;
  v_deadline_days INTEGER;
  v_new_deadline TIMESTAMPTZ;
BEGIN
  -- Get template ID for this activity
  SELECT template_id INTO v_template_id
  FROM pr_activities
  WHERE activity_id = p_activity_id;
  
  IF v_template_id IS NULL THEN
    RETURN FALSE;
  END IF;
  
  -- Get deadline days for this state and template
  SELECT deadline_days INTO v_deadline_days
  FROM pr_deadlines
  WHERE template_id = v_template_id
    AND state_name = p_state;
  
  -- If no deadline configuration exists, don't set deadline
  IF v_deadline_days IS NULL THEN
    UPDATE pr_activities
    SET stage_deadline = NULL
    WHERE activity_id = p_activity_id;
    RETURN TRUE;
  END IF;
  
  -- Calculate new deadline
  v_new_deadline := NOW() + (v_deadline_days || ' days')::INTERVAL;
  
  -- Update activity deadline
  UPDATE pr_activities
  SET stage_deadline = v_new_deadline
  WHERE activity_id = p_activity_id;
  
  RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

-- Grant permissions
GRANT SELECT ON pr_deadlines TO authenticated;
GRANT EXECUTE ON FUNCTION get_activities_approaching_deadline(INTEGER) TO authenticated;
GRANT EXECUTE ON FUNCTION get_activities_with_expired_deadlines() TO authenticated;
GRANT EXECUTE ON FUNCTION set_activity_deadline(INTEGER, public.activity_state) TO authenticated;

-- RLS Policies
ALTER TABLE pr_deadlines ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Anyone can view deadline configurations"
  ON pr_deadlines FOR SELECT
  USING (true);

-- Admin-only policies for deadline management (to be implemented later)
CREATE POLICY "Admins can insert deadline configurations"
  ON pr_deadlines FOR INSERT TO authenticated
  WITH CHECK (false);  -- Disabled for now, will be enabled when admin system is ready

CREATE POLICY "Admins can update deadline configurations"
  ON pr_deadlines FOR UPDATE TO authenticated
  USING (false)  -- Disabled for now, will be enabled when admin system is ready
  WITH CHECK (false);

CREATE POLICY "Admins can delete deadline configurations"
  ON pr_deadlines FOR DELETE TO authenticated
  USING (false);  -- Disabled for now, will be enabled when admin system is ready 