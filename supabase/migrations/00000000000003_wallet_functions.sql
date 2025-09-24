-- =============================================
-- 00000000000003_wallet_functions.sql
-- Wallet Domain: Functions for Wallet Operations
-- =============================================

-- Function to get user wallet balance
CREATE OR REPLACE FUNCTION get_user_wallet_balance(p_user_id INTEGER)
RETURNS INTEGER AS $$
DECLARE
  v_balance INTEGER;
BEGIN
  SELECT balance INTO v_balance
  FROM wallet_balances
  WHERE user_id = p_user_id;
  
  RETURN COALESCE(v_balance, 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION get_user_wallet_balance(INTEGER) IS 'Get the current wallet balance for a user';

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
  FROM user_accounts
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
  
  INSERT INTO wallet_transactions (
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION superadmin_add_tokens(INTEGER, INTEGER, INTEGER, TEXT) IS 'Add tokens to a user wallet (superadmin only)';

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
  FROM user_accounts
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
  FROM wallet_balances
  WHERE user_id = p_target_user_id;
  
  IF COALESCE(v_balance, 0) < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient tokens in user wallet'
    );
  END IF;
  
  INSERT INTO wallet_transactions (
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
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION superadmin_deduct_tokens(INTEGER, INTEGER, INTEGER, TEXT) IS 'Deduct tokens from a user wallet (superadmin only)';

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
  FROM wallet_balances
  WHERE user_id = p_user_id;
  
  RETURN COALESCE(v_balance, 0) >= p_amount;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION has_sufficient_balance(INTEGER, INTEGER) IS 'Check if user has sufficient balance for a transaction';

-- Activity reward function (for reviewers, etc.)
CREATE OR REPLACE FUNCTION activity_reward_tokens(
  p_user_id INTEGER,
  p_amount INTEGER,
  p_activity_id INTEGER DEFAULT NULL,
  p_activity_uuid UUID DEFAULT NULL,
  p_description TEXT DEFAULT 'Activity reward'
)
RETURNS JSONB AS $$
BEGIN
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Reward amount must be positive'
    );
  END IF;
  
  INSERT INTO wallet_transactions (
    user_id,
    amount,
    transaction_type,
    transaction_origin,
    related_activity_id,
    related_activity_uuid,
    description
  ) VALUES (
    p_user_id,
    p_amount,
    'credit',
    'activity',
    p_activity_id,
    p_activity_uuid,
    p_description
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Tokens rewarded successfully',
    'amount', p_amount,
    'user_id', p_user_id,
    'new_balance', get_user_wallet_balance(p_user_id)
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error rewarding tokens: ' || SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION activity_reward_tokens(INTEGER, INTEGER, INTEGER, UUID, TEXT) IS 'Reward tokens to a user for activity participation';

-- Activity deduction function (for activity costs, penalties, etc.)
CREATE OR REPLACE FUNCTION activity_deduct_tokens(
  p_user_id INTEGER,
  p_amount INTEGER,
  p_activity_id INTEGER DEFAULT NULL,
  p_activity_uuid UUID DEFAULT NULL,
  p_description TEXT DEFAULT 'Activity deduction'
)
RETURNS JSONB AS $$
DECLARE
  v_balance INTEGER;
BEGIN
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Deduction amount must be positive'
    );
  END IF;
  
  -- Check if user has sufficient balance
  SELECT balance INTO v_balance 
  FROM wallet_balances
  WHERE user_id = p_user_id;
  
  IF COALESCE(v_balance, 0) < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient tokens in user wallet'
    );
  END IF;
  
  INSERT INTO wallet_transactions (
    user_id,
    amount,
    transaction_type,
    transaction_origin,
    related_activity_id,
    related_activity_uuid,
    description
  ) VALUES (
    p_user_id,
    -p_amount,
    'debit',
    'activity',
    p_activity_id,
    p_activity_uuid,
    p_description
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Tokens deducted successfully',
    'amount', p_amount,
    'user_id', p_user_id,
    'new_balance', get_user_wallet_balance(p_user_id)
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error deducting tokens: ' || SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION activity_deduct_tokens(INTEGER, INTEGER, INTEGER, UUID, TEXT) IS 'Deduct tokens from a user for activity costs or penalties'; 

-- Escrow transfer function (transfer tokens from activity escrow to user wallet)
CREATE OR REPLACE FUNCTION transfer_from_escrow_to_user(
  p_activity_id INTEGER,
  p_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Escrow transfer'
)
RETURNS JSONB AS $$
DECLARE
  v_escrow_balance INTEGER;
  v_activity_uuid UUID;
BEGIN
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Transfer amount must be positive'
    );
  END IF;
  
  -- Get and lock escrow balance
  SELECT escrow_balance, activity_uuid INTO v_escrow_balance, v_activity_uuid
  FROM pr_activities 
  WHERE activity_id = p_activity_id
  FOR UPDATE;
  
  IF v_escrow_balance IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Activity not found'
    );
  END IF;
  
  IF v_escrow_balance < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient escrow balance'
    );
  END IF;
  
  -- Transfer tokens: decrease escrow, increase user wallet
  UPDATE pr_activities
  SET escrow_balance = escrow_balance - p_amount,
      updated_at = NOW()
  WHERE activity_id = p_activity_id;
  
  -- Credit tokens to user wallet
  INSERT INTO wallet_transactions (
    user_id,
    amount,
    transaction_type,
    transaction_origin,
    related_activity_id,
    related_activity_uuid,
    description
  ) VALUES (
    p_user_id,
    p_amount,
    'credit',
    'activity',
    p_activity_id,
    v_activity_uuid,
    p_description
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Tokens transferred successfully from escrow',
    'amount', p_amount,
    'user_id', p_user_id,
    'activity_id', p_activity_id,
    'new_user_balance', get_user_wallet_balance(p_user_id),
    'new_escrow_balance', v_escrow_balance - p_amount
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error transferring from escrow: ' || SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION transfer_from_escrow_to_user(INTEGER, INTEGER, INTEGER, TEXT) IS 'Transfer tokens from activity escrow to user wallet';

-- Escrow transfer function for superadmin (for insurance tokens)
CREATE OR REPLACE FUNCTION transfer_escrow_to_superadmin(
  p_activity_id INTEGER,
  p_superadmin_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Insurance transfer from escrow'
)
RETURNS JSONB AS $$
DECLARE
  v_escrow_balance INTEGER;
  v_activity_uuid UUID;
  v_is_superadmin BOOLEAN;
BEGIN
  -- Verify the superadmin role
  SELECT (role = 'superadmin') INTO v_is_superadmin
  FROM user_accounts
  WHERE user_id = p_superadmin_id;
  
  IF NOT v_is_superadmin THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Only superadmins can receive insurance transfers'
    );
  END IF;
  
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Transfer amount must be positive'
    );
  END IF;
  
  -- Get and lock escrow balance
  SELECT escrow_balance, activity_uuid INTO v_escrow_balance, v_activity_uuid
  FROM pr_activities 
  WHERE activity_id = p_activity_id
  FOR UPDATE;
  
  IF v_escrow_balance IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Activity not found'
    );
  END IF;
  
  IF v_escrow_balance < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient escrow balance for insurance transfer'
    );
  END IF;
  
  -- Transfer tokens: decrease escrow, increase superadmin wallet
  UPDATE pr_activities
  SET escrow_balance = escrow_balance - p_amount,
      updated_at = NOW()
  WHERE activity_id = p_activity_id;
  
  -- Credit tokens to superadmin wallet
  INSERT INTO wallet_transactions (
    user_id,
    amount,
    transaction_type,
    transaction_origin,
    superadmin_id,
    related_activity_id,
    related_activity_uuid,
    description
  ) VALUES (
    p_superadmin_id,
    p_amount,
    'credit',
    'superadmin',
    p_superadmin_id,
    p_activity_id,
    v_activity_uuid,
    p_description
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Insurance tokens transferred successfully from escrow',
    'amount', p_amount,
    'superadmin_id', p_superadmin_id,
    'activity_id', p_activity_id,
    'new_superadmin_balance', get_user_wallet_balance(p_superadmin_id),
    'new_escrow_balance', v_escrow_balance - p_amount
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error transferring insurance from escrow: ' || SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION transfer_escrow_to_superadmin(INTEGER, INTEGER, INTEGER, TEXT) IS 'Transfer insurance tokens from activity escrow to superadmin wallet'; 

-- Atomic escrow funding function (transfer tokens from user wallet to activity escrow)
CREATE OR REPLACE FUNCTION fund_activity_escrow(
  p_activity_id INTEGER,
  p_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Activity escrow funding'
)
RETURNS JSONB AS $$
DECLARE
  v_user_balance INTEGER;
  v_activity_uuid UUID;
  v_current_escrow INTEGER;
BEGIN
  IF p_amount <= 0 THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Funding amount must be positive'
    );
  END IF;
  
  -- Get and lock user wallet balance
  SELECT balance INTO v_user_balance
  FROM wallet_balances 
  WHERE user_id = p_user_id
  FOR UPDATE;
  
  IF v_user_balance IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'User wallet not found'
    );
  END IF;
  
  IF v_user_balance < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient user balance for escrow funding'
    );
  END IF;
  
  -- Get and lock activity escrow
  SELECT escrow_balance, activity_uuid INTO v_current_escrow, v_activity_uuid
  FROM pr_activities 
  WHERE activity_id = p_activity_id
  FOR UPDATE;
  
  IF v_current_escrow IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Activity not found'
    );
  END IF;
  
  -- ATOMIC TRANSFER: Deduct from user wallet, add to activity escrow
  
  -- 1. Deduct tokens from user wallet
  UPDATE wallet_balances
  SET balance = balance - p_amount,
      last_updated = NOW()
  WHERE user_id = p_user_id;
  
  -- 2. Add tokens to activity escrow
  UPDATE pr_activities
  SET escrow_balance = escrow_balance + p_amount,
      updated_at = NOW()
  WHERE activity_id = p_activity_id;
  
  -- 3. Record the transaction (debit from user)
  INSERT INTO wallet_transactions (
    user_id,
    amount,
    transaction_type,
    transaction_origin,
    related_activity_id,
    related_activity_uuid,
    description
  ) VALUES (
    p_user_id,
    -p_amount,
    'debit',
    'activity',
    p_activity_id,
    v_activity_uuid,
    p_description
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Escrow funded successfully',
    'amount', p_amount,
    'user_id', p_user_id,
    'activity_id', p_activity_id,
    'new_user_balance', v_user_balance - p_amount,
    'new_escrow_balance', v_current_escrow + p_amount
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error funding escrow: ' || SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION fund_activity_escrow(INTEGER, INTEGER, INTEGER, TEXT) IS 'Atomically transfer tokens from user wallet to activity escrow'; 