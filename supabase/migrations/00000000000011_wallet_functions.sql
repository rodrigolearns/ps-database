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

-- Function to add tokens to user wallet
CREATE OR REPLACE FUNCTION add_tokens_to_wallet(
  p_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Token purchase'
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
    description
  ) VALUES (
    p_user_id,
    p_amount,
    'credit',
    p_description
  );
  
  RETURN TRUE;
EXCEPTION
  WHEN OTHERS THEN
    RETURN FALSE;
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

-- Function to deduct tokens from user wallet
CREATE OR REPLACE FUNCTION deduct_tokens_from_wallet(
  p_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Token deduction',
  p_related_activity_id INTEGER DEFAULT NULL,
  p_activity_type TEXT DEFAULT NULL
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
    description,
    related_activity_id,
    activity_type
  ) VALUES (
    p_user_id,
    -p_amount, -- Negative for debit
    'debit',
    p_description,
    p_related_activity_id,
    p_activity_type
  );
  
  RETURN TRUE;
EXCEPTION
  WHEN OTHERS THEN
    RETURN FALSE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER; 