-- =============================================
-- 00000000000023_pr_create.sql
-- Functions for creating peer review activities
-- =============================================

-- Function to submit a paper with peer review activity
CREATE OR REPLACE FUNCTION submit_paper_with_pr_activity(
  p_title TEXT,
  p_abstract TEXT,
  p_license TEXT,
  p_preprint_doi TEXT,
  p_preprint_source TEXT,
  p_preprint_date DATE,
  p_uploaded_by INTEGER,
  p_template_id INTEGER,
  p_storage_reference TEXT,
  p_visual_abstract_storage_reference TEXT,
  p_visual_abstract_caption JSONB,
  p_cited_sources JSONB,
  p_supplementary_materials JSONB,
  p_funding_info JSONB,
  p_data_availability_statement TEXT,
  p_data_availability_url JSONB,
  p_authors JSONB
)
RETURNS JSONB AS $$
DECLARE
  v_paper_id INTEGER;
  v_activity_id INTEGER;
  v_activity_uuid UUID;
  v_wallet_balance INTEGER;
  v_template_tokens INTEGER;
BEGIN
  -- Get template token cost
  SELECT total_tokens INTO v_template_tokens
  FROM "Peer_Review_Templates"
  WHERE template_id = p_template_id;
  
  IF v_template_tokens IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Invalid template ID: ' || p_template_id
    );
  END IF;
  
  -- Check wallet balance
  SELECT balance INTO v_wallet_balance
  FROM "User_Wallet_Balances"
  WHERE user_id = p_uploaded_by;
  
  IF v_wallet_balance IS NULL OR v_wallet_balance < v_template_tokens THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient tokens. You need at least ' || v_template_tokens || ' tokens to submit a paper with this template.'
    );
  END IF;
  
  -- Begin transaction
  BEGIN
    -- 1. Insert paper record, now including authors
    -- This populates `Papers.authors`, the source of truth for authorship.
    INSERT INTO "Papers" (
      title, abstract, license, preprint_doi, preprint_source, preprint_date,
      uploaded_by, storage_reference, visual_abstract_storage_reference,
      visual_abstract_caption, cited_sources, supplementary_materials,
      funding_info, data_availability_statement, data_availability_url,
      authors -- Include authors column
    ) VALUES (
      p_title, p_abstract, p_license, p_preprint_doi, p_preprint_source, p_preprint_date,
      p_uploaded_by, p_storage_reference, p_visual_abstract_storage_reference,
      p_visual_abstract_caption, p_cited_sources, p_supplementary_materials,
      p_funding_info, p_data_availability_statement, p_data_availability_url,
      p_authors -- Use the authors parameter
    ) RETURNING paper_id INTO v_paper_id;
    
    -- 2. Create peer review activity
    INSERT INTO "Peer_Review_Activities" (
      paper_id, creator_id, template_id, funding_amount, escrow_balance,
      current_state, stage_deadline, posted_at
    ) VALUES (
      v_paper_id, p_uploaded_by, p_template_id, v_template_tokens, v_template_tokens,
      'submitted', NOW() + INTERVAL '14 days', NOW()
    ) RETURNING activity_id, activity_uuid INTO v_activity_id, v_activity_uuid;
    
    -- 3. Update paper with activity information (activity_id is deprecated, use activity_uuids)
    UPDATE "Papers"
    SET activity_uuids = array_append(activity_uuids, v_activity_uuid)
    WHERE paper_id = v_paper_id;
    
    -- 4. Create wallet transaction (token deduction)
    PERFORM activity_deduct_tokens(
      p_uploaded_by,
      v_template_tokens,
      'Paper submission fee for PR activity #' || v_activity_id,
      v_activity_id,
      v_activity_uuid
    );
    
    -- Return success response
    RETURN jsonb_build_object(
      'success', true,
      'message', 'Paper submitted successfully and peer review activity created',
      'paperId', v_paper_id,
      'activityId', v_activity_id,
      'activityUuid', v_activity_uuid,
      'tokenCost', v_template_tokens
    );
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RETURN jsonb_build_object(
        'success', false,
        'message', 'Error in paper submission process: ' || SQLERRM
      );
  END;
  
  COMMIT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to create additional PR activity for an existing paper
CREATE OR REPLACE FUNCTION create_additional_pr_activity(
  p_paper_id INTEGER,
  p_creator_id INTEGER,
  p_template_id INTEGER
)
RETURNS JSONB AS $$
DECLARE
  v_activity_id INTEGER;
  v_activity_uuid UUID;
  v_wallet_balance INTEGER;
  v_template_tokens INTEGER;
  v_paper_exists BOOLEAN;
BEGIN
  -- Check if paper exists
  SELECT EXISTS(SELECT 1 FROM "Papers" WHERE paper_id = p_paper_id) INTO v_paper_exists;
  IF NOT v_paper_exists THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Paper not found with ID: ' || p_paper_id
    );
  END IF;

  -- Get template token cost
  SELECT total_tokens INTO v_template_tokens
  FROM "Peer_Review_Templates"
  WHERE template_id = p_template_id;
  
  IF v_template_tokens IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Invalid template ID: ' || p_template_id
    );
  END IF;
  
  -- Check wallet balance
  SELECT balance INTO v_wallet_balance
  FROM "User_Wallet_Balances"
  WHERE user_id = p_creator_id;
  
  IF v_wallet_balance IS NULL OR v_wallet_balance < v_template_tokens THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient tokens. You need at least ' || v_template_tokens || ' tokens to create this activity.'
    );
  END IF;
  
  -- Begin transaction
  BEGIN
    -- 1. Create peer review activity
    INSERT INTO "Peer_Review_Activities" (
      paper_id, creator_id, template_id, funding_amount, escrow_balance,
      current_state, stage_deadline, posted_at
    ) VALUES (
      p_paper_id, p_creator_id, p_template_id, v_template_tokens, v_template_tokens,
      'submitted', NOW() + INTERVAL '14 days', NOW()
    ) RETURNING activity_id, activity_uuid INTO v_activity_id, v_activity_uuid;
    
    -- 2. Update paper's activity UUIDs array
    UPDATE "Papers"
    SET activity_uuids = array_append(activity_uuids, v_activity_uuid)
    WHERE paper_id = p_paper_id;
    
    -- 3. Create wallet transaction (token deduction)
    PERFORM activity_deduct_tokens(
      p_creator_id,
      v_template_tokens,
      'Additional PR activity fee for paper #' || p_paper_id,
      v_activity_id,
      v_activity_uuid
    );
    
    -- Return success response
    RETURN jsonb_build_object(
      'success', true,
      'message', 'New peer review activity created for existing paper',
      'paperId', p_paper_id,
      'activityId', v_activity_id,
      'activityUuid', v_activity_uuid,
      'tokenCost', v_template_tokens
    );
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RETURN jsonb_build_object(
        'success', false,
        'message', 'Error creating additional PR activity: ' || SQLERRM
      );
  END;
  
  COMMIT;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER; 