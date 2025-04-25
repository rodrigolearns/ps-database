-- =============================================
-- 00000000000002_wallets.sql
-- Migration for Wallet Tables and Wallet Triggers
-- =============================================

-- Create ENUM for transaction types using standard names
DO $$ BEGIN
  CREATE TYPE transaction_type AS ENUM ('credit', 'debit');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON TYPE transaction_type IS 'Types of transactions in the wallet system';

-- Create ENUM for transaction origins
DO $$ BEGIN
  CREATE TYPE transaction_origin AS ENUM ('activity', 'superadmin', 'system');
EXCEPTION
  WHEN duplicate_object THEN NULL;
END $$;
COMMENT ON TYPE transaction_origin IS 'Origin of the transaction (activity-related, superadmin, or system)';

-- Create user_wallet_balances table
CREATE TABLE IF NOT EXISTS user_wallet_balances (
  wallet_id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES user_accounts(user_id) ON DELETE CASCADE,
  balance INTEGER NOT NULL DEFAULT 0,
  last_updated TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id)
);
COMMENT ON TABLE user_wallet_balances IS 'User wallet balances managed through the transaction system';

-- Create wallet_transactions table
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
COMMENT ON COLUMN wallet_transactions.transaction_origin IS 'Origin of the transaction (activity-related, superadmin, or system)';
COMMENT ON COLUMN wallet_transactions.superadmin_id IS 'Admin who authorized the transaction (for superadmin transactions)';
COMMENT ON COLUMN wallet_transactions.related_activity_uuid IS 'UUID of the related activity (if applicable)';

-- Trigger: Update wallet balance after a transaction is inserted
CREATE OR REPLACE FUNCTION update_wallet_balance_after_transaction()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE user_wallet_balances
  SET balance = balance + NEW.amount,
      last_updated = NOW()
  WHERE user_id = NEW.user_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS update_wallet_balance_trigger ON wallet_transactions;
CREATE TRIGGER update_wallet_balance_trigger
AFTER INSERT ON wallet_transactions
FOR EACH ROW
EXECUTE FUNCTION update_wallet_balance_after_transaction();

-- Trigger: Create wallet for new user automatically
CREATE OR REPLACE FUNCTION initialize_user_wallet()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO user_wallet_balances (user_id, balance)
  VALUES (NEW.user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS create_wallet_for_new_user ON user_accounts;
CREATE TRIGGER create_wallet_for_new_user
AFTER INSERT ON user_accounts
FOR EACH ROW
EXECUTE FUNCTION initialize_user_wallet();
