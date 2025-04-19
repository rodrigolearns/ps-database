-- =============================================
-- 00000000000011_wallet_functions.sql
-- Functions for wallet operations
-- =============================================

-- Function to get user wallet balance
CREATE OR REPLACE FUNCTION get_user_wallet_balance(p_user_id INTEGER)
RETURNS INTEGER AS $$
DECLARE
  v_balance INTEGER;
BEGIN
  SELECT balance INTO v_balance 
  FROM "User_Wallet_Balances"
  WHERE user_id = p_user_id;
  
  RETURN COALESCE(v_balance, 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function for superadmin to add tokens to user wallet
CREATE OR REPLACE FUNCTION superadmin_add_tokens(
  p_superadmin_id INTEGER,
  p_target_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Superadmin token grant'
)
RETURNS JSONB AS $$
DECLARE
  v_is_superadmin BOOLEAN;
BEGIN
  -- Verify the superadmin role
  SELECT (role = 'superadmin') INTO v_is_superadmin
  FROM "User_Accounts"
  WHERE user_id = p_superadmin_id;
  
  IF NOT v_is_superadmin THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Only superadmins can perform this operation'
    );
  END IF;
  
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Token amount must be positive'
    );
  END IF;
  
  INSERT INTO "Wallet_Transactions" (
    user_id,
    amount,
    transaction_type,
    transaction_origin,
    superadmin_id,
    description
  ) VALUES (
    p_target_user_id,
    p_amount,
    'credit',
    'superadmin',
    p_superadmin_id,
    p_description
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Tokens added successfully',
    'amount', p_amount,
    'user_id', p_target_user_id,
    'new_balance', get_user_wallet_balance(p_target_user_id)
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error adding tokens: ' || SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function for superadmin to deduct tokens from user wallet
CREATE OR REPLACE FUNCTION superadmin_deduct_tokens(
  p_superadmin_id INTEGER,
  p_target_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Superadmin token deduction'
)
RETURNS JSONB AS $$
DECLARE
  v_is_superadmin BOOLEAN;
  v_balance INTEGER;
BEGIN
  -- Verify the superadmin role
  SELECT (role = 'superadmin') INTO v_is_superadmin
  FROM "User_Accounts"
  WHERE user_id = p_superadmin_id;
  
  IF NOT v_is_superadmin THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Only superadmins can perform this operation'
    );
  END IF;
  
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Token amount must be positive'
    );
  END IF;
  
  -- Check if user has sufficient balance
  SELECT balance INTO v_balance 
  FROM "User_Wallet_Balances"
  WHERE user_id = p_target_user_id;
  
  IF COALESCE(v_balance, 0) < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient tokens in user wallet'
    );
  END IF;
  
  INSERT INTO "Wallet_Transactions" (
    user_id,
    amount,
    transaction_type,
    transaction_origin,
    superadmin_id,
    description
  ) VALUES (
    p_target_user_id,
    -p_amount,
    'debit',
    'superadmin',
    p_superadmin_id,
    p_description
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Tokens deducted successfully',
    'amount', p_amount,
    'user_id', p_target_user_id,
    'new_balance', get_user_wallet_balance(p_target_user_id)
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error deducting tokens: ' || SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to check if user has sufficient balance
CREATE OR REPLACE FUNCTION has_sufficient_balance(
  p_user_id INTEGER,
  p_amount INTEGER
)
RETURNS BOOLEAN AS $$
DECLARE
  v_balance INTEGER;
BEGIN
  SELECT balance INTO v_balance 
  FROM "User_Wallet_Balances"
  WHERE user_id = p_user_id;
  
  RETURN COALESCE(v_balance, 0) >= p_amount;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Activity reward function (for reviewers, etc.)
CREATE OR REPLACE FUNCTION activity_reward_tokens(
  p_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT,
  p_related_activity_id INTEGER,
  p_related_activity_uuid UUID
)
RETURNS BOOLEAN AS $$
BEGIN
  IF p_amount <= 0 THEN
    RETURN FALSE;
  END IF;
  
  INSERT INTO "Wallet_Transactions" (
    user_id,
    amount,
    transaction_type,
    transaction_origin,
    description,
    related_activity_id,
    related_activity_uuid
  ) VALUES (
    p_user_id,
    p_amount,
    'credit',
    'activity',
    p_description,
    p_related_activity_id,
    p_related_activity_uuid
  );
  
  RETURN TRUE;
EXCEPTION
  WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Activity cost function (for creating activities)
CREATE OR REPLACE FUNCTION activity_deduct_tokens(
  p_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT,
  p_related_activity_id INTEGER,
  p_related_activity_uuid UUID
)
RETURNS BOOLEAN AS $$
BEGIN
  IF p_amount <= 0 THEN
    RETURN FALSE;
  END IF;
  
  -- Check if user has sufficient balance
  IF NOT has_sufficient_balance(p_user_id, p_amount) THEN
    RETURN FALSE;
  END IF;
  
  INSERT INTO "Wallet_Transactions" (
    user_id,
    amount,
    transaction_type,
    transaction_origin,
    description,
    related_activity_id,
    related_activity_uuid
  ) VALUES (
    p_user_id,
    -p_amount,
    'debit',
    'activity',
    p_description,
    p_related_activity_id,
    p_related_activity_uuid
  );
  
  RETURN TRUE;
EXCEPTION
  WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER; 