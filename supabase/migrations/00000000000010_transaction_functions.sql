-- =============================================
-- 00000000000010_transaction_functions.sql
-- Functions for transaction support
-- =============================================

-- Function to begin a transaction
CREATE OR REPLACE FUNCTION begin_transaction()
RETURNS void AS $$
BEGIN
  EXECUTE 'BEGIN';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to commit a transaction
CREATE OR REPLACE FUNCTION commit_transaction()
RETURNS void AS $$
BEGIN
  EXECUTE 'COMMIT';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to rollback a transaction
CREATE OR REPLACE FUNCTION rollback_transaction()
RETURNS void AS $$
BEGIN
  EXECUTE 'ROLLBACK';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to submit a paper with atomic transaction
CREATE OR REPLACE FUNCTION submit_paper_with_activity(
  p_title TEXT,
  p_abstract TEXT,
  p_license TEXT,
  p_preprint_doi TEXT,
  p_preprint_source TEXT,
  p_preprint_date DATE,
  p_uploaded_by INTEGER,
  p_storage_reference TEXT,
  p_visual_abstract_storage_reference TEXT,
  p_visual_abstract_caption JSONB,
  p_cited_sources JSONB,
  p_supplementary_materials JSONB,
  p_funding_info JSONB,
  p_data_availability_statement TEXT,
  p_data_availability_url JSONB,
  p_token_cost INTEGER DEFAULT 10
)
RETURNS JSONB AS $$
DECLARE
  v_paper_id INTEGER;
  v_activity_id INTEGER;
  v_wallet_balance INTEGER;
BEGIN
  -- Check wallet balance
  SELECT balance INTO v_wallet_balance
  FROM "User_Wallet_Balances"
  WHERE user_id = p_uploaded_by;
  
  IF v_wallet_balance IS NULL OR v_wallet_balance < p_token_cost THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient tokens. You need at least ' || p_token_cost || ' tokens to submit a paper.'
    );
  END IF;
  
  -- Begin transaction
  BEGIN
    -- 1. Insert paper record
    INSERT INTO "Papers" (
      title, abstract, license, preprint_doi, preprint_source, preprint_date,
      uploaded_by, storage_reference, visual_abstract_storage_reference,
      visual_abstract_caption, cited_sources, supplementary_materials,
      funding_info, data_availability_statement, data_availability_url
    ) VALUES (
      p_title, p_abstract, p_license, p_preprint_doi, p_preprint_source, p_preprint_date,
      p_uploaded_by, p_storage_reference, p_visual_abstract_storage_reference,
      p_visual_abstract_caption, p_cited_sources, p_supplementary_materials,
      p_funding_info, p_data_availability_statement, p_data_availability_url
    ) RETURNING paper_id INTO v_paper_id;
    
    -- 2. Create wallet transaction (token deduction)
    INSERT INTO "Wallet_Transactions" (
      user_id, amount, transaction_type, description
    ) VALUES (
      p_uploaded_by, -p_token_cost, 'debit', 'Paper submission fee'
    );
    
    -- 3. Create peer review activity
    INSERT INTO "Peer_Review_Activities" (
      activity_type, paper_id, creator_id, funding_amount, escrow_balance,
      current_state, stage_deadline, posted_at
    ) VALUES (
      'pr_activity', v_paper_id, p_uploaded_by, p_token_cost, p_token_cost,
      'submitted', NOW() + INTERVAL '14 days', NOW()
    ) RETURNING activity_id INTO v_activity_id;
    
    -- 4. Update paper with activity information
    UPDATE "Papers"
    SET activity_id = v_activity_id,
        activity_type = 'pr_activity'
    WHERE paper_id = v_paper_id;
    
    -- Return success response
    RETURN jsonb_build_object(
      'success', true,
      'message', 'Paper submitted successfully and peer review activity created',
      'paperId', v_paper_id,
      'activityId', v_activity_id
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