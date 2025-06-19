-- =============================================
-- 00000000000002_wallet.sql
-- Wallet Domain: Balances and Transactions
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

-- Wallet balances table
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

-- Wallet transactions table
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
COMMENT ON COLUMN wallet_transactions.related_activity_id IS 'Related activity ID (if applicable)';
COMMENT ON COLUMN wallet_transactions.related_activity_uuid IS 'UUID of the related activity (if applicable)';

-- Indexes
CREATE INDEX IF NOT EXISTS idx_wallet_balances_user_id ON wallet_balances (user_id);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_user_id ON wallet_transactions (user_id);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_timestamp ON wallet_transactions (timestamp);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_activity_id ON wallet_transactions (related_activity_id);
CREATE INDEX IF NOT EXISTS idx_wallet_transactions_activity_uuid ON wallet_transactions (related_activity_uuid);

-- Simple trigger to update wallet balance after transaction
CREATE OR REPLACE FUNCTION update_wallet_balance_after_transaction()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE wallet_balances
  SET balance = balance + NEW.amount,
      last_updated = NOW()
  WHERE user_id = NEW.user_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_wallet_balance_trigger
  AFTER INSERT ON wallet_transactions
  FOR EACH ROW
  EXECUTE FUNCTION update_wallet_balance_after_transaction();

-- Simple trigger to create wallet for new user
CREATE OR REPLACE FUNCTION initialize_user_wallet()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO wallet_balances (user_id, balance)
  VALUES (NEW.user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER create_wallet_for_new_user
  AFTER INSERT ON user_accounts
  FOR EACH ROW
  EXECUTE FUNCTION initialize_user_wallet(); 