-- =============================================
-- 00000000000010_activity_system_core.sql
-- Activity System Core: Registries, Stage Types, and Conditions
-- =============================================
-- This migration establishes the foundation for the flexible activity system
-- Following SPRINT-7.md: Activity types as first-class citizens, templates define workflows

-- =============================================
-- 1. Activity Type Registry
-- =============================================
-- Central registry of all activity types in the system
-- Each activity type is a separate table (pr_activities, jc_activities, etc.)
CREATE TABLE IF NOT EXISTS activity_type_registry (
  type_code TEXT PRIMARY KEY,  -- 'pr-activity', 'jc-activity', 'cr-activity'
  display_name TEXT NOT NULL,
  description TEXT,
  
  -- UI configuration
  route_prefix TEXT NOT NULL,  -- '/pr-activity', '/jc-activity'
  icon_name TEXT,
  
  -- Token economics
  token_cost INTEGER NOT NULL DEFAULT 0,  -- 0 = free, >0 = cost in tokens
  
  -- Feature flags
  is_active BOOLEAN DEFAULT true,
  supports_deadlines BOOLEAN DEFAULT true,
  supports_templates BOOLEAN DEFAULT true,
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE activity_type_registry IS 'Central registry of all activity types in the system';
COMMENT ON COLUMN activity_type_registry.type_code IS 'Activity type identifier (format: {prefix}-activity, e.g., pr-activity)';
COMMENT ON COLUMN activity_type_registry.display_name IS 'Human-readable name for UI display';
COMMENT ON COLUMN activity_type_registry.route_prefix IS 'URL prefix for this activity type (matches type_code)';
COMMENT ON COLUMN activity_type_registry.token_cost IS 'Base token cost to create this activity type (0 = free, specific cost may vary by template)';
COMMENT ON COLUMN activity_type_registry.supports_deadlines IS 'Whether this activity type uses deadline system';
COMMENT ON COLUMN activity_type_registry.supports_templates IS 'Whether this activity type uses template/workflow system';

-- Seed activity types
INSERT INTO activity_type_registry (type_code, display_name, description, route_prefix, token_cost, supports_deadlines, supports_templates)
VALUES 
  ('pr-activity', 'Peer Review Activity', 'Token-based peer review with automatic progression and deadlines', '/pr-activity', 10, true, true),
  ('jc-activity', 'Journal Club', 'Free collaborative review with manual progression (invitation-only)', '/jc-activity', 0, false, true);

-- =============================================
-- 2. Stage Type Registry
-- =============================================
-- Defines all possible stage types across all activity types
-- Each stage type maps to a specific React component
-- Following DEVELOPMENT_PRINCIPLES.md: Explicit stage types, no parameterization
CREATE TABLE IF NOT EXISTS stage_types (
  stage_type_code TEXT PRIMARY KEY,  -- 'review_round_1', 'review_round_2', 'jc_review'
  activity_type TEXT NOT NULL REFERENCES activity_type_registry(type_code) ON DELETE CASCADE,
  display_name TEXT NOT NULL,
  description TEXT,
  
  -- UI rendering
  ui_component_name TEXT NOT NULL,  -- React component: 'ReviewSubmissionFormRound1'
  
  -- Data storage
  data_tables TEXT[],  -- Tables this stage uses: ['pr_review_submissions', 'pr_reviewers']
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE stage_types IS 'Registry of all possible stage types across activity types';
COMMENT ON COLUMN stage_types.stage_type_code IS 'Unique identifier (explicit per round: review_round_1, review_round_2)';
COMMENT ON COLUMN stage_types.activity_type IS 'Which activity type this stage belongs to';
COMMENT ON COLUMN stage_types.ui_component_name IS 'React component name (one component per stage type)';
COMMENT ON COLUMN stage_types.data_tables IS 'Database tables this stage interacts with';

-- Seed PR activity stage types
-- NOTE: Each round is a separate stage type (DB is source of truth, copy-paste over complexity)
-- NOTE: No default_config - all configuration lives in template_stage_graph or application layer
INSERT INTO stage_types (stage_type_code, activity_type, display_name, description, ui_component_name, data_tables)
VALUES 
  -- Posted stage (seeking reviewers on feed)
  ('posted', 'pr-activity', 'Posted on Feed', 'Activity posted on feed, seeking reviewers to join', 
   'PostedOnFeedView', 
   ARRAY['pr_reviewers']),
   
  -- Review rounds (separate type per round)
  ('review_round_1', 'pr-activity', 'Review Round 1', 'Initial review: reviewers submit independent evaluations', 
   'ReviewSubmissionFormRound1', 
   ARRAY['pr_review_submissions', 'pr_reviewers']),
   
  ('review_round_2', 'pr-activity', 'Review Round 2', 'Second review: reviewers evaluate author revisions',
   'ReviewSubmissionFormRound2',
   ARRAY['pr_review_submissions', 'pr_reviewers']),
   
  ('review_round_3', 'pr-activity', 'Review Round 3', 'Third review: final evaluation round',
   'ReviewSubmissionFormRound3',
   ARRAY['pr_review_submissions', 'pr_reviewers']),
   
  -- Author responses (separate type per round)
  ('author_response_round_1', 'pr-activity', 'Author Response Round 1', 'Author responds to initial reviewer feedback',
   'AuthorResponseFormRound1',
   ARRAY['pr_author_responses']),
   
  ('author_response_round_2', 'pr-activity', 'Author Response Round 2', 'Author responds to second round feedback',
   'AuthorResponseFormRound2',
   ARRAY['pr_author_responses']),
   
  -- Collaborative assessment (single instance)
  ('collaborative_assessment', 'pr-activity', 'Collaborative Assessment', 'Reviewers write consensus assessment together (Etherpad)',
   'CollaborativeAssessmentForm',
   ARRAY['pr_assessments', 'pr_finalization_status']),
   
  -- Award distribution (single instance)
  ('award_distribution', 'pr-activity', 'Award Distribution', 'All participants distribute recognition awards',
   'AwardDistributionForm',
   ARRAY['pr_award_distributions', 'pr_award_distribution_status']),
   
  -- Publication choice (single instance)
  ('publication_choice', 'pr-activity', 'Publication Choice', 'Author chooses publication path',
   'PublicationChoiceForm',
   ARRAY['pr_publication_choices']);

-- Seed JC activity stage types
-- JC activities use templates like PR but with manual progression
INSERT INTO stage_types (stage_type_code, activity_type, display_name, description, ui_component_name, data_tables)
VALUES 
  ('jc_created', 'jc-activity', 'Journal Club Created', 'Creator sends invitations, participants join',
   'JCCreatedView',
   ARRAY['jc_invitations', 'jc_participants']),
   
  ('jc_review', 'jc-activity', 'Journal Club Review', 'Participants submit reviews (manual progression)',
   'JCReviewSubmissionForm',
   ARRAY['jc_review_submissions', 'jc_participants']),
   
  ('jc_assessment', 'jc-activity', 'Journal Club Assessment', 'Collaborative discussion and consensus (manual progression)',
   'JCCollaborativeAssessmentForm',
   ARRAY['jc_assessments', 'jc_finalization_status']),
   
  ('jc_awarding', 'jc-activity', 'Journal Club Awarding', 'Recognition awards (no tokens, manual progression)',
   'JCAwardDistributionForm',
   ARRAY['jc_award_distributions']);

-- =============================================
-- 3. Progression Conditions Registry
-- =============================================
-- Registry of condition evaluators for stage progression
-- Each condition is a PostgreSQL function that returns true/false
CREATE TABLE IF NOT EXISTS progression_conditions (
  condition_code TEXT PRIMARY KEY,
  activity_type TEXT NOT NULL,  -- 'pr-activity', 'jc-activity', or '*' for universal
  display_name TEXT NOT NULL,
  description TEXT,
  
  -- Evaluator function
  evaluator_function TEXT NOT NULL,  -- PostgreSQL function name
  
  -- Configuration schema (JSON Schema for validation)
  config_schema JSONB,
  
  -- Metadata
  is_reusable BOOLEAN DEFAULT true,
  is_system_condition BOOLEAN DEFAULT true,
  
  created_at TIMESTAMPTZ DEFAULT NOW()
);

COMMENT ON TABLE progression_conditions IS 'Registry of condition evaluators for stage progression';
COMMENT ON COLUMN progression_conditions.condition_code IS 'Unique identifier for this condition';
COMMENT ON COLUMN progression_conditions.activity_type IS 'Activity type or * for universal';
COMMENT ON COLUMN progression_conditions.evaluator_function IS 'PostgreSQL function name to call for evaluation';
COMMENT ON COLUMN progression_conditions.config_schema IS 'JSON Schema defining expected configuration parameters';

-- Seed PR activity conditions
INSERT INTO progression_conditions (condition_code, activity_type, display_name, description, evaluator_function, config_schema)
VALUES 
  ('first_review_submitted', 'pr-activity', 'First Review Submitted', 
   'At least one reviewer has submitted a review (triggers posted → review_1)',
   'eval_first_review_submitted',
   '{"type": "object", "properties": {"round_number": {"type": "integer", "minimum": 1}}}'::jsonb),
   
  ('min_reviewers_locked_in', 'pr-activity', 'Minimum Reviewers Locked In', 
   'At least N reviewers have submitted initial evaluations and locked in',
   'eval_min_reviewers_locked_in',
   '{"type": "object", "required": ["min_count"], "properties": {"min_count": {"type": "integer", "minimum": 1}}}'::jsonb),
   
  ('all_reviews_submitted', 'pr-activity', 'All Reviews Submitted', 
   'All locked-in reviewers have submitted reviews for a specific round',
   'eval_all_reviews_submitted',
   '{"type": "object", "required": ["round_number"], "properties": {"round_number": {"type": "integer", "minimum": 1}}}'::jsonb),
   
  ('author_response_submitted', 'pr-activity', 'Author Response Submitted',
   'Author has submitted a response for a specific round',
   'eval_author_response_submitted',
   '{"type": "object", "required": ["round_number"], "properties": {"round_number": {"type": "integer", "minimum": 1}}}'::jsonb),
   
  ('all_finalized', 'pr-activity', 'All Participants Finalized',
   'All required participants have marked their content as finalized',
   'eval_all_finalized',
   '{}'::jsonb),
   
  ('all_awards_distributed', 'pr-activity', 'All Awards Distributed',
   'All participants have submitted their award distributions',
   'eval_all_awards_distributed',
   '{}'::jsonb),
   
  ('deadline_reached', 'pr-activity', 'Deadline Reached',
   'Stage deadline has been reached or exceeded',
   'eval_deadline_reached',
   '{}'::jsonb);

-- Seed universal conditions (work across all activity types)
INSERT INTO progression_conditions (condition_code, activity_type, display_name, description, evaluator_function, config_schema)
VALUES 
  ('manual', '*', 'Manual Progression', 
   'Requires explicit user action (always returns true when triggered)',
   'eval_manual',
   '{}'::jsonb);

-- =============================================
-- 4. Template Stage Graph Table
-- =============================================
-- Defines workflow graphs for templates (nodes in the graph)
-- Each row is a stage within a template's workflow
CREATE TABLE IF NOT EXISTS template_stage_graph (
  graph_id SERIAL PRIMARY KEY,
  template_id INTEGER NOT NULL,  -- References pr_templates, jc_templates, etc.
  activity_type TEXT NOT NULL REFERENCES activity_type_registry(type_code) ON DELETE CASCADE,
  
  -- Stage identification
  stage_key TEXT NOT NULL,  -- Unique within template: 'review_1', 'assessment', 'awarding'
  stage_type TEXT NOT NULL REFERENCES stage_types(stage_type_code) ON DELETE RESTRICT,
  stage_order INTEGER NOT NULL,  -- Display order (NOT execution order - graph edges determine that)
  
  -- Deadline configuration
  deadline_days INTEGER,  -- NULL = no deadline
  
  -- Display metadata
  display_name TEXT NOT NULL,
  description TEXT,
  
  -- Stage behavior
  is_initial_stage BOOLEAN DEFAULT false,
  is_terminal_stage BOOLEAN DEFAULT false,
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(template_id, activity_type, stage_key)
);

COMMENT ON TABLE template_stage_graph IS 'Workflow graph definition for templates (nodes in the DAG)';
COMMENT ON COLUMN template_stage_graph.template_id IS 'Template ID (references activity-type-specific template table)';
COMMENT ON COLUMN template_stage_graph.activity_type IS 'Which activity type this workflow belongs to';
COMMENT ON COLUMN template_stage_graph.stage_key IS 'Unique identifier for this stage within the template';
COMMENT ON COLUMN template_stage_graph.stage_type IS 'Stage type (determines behavior and UI component)';
COMMENT ON COLUMN template_stage_graph.stage_order IS 'Display order in UI (NOT execution order)';
COMMENT ON COLUMN template_stage_graph.deadline_days IS 'Days until deadline (NULL = no deadline, warning logic in app layer)';
COMMENT ON COLUMN template_stage_graph.is_initial_stage IS 'Is this the starting stage for new activities?';
COMMENT ON COLUMN template_stage_graph.is_terminal_stage IS 'Is this an ending stage (no outgoing transitions)?';

-- =============================================
-- 5. Template Stage Transitions Table
-- =============================================
-- Defines valid transitions between stages (edges in the graph)
-- Supports AND/OR/NOT condition logic
CREATE TABLE IF NOT EXISTS template_stage_transitions (
  transition_id SERIAL PRIMARY KEY,
  template_id INTEGER NOT NULL,
  activity_type TEXT NOT NULL REFERENCES activity_type_registry(type_code) ON DELETE CASCADE,
  
  -- Transition edge
  from_stage_key TEXT NOT NULL,
  to_stage_key TEXT NOT NULL,
  
  -- Progression condition (supports AND/OR/NOT logic)
  condition_expression JSONB NOT NULL,  -- Expression tree: {"type": "...", "config": {...}} or {"op": "AND", "conditions": [...]}
  
  -- Transition behavior
  is_automatic BOOLEAN DEFAULT true,  -- false = requires manual trigger
  requires_confirmation BOOLEAN DEFAULT false,
  transition_order INTEGER DEFAULT 0,  -- Evaluation order (currently always 1 for linear workflows; FUTURE: for admin branching)
  
  created_at TIMESTAMPTZ DEFAULT NOW(),
  
  -- Foreign key constraints
  FOREIGN KEY (template_id, activity_type, from_stage_key) 
    REFERENCES template_stage_graph(template_id, activity_type, stage_key) ON DELETE CASCADE,
  FOREIGN KEY (template_id, activity_type, to_stage_key) 
    REFERENCES template_stage_graph(template_id, activity_type, stage_key) ON DELETE CASCADE
);

COMMENT ON TABLE template_stage_transitions IS 'Stage transition rules (edges in the workflow DAG - no cycles allowed)';
COMMENT ON COLUMN template_stage_transitions.from_stage_key IS 'Source stage';
COMMENT ON COLUMN template_stage_transitions.to_stage_key IS 'Target stage';
COMMENT ON COLUMN template_stage_transitions.condition_expression IS 'Condition expression tree with AND/OR/NOT support';
COMMENT ON COLUMN template_stage_transitions.is_automatic IS 'Automatic (true) or manual (false) progression';
COMMENT ON COLUMN template_stage_transitions.transition_order IS 'Evaluation order (currently always 1 for linear workflows; FUTURE: for admin overrides like paused/cancelled/flagged states)';

-- =============================================
-- Indexes
-- =============================================

-- Activity type registry indexes
CREATE INDEX IF NOT EXISTS idx_activity_type_registry_active ON activity_type_registry (is_active) WHERE is_active = true;

-- Stage type registry indexes
CREATE INDEX IF NOT EXISTS idx_stage_types_activity_type ON stage_types (activity_type);
CREATE INDEX IF NOT EXISTS idx_stage_types_component ON stage_types (ui_component_name);

-- Template stage graph indexes
CREATE INDEX IF NOT EXISTS idx_template_stage_graph_template ON template_stage_graph (template_id, activity_type);
CREATE INDEX IF NOT EXISTS idx_template_stage_graph_stage_type ON template_stage_graph (stage_type);
CREATE INDEX IF NOT EXISTS idx_template_stage_graph_initial ON template_stage_graph (template_id, activity_type, is_initial_stage) WHERE is_initial_stage = true;

-- Template stage transitions indexes
CREATE INDEX IF NOT EXISTS idx_template_stage_transitions_template ON template_stage_transitions (template_id, activity_type);
CREATE INDEX IF NOT EXISTS idx_template_stage_transitions_from ON template_stage_transitions (template_id, activity_type, from_stage_key);
CREATE INDEX IF NOT EXISTS idx_template_stage_transitions_automatic ON template_stage_transitions (template_id, activity_type, from_stage_key, is_automatic) WHERE is_automatic = true;

-- =============================================
-- Row Level Security Policies
-- =============================================
-- Registry tables are read-only for authenticated users
-- Only service role can modify (system configuration)

ALTER TABLE activity_type_registry ENABLE ROW LEVEL SECURITY;
ALTER TABLE stage_types ENABLE ROW LEVEL SECURITY;
ALTER TABLE progression_conditions ENABLE ROW LEVEL SECURITY;
ALTER TABLE template_stage_graph ENABLE ROW LEVEL SECURITY;
ALTER TABLE template_stage_transitions ENABLE ROW LEVEL SECURITY;

-- Activity type registry: Read-only for authenticated users
CREATE POLICY activity_type_registry_select_authenticated ON activity_type_registry
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY activity_type_registry_modify_service_role_only ON activity_type_registry
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Stage types: Read-only for authenticated users
CREATE POLICY stage_types_select_authenticated ON stage_types
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY stage_types_modify_service_role_only ON stage_types
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Progression conditions: Read-only for authenticated users
CREATE POLICY progression_conditions_select_authenticated ON progression_conditions
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY progression_conditions_modify_service_role_only ON progression_conditions
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Template stage graph: Read-only for authenticated users
CREATE POLICY template_stage_graph_select_authenticated ON template_stage_graph
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY template_stage_graph_modify_service_role_only ON template_stage_graph
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

-- Template stage transitions: Read-only for authenticated users
CREATE POLICY template_stage_transitions_select_authenticated ON template_stage_transitions
  FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY template_stage_transitions_modify_service_role_only ON template_stage_transitions
  FOR ALL
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

