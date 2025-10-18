-- =============================================
-- 00000000000002_wallet.sql
-- Wallet Domain: Balances, Transactions, and Token Operations
-- =============================================

-- Create ENUMs for transaction system
DO $$ BEGIN
  CREATE TYPE transaction_type AS ENUM ('credit', 'debit');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON TYPE transaction_type IS 'Types of transactions in the wallet system';

DO $$ BEGIN
  CREATE TYPE transaction_origin AS ENUM ('activity', 'superadmin', 'system');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;

COMMENT ON TYPE transaction_origin IS 'Origin of the transaction (activity-related, superadmin, or system)';

-- =============================================
-- Wallet Balances Table
-- =============================================
CREATE TABLE IF NOT EXISTS wallet_balances (
  wallet_id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  balance INTEGER NOT NULL DEFAULT 0,
  last_updated TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id)
);

COMMENT ON TABLE wallet_balances IS 'User wallet balances managed through the transaction system';
COMMENT ON COLUMN wallet_balances.wallet_id IS 'Primary key for the wallet';
COMMENT ON COLUMN wallet_balances.user_id IS 'Foreign key to user_accounts';
COMMENT ON COLUMN wallet_balances.balance IS 'Current balance in tokens';
COMMENT ON COLUMN wallet_balances.last_updated IS 'When the balance was last updated';

-- =============================================
-- Wallet Transactions Table
-- =============================================
CREATE TABLE IF NOT EXISTS wallet_transactions (
  transaction_id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  related_user_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  amount INTEGER NOT NULL,
  transaction_type transaction_type NOT NULL,
  transaction_origin transaction_origin NOT NULL DEFAULT 'system',
  superadmin_id INTEGER REFERENCES user_accounts(user_id) ON DELETE SET NULL,
  description TEXT,
  timestamp TIMESTAMPTZ DEFAULT NOW(),
  related_activity_id INTEGER,
  related_activity_uuid UUID
);

COMMENT ON TABLE wallet_transactions IS 'Record of token movements in the platform';
COMMENT ON COLUMN wallet_transactions.transaction_id IS 'Primary key for the transaction';
COMMENT ON COLUMN wallet_transactions.user_id IS 'User whose wallet is affected';
COMMENT ON COLUMN wallet_transactions.related_user_id IS 'Related user (for transfers)';
COMMENT ON COLUMN wallet_transactions.amount IS 'Transaction amount (positive for credit, negative for debit)';
COMMENT ON COLUMN wallet_transactions.transaction_type IS 'Type of transaction (credit/debit)';
COMMENT ON COLUMN wallet_transactions.transaction_origin IS 'Origin of the transaction';
COMMENT ON COLUMN wallet_transactions.superadmin_id IS 'Admin who authorized the transaction (for superadmin transactions)';
COMMENT ON COLUMN wallet_transactions.description IS 'Description of the transaction';
COMMENT ON COLUMN wallet_transactions.timestamp IS 'When the transaction occurred';
COMMENT ON COLUMN wallet_transactions.related_activity_id IS 'Related activity ID (polymorphic - could be pr_activities or jc_activities)';
COMMENT ON COLUMN wallet_transactions.related_activity_uuid IS 'UUID of the related activity (for lookups across activity types)';

-- =============================================
-- Indexes
-- =============================================
CREATE INDEX IF NOT EXISTS idx_wallet_balances_user_id ON wallet_balances (user_id);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_user_id ON wallet_transactions (user_id);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_timestamp ON wallet_transactions (timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_activity_id ON wallet_transactions (related_activity_id) WHERE related_activity_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_activity_uuid ON wallet_transactions (related_activity_uuid) WHERE related_activity_uuid IS NOT NULL;

-- =============================================
-- Wallet Balance Update Trigger
-- =============================================
-- Automatically updates wallet balance when transaction is inserted
-- Validates sufficient funds for debits
CREATE OR REPLACE FUNCTION validate_and_update_wallet_balance()
RETURNS TRIGGER AS $$
DECLARE
  current_balance INTEGER;
BEGIN
  -- Prevent duplicate transactions (within 1 minute window)
  IF EXISTS (
    SELECT 1 FROM public.wallet_transactions 
    WHERE user_id = NEW.user_id 
    AND related_activity_id = NEW.related_activity_id
    AND description = NEW.description
    AND ABS(amount) = ABS(NEW.amount)
    AND timestamp > NOW() - INTERVAL '1 minute'
    AND transaction_id != NEW.transaction_id
  ) THEN
    RAISE EXCEPTION 'Duplicate transaction detected for user % with description: %', NEW.user_id, NEW.description;
  END IF;
  
  -- Get current balance with row lock for debit transactions
  IF NEW.transaction_type = 'debit' THEN
    SELECT balance INTO current_balance 
    FROM public.wallet_balances 
    WHERE user_id = NEW.user_id
    FOR UPDATE;
    
    -- Validate sufficient balance (amount is negative for debits)
    IF current_balance + NEW.amount < 0 THEN
      RAISE EXCEPTION 'Insufficient balance for user %. Current: %, Attempted debit: %', 
        NEW.user_id, current_balance, ABS(NEW.amount);
    END IF;
  END IF;
  
  -- Update balance
  UPDATE public.wallet_balances
  SET balance = balance + NEW.amount,
      last_updated = NOW()
  WHERE user_id = NEW.user_id;
  
  -- Verify the update succeeded
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Wallet not found for user %', NEW.user_id;
  END IF;
  
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION validate_and_update_wallet_balance() IS 'Trigger function to validate and update wallet balance on transaction insert';

CREATE TRIGGER validate_wallet_transaction_trigger
  AFTER INSERT ON wallet_transactions
  FOR EACH ROW
  EXECUTE FUNCTION validate_and_update_wallet_balance();

-- =============================================
-- Initialize Wallet for New Users
-- =============================================
-- Automatically creates wallet when user account is created
CREATE OR REPLACE FUNCTION initialize_user_wallet()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.wallet_balances (user_id, balance)
  VALUES (NEW.user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION initialize_user_wallet() IS 'Trigger function to create wallet for new users';

CREATE TRIGGER create_wallet_for_new_user
  AFTER INSERT ON user_accounts
  FOR EACH ROW
  EXECUTE FUNCTION initialize_user_wallet();

-- =============================================
-- Wallet Helper Functions
-- =============================================

-- Get user wallet balance
CREATE OR REPLACE FUNCTION get_user_wallet_balance(p_user_id INTEGER)
RETURNS INTEGER AS $$
DECLARE
  v_balance INTEGER;
BEGIN
  SELECT balance INTO v_balance
  FROM public.wallet_balances
  WHERE user_id = p_user_id;
  
  RETURN COALESCE(v_balance, 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION get_user_wallet_balance(INTEGER) IS 'Get the current wallet balance for a user';

-- Check if user has sufficient balance
CREATE OR REPLACE FUNCTION has_sufficient_balance(
  p_user_id INTEGER,
  p_amount INTEGER
)
RETURNS BOOLEAN AS $$
DECLARE
  v_balance INTEGER;
BEGIN
  SELECT balance INTO v_balance 
  FROM public.wallet_balances
  WHERE user_id = p_user_id;
  
  RETURN COALESCE(v_balance, 0) >= p_amount;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION has_sufficient_balance(INTEGER, INTEGER) IS 'Check if user has sufficient balance for a transaction';

-- =============================================
-- Activity Token Functions
-- =============================================

-- Deduct tokens from user wallet for activity creation
CREATE OR REPLACE FUNCTION activity_deduct_tokens(
  p_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT,
  p_activity_id INTEGER,
  p_activity_uuid UUID
)
RETURNS BOOLEAN AS $$
DECLARE
  v_current_balance INTEGER;
BEGIN
  -- Get current balance with row lock
  SELECT balance INTO v_current_balance
  FROM wallet_balances
  WHERE user_id = p_user_id
  FOR UPDATE;

  IF v_current_balance IS NULL OR v_current_balance < p_amount THEN
    RETURN FALSE;
  END IF;

  -- Record transaction (trigger will update wallet balance automatically)
  INSERT INTO wallet_transactions (
    user_id, amount, transaction_type,
    description, related_activity_id, related_activity_uuid
  ) VALUES (
    p_user_id, -p_amount, 'debit',
    p_description, p_activity_id, p_activity_uuid
  );

  RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION activity_deduct_tokens(INTEGER, INTEGER, TEXT, INTEGER, UUID) IS 'Deducts tokens from user wallet for activity creation/participation';

-- Reward tokens to user for activity participation
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
  
  INSERT INTO public.wallet_transactions (
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
    'new_balance', public.get_user_wallet_balance(p_user_id)
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

-- =============================================
-- Escrow Functions (PR Activity Specific)
-- =============================================

-- Transfer tokens from user wallet to activity escrow (activity funding)
CREATE OR REPLACE FUNCTION fund_activity_escrow(
  p_activity_id INTEGER,
  p_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Activity escrow funding'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
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
  FROM public.wallet_balances 
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
  FROM public.pr_activities 
  WHERE activity_id = p_activity_id
  FOR UPDATE;
  
  IF v_current_escrow IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Activity not found'
    );
  END IF;
  
  -- ATOMIC TRANSFER: Add to activity escrow, then record transaction
  UPDATE public.pr_activities
  SET escrow_balance = escrow_balance + p_amount,
      funding_amount = COALESCE(funding_amount, 0) + p_amount,
      updated_at = NOW()
  WHERE activity_id = p_activity_id;
  
  -- Record transaction (trigger will update wallet balance)
  INSERT INTO public.wallet_transactions (
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
$$;

COMMENT ON FUNCTION fund_activity_escrow(INTEGER, INTEGER, INTEGER, TEXT) IS 'Atomically transfer tokens from user wallet to PR activity escrow';

-- Transfer tokens from activity escrow to user wallet (award distribution)
CREATE OR REPLACE FUNCTION transfer_from_escrow_to_user(
  p_activity_id INTEGER,
  p_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Award from escrow'
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
  FROM public.pr_activities 
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
  UPDATE public.pr_activities
  SET escrow_balance = escrow_balance - p_amount,
      updated_at = NOW()
  WHERE activity_id = p_activity_id;
  
  -- Credit tokens to user wallet
  INSERT INTO public.wallet_transactions (
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
    'new_user_balance', public.get_user_wallet_balance(p_user_id),
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

COMMENT ON FUNCTION transfer_from_escrow_to_user(INTEGER, INTEGER, INTEGER, TEXT) IS 'Transfer tokens from PR activity escrow to user wallet';

-- Transfer escrow to superadmin (insurance tokens)
CREATE OR REPLACE FUNCTION transfer_escrow_to_superadmin(
  p_activity_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Insurance transfer from escrow'
)
RETURNS JSONB AS $$
DECLARE
  v_superadmin_id INTEGER;
  v_escrow_balance INTEGER;
  v_activity_uuid UUID;
BEGIN
  -- Find the superadmin user
  SELECT user_id INTO v_superadmin_id
  FROM public.user_accounts
  WHERE role = 'superadmin'
  LIMIT 1;
  
  IF v_superadmin_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Super admin not found in system'
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
  FROM public.pr_activities 
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
  UPDATE public.pr_activities
  SET escrow_balance = escrow_balance - p_amount,
      updated_at = NOW()
  WHERE activity_id = p_activity_id;
  
  -- Credit tokens to superadmin wallet
  INSERT INTO public.wallet_transactions (
    user_id,
    amount,
    transaction_type,
    transaction_origin,
    superadmin_id,
    related_activity_id,
    related_activity_uuid,
    description
  ) VALUES (
    v_superadmin_id,
    p_amount,
    'credit',
    'superadmin',
    v_superadmin_id,
    p_activity_id,
    v_activity_uuid,
    p_description
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Insurance tokens transferred successfully from escrow',
    'amount', p_amount,
    'superadmin_id', v_superadmin_id,
    'activity_id', p_activity_id,
    'new_superadmin_balance', public.get_user_wallet_balance(v_superadmin_id),
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

COMMENT ON FUNCTION transfer_escrow_to_superadmin(INTEGER, INTEGER, TEXT) IS 'Transfer insurance tokens from PR activity escrow to superadmin wallet';

-- =============================================
-- Superadmin Wallet Functions
-- =============================================

-- Superadmin adds tokens to user wallet
CREATE OR REPLACE FUNCTION superadmin_add_tokens(
  p_target_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Superadmin token grant'
)
RETURNS JSONB AS $$
DECLARE
  v_caller_user_id INTEGER;
  v_is_superadmin BOOLEAN;
BEGIN
  -- Get caller's user_id from auth context
  SELECT user_id INTO v_caller_user_id 
  FROM public.user_accounts 
  WHERE auth_id = auth.uid();
  
  IF v_caller_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Authentication required'
    );
  END IF;
  
  -- Verify caller is superadmin
  SELECT (role = 'superadmin') INTO v_is_superadmin
  FROM public.user_accounts
  WHERE user_id = v_caller_user_id;
  
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
  
  INSERT INTO public.wallet_transactions (
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
    v_caller_user_id,
    p_description
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Tokens added successfully',
    'amount', p_amount,
    'user_id', p_target_user_id,
    'new_balance', public.get_user_wallet_balance(p_target_user_id)
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error adding tokens: ' || SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION superadmin_add_tokens(INTEGER, INTEGER, TEXT) IS 'Add tokens to user wallet (superadmin only - caller verified via auth.uid())';

-- Superadmin deducts tokens from user wallet
CREATE OR REPLACE FUNCTION superadmin_deduct_tokens(
  p_target_user_id INTEGER,
  p_amount INTEGER,
  p_description TEXT DEFAULT 'Superadmin token deduction'
)
RETURNS JSONB AS $$
DECLARE
  v_caller_user_id INTEGER;
  v_is_superadmin BOOLEAN;
  v_balance INTEGER;
BEGIN
  -- Get caller's user_id from auth context
  SELECT user_id INTO v_caller_user_id 
  FROM public.user_accounts 
  WHERE auth_id = auth.uid();
  
  IF v_caller_user_id IS NULL THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Authentication required'
    );
  END IF;
  
  -- Verify caller is superadmin
  SELECT (role = 'superadmin') INTO v_is_superadmin
  FROM public.user_accounts
  WHERE user_id = v_caller_user_id;
  
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
  FROM public.wallet_balances
  WHERE user_id = p_target_user_id;
  
  IF COALESCE(v_balance, 0) < p_amount THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Insufficient tokens in user wallet'
    );
  END IF;
  
  INSERT INTO public.wallet_transactions (
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
    v_caller_user_id,
    p_description
  );
  
  RETURN jsonb_build_object(
    'success', true,
    'message', 'Tokens deducted successfully',
    'amount', p_amount,
    'user_id', p_target_user_id,
    'new_balance', public.get_user_wallet_balance(p_target_user_id)
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object(
      'success', false,
      'message', 'Error deducting tokens: ' || SQLERRM
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = '';

COMMENT ON FUNCTION superadmin_deduct_tokens(INTEGER, INTEGER, TEXT) IS 'Deduct tokens from user wallet (superadmin only - caller verified via auth.uid())';

-- =============================================
-- Function Permissions
-- =============================================
-- Wallet functions handle sensitive financial operations
-- Only service role can execute (API routes enforce authorization)

REVOKE EXECUTE ON FUNCTION get_user_wallet_balance(INTEGER) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION has_sufficient_balance(INTEGER, INTEGER) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION activity_deduct_tokens(INTEGER, INTEGER, TEXT, INTEGER, UUID) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION activity_reward_tokens(INTEGER, INTEGER, INTEGER, UUID, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION fund_activity_escrow(INTEGER, INTEGER, INTEGER, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION transfer_from_escrow_to_user(INTEGER, INTEGER, INTEGER, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION transfer_escrow_to_superadmin(INTEGER, INTEGER, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION superadmin_add_tokens(INTEGER, INTEGER, TEXT) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION superadmin_deduct_tokens(INTEGER, INTEGER, TEXT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION get_user_wallet_balance(INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION has_sufficient_balance(INTEGER, INTEGER) TO service_role;
GRANT EXECUTE ON FUNCTION activity_deduct_tokens(INTEGER, INTEGER, TEXT, INTEGER, UUID) TO service_role;
GRANT EXECUTE ON FUNCTION activity_reward_tokens(INTEGER, INTEGER, INTEGER, UUID, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION fund_activity_escrow(INTEGER, INTEGER, INTEGER, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION transfer_from_escrow_to_user(INTEGER, INTEGER, INTEGER, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION transfer_escrow_to_superadmin(INTEGER, INTEGER, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION superadmin_add_tokens(INTEGER, INTEGER, TEXT) TO service_role;
GRANT EXECUTE ON FUNCTION superadmin_deduct_tokens(INTEGER, INTEGER, TEXT) TO service_role;

-- =============================================
-- Row Level Security Policies
-- =============================================

-- Enable RLS on wallet_balances
ALTER TABLE wallet_balances ENABLE ROW LEVEL SECURITY;

-- Users can read their own wallet balance, service role can read/modify all
CREATE POLICY wallet_balances_select_own_or_service ON wallet_balances
  FOR SELECT
  USING (
    user_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can modify balances (via wallet functions)
CREATE POLICY wallet_balances_insert_service_role_only ON wallet_balances
  FOR INSERT
  WITH CHECK ((SELECT auth.role()) = 'service_role');

CREATE POLICY wallet_balances_update_service_role_only ON wallet_balances
  FOR UPDATE
  USING ((SELECT auth.role()) = 'service_role')
  WITH CHECK ((SELECT auth.role()) = 'service_role');

CREATE POLICY wallet_balances_delete_service_role_only ON wallet_balances
  FOR DELETE
  USING ((SELECT auth.role()) = 'service_role');

-- Enable RLS on wallet_transactions
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;

-- Users can read their own transactions, service role can read all
CREATE POLICY wallet_transactions_select_own_or_service ON wallet_transactions
  FOR SELECT
  USING (
    user_id = (SELECT auth_user_id()) OR
    (SELECT auth.role()) = 'service_role'
  );

-- Only service role can insert transactions (via wallet functions)
CREATE POLICY wallet_transactions_insert_service_role_only ON wallet_transactions
  FOR INSERT
  WITH CHECK ((SELECT auth.role()) = 'service_role');

