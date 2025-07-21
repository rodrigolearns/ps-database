-- =============================================
-- 00000000000020_pr_create.sql -- Updated for relational authors
-- Functions for creating peer review activities
-- =============================================

-- Function to submit a paper with peer review activity
-- NOTE: Accepts authors as JSONB input for convenience from the frontend,
-- but internally finds/creates records in the relational "Authors" table
-- and links them using the "Paper_Authors" join table.
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
  v_author_json JSONB;
  v_author_id INTEGER;
  v_ps_user_id INTEGER;
  v_email TEXT;
  v_orcid TEXT;
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
    -- 1. Insert paper record (without authors column)
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

    -- 2. Process and link authors
    IF p_authors IS NOT NULL AND jsonb_typeof(p_authors) = 'array' THEN
      FOR v_author_json IN SELECT * FROM jsonb_array_elements(p_authors) LOOP
        v_author_id := NULL;
        v_ps_user_id := (v_author_json->>'userId')::INTEGER; -- Use userId from frontend AuthorInfo
        v_email := v_author_json->>'email';
        v_orcid := v_author_json->>'orcid';

        -- Try find author by ps_user_id if provided and valid
        IF v_ps_user_id IS NOT NULL THEN
          SELECT author_id INTO v_author_id FROM "Authors" WHERE ps_user_id = v_ps_user_id;
        END IF;

        -- If not found, try by email if provided and valid
        IF v_author_id IS NULL AND v_email IS NOT NULL AND v_email <> '' THEN
           SELECT author_id INTO v_author_id FROM "Authors" WHERE email = v_email;
        END IF;

        -- If not found, try by ORCID if provided and valid
        IF v_author_id IS NULL AND v_orcid IS NOT NULL AND v_orcid <> '' THEN
           SELECT author_id INTO v_author_id FROM "Authors" WHERE orcid = v_orcid;
        END IF;

        -- If still not found, insert new author
        IF v_author_id IS NULL THEN
           -- Use ON CONFLICT with a single target (e.g., ps_user_id if it's most likely to be unique)
           -- Or handle potential conflicts more gracefully if multiple unique fields might clash.
           -- For simplicity, let's prioritize ps_user_id for conflict handling.
           INSERT INTO "Authors" (full_name, email, orcid, affiliations, ps_user_id)
           VALUES (
             v_author_json->>'name', -- Assuming 'name' exists
             CASE WHEN v_email <> '' THEN v_email ELSE NULL END, -- Store NULL if empty string
             CASE WHEN v_orcid <> '' THEN v_orcid ELSE NULL END, -- Store NULL if empty string
             CASE 
                WHEN v_author_json ? 'affiliation' THEN jsonb_build_array(jsonb_build_object('name', v_author_json->>'affiliation')) 
                WHEN v_author_json ? 'affiliations' THEN (v_author_json->'affiliations')::jsonb
                ELSE '[]'::jsonb
             END, -- Standardize to affiliations JSONB array
             v_ps_user_id -- Already extracted
           )
           -- Handle conflict on ps_user_id first. If it exists, do nothing (we should have found it above).
           ON CONFLICT (ps_user_id) WHERE ps_user_id IS NOT NULL DO NOTHING
           RETURNING author_id INTO v_author_id;
           
           -- If v_author_id is still NULL (e.g., conflict occurred), try to find it again.
           -- This handles cases where another transaction might have inserted the author
           -- between our initial checks and the insert attempt.
           IF v_author_id IS NULL THEN
              IF v_ps_user_id IS NOT NULL THEN SELECT author_id INTO v_author_id FROM "Authors" WHERE ps_user_id = v_ps_user_id;
              ELSIF v_email IS NOT NULL AND v_email <> '' THEN SELECT author_id INTO v_author_id FROM "Authors" WHERE email = v_email;
              ELSIF v_orcid IS NOT NULL AND v_orcid <> '' THEN SELECT author_id INTO v_author_id FROM "Authors" WHERE orcid = v_orcid;
              END IF;
           END IF;
        END IF;

        -- 3. Link author to paper in Paper_Authors, if author_id was found/created
        IF v_author_id IS NOT NULL THEN
          INSERT INTO "Paper_Authors" (paper_id, author_id, author_order, contribution_group, author_role)
          VALUES (
            v_paper_id,
            v_author_id,
            (v_author_json->>'author_order')::INTEGER, -- Requires author_order in input JSON
            COALESCE((v_author_json->>'contribution_group')::INTEGER, 0), -- Default to 0 if missing
            v_author_json->>'author_role' -- Null if missing
          )
          ON CONFLICT (paper_id, author_id) DO NOTHING;
        ELSE 
          RAISE WARNING 'Could not find or create author record for: %', v_author_json;
        END IF;
      END LOOP;
    END IF;
    
    -- 4. Create peer review activity
    INSERT INTO "Peer_Review_Activities" (
      paper_id, creator_id, template_id, funding_amount, escrow_balance,
      current_state, stage_deadline, posted_at
    ) VALUES (
      v_paper_id, p_uploaded_by, p_template_id, v_template_tokens, v_template_tokens,
      'submitted', NOW() + INTERVAL '14 days', NOW()
    ) RETURNING activity_id, activity_uuid INTO v_activity_id, v_activity_uuid;
    
    -- 5. Update paper with activity UUID
    UPDATE "Papers"
    SET activity_uuids = array_append(activity_uuids, v_activity_uuid)
    WHERE paper_id = v_paper_id;
    
    -- 6. Create wallet transaction (token deduction)
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

-- Function to create additional PR activity for an existing paper (DOES NOT NEED AUTHOR HANDLING)
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
   SELECT EXISTS(SELECT 1 FROM "Papers" WHERE paper_id = p_paper_id) INTO v_paper_exists;
  IF NOT v_paper_exists THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Paper not found with ID: ' || p_paper_id
    );
  END IF;
  SELECT total_tokens INTO v_template_tokens
  FROM "Peer_Review_Templates"
  WHERE template_id = p_template_id;
  IF v_template_tokens IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Invalid template ID: ' || p_template_id
    );
  END IF;
  SELECT balance INTO v_wallet_balance
  FROM "User_Wallet_Balances"
  WHERE user_id = p_creator_id;
  IF v_wallet_balance IS NULL OR v_wallet_balance < v_template_tokens THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient tokens. You need at least ' || v_template_tokens || ' tokens to create this activity.'
    );
  END IF;

  BEGIN
    INSERT INTO "Peer_Review_Activities" (
      paper_id, creator_id, template_id, funding_amount, escrow_balance,
      current_state, stage_deadline, posted_at
    ) VALUES (
      p_paper_id, p_creator_id, p_template_id, v_template_tokens, v_template_tokens,
      'Submitted', NOW() + INTERVAL '14 days', NOW()
    ) RETURNING activity_id, activity_uuid INTO v_activity_id, v_activity_uuid;
    
    UPDATE "Papers"
    SET activity_uuids = array_append(activity_uuids, v_activity_uuid)
    WHERE paper_id = p_paper_id;
    
    PERFORM activity_deduct_tokens(
      p_creator_id,
      v_template_tokens,
      'Additional PR activity fee for paper #' || p_paper_id,
      v_activity_id,
      v_activity_uuid
    );
    
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

-- Function to check if a user is the creator or an author of the paper linked to an activity
-- Uses relational structure now
CREATE OR REPLACE FUNCTION is_author_or_creator(p_user_id INTEGER, p_activity_id INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
    v_creator_id INTEGER;
    v_paper_id INTEGER;
    v_is_author BOOLEAN := FALSE;
BEGIN
    SELECT creator_id, paper_id INTO v_creator_id, v_paper_id
    FROM "Peer_Review_Activities" WHERE activity_id = p_activity_id;

    IF v_creator_id = p_user_id THEN
        RETURN TRUE;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM "Paper_Authors" pa
        JOIN "Authors" a ON pa.author_id = a.author_id
        WHERE pa.paper_id = v_paper_id AND a.ps_user_id = p_user_id
    ) INTO v_is_author;

    RETURN v_is_author;
END;
$$ LANGUAGE plpgsql STABLE SECURITY DEFINER;

COMMENT ON FUNCTION is_author_or_creator(INTEGER, INTEGER) IS 'Checks if a given user_id corresponds to the creator or an author (via Authors.ps_user_id) of the paper associated with the activity_id. Returns TRUE if they are, FALSE otherwise.'; 