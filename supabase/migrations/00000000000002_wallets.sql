-- =============================================
-- 00000000000002_wallets.sql
-- Wallet Tables and Wallet Triggers
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

-- Create User_Wallet_Balances table
CREATE TABLE IF NOT EXISTS "User_Wallet_Balances" (
  wallet_id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES "User_Accounts"(user_id) ON DELETE CASCADE,
  balance INTEGER NOT NULL DEFAULT 0,
  last_updated TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (user_id)
);
COMMENT ON TABLE "User_Wallet_Balances" IS 'User wallet balances managed through the transaction system';

-- Create Wallet_Transactions table
CREATE TABLE IF NOT EXISTS "Wallet_Transactions" (
  transaction_id SERIAL PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES "User_Accounts"(user_id) ON DELETE CASCADE,
  related_user_id INTEGER REFERENCES "User_Accounts"(user_id) ON DELETE SET NULL,
  amount INTEGER NOT NULL,
  transaction_type transaction_type NOT NULL,
  transaction_origin transaction_origin NOT NULL DEFAULT 'system',
  superadmin_id INTEGER REFERENCES "User_Accounts"(user_id) ON DELETE SET NULL,
  description TEXT,
  timestamp TIMESTAMPTZ DEFAULT NOW(),
  related_activity_id INTEGER,
  related_activity_uuid UUID
);
COMMENT ON TABLE "Wallet_Transactions" IS 'Record of token movements in the platform';
COMMENT ON COLUMN "Wallet_Transactions".transaction_origin IS 'Origin of the transaction (activity-related, superadmin, or system)';
COMMENT ON COLUMN "Wallet_Transactions".superadmin_id IS 'Admin who authorized the transaction (for superadmin transactions)';
COMMENT ON COLUMN "Wallet_Transactions".related_activity_uuid IS 'UUID of the related activity (if applicable)';

-- Trigger: Update wallet balance after a transaction is inserted
CREATE OR REPLACE FUNCTION update_wallet_balance_after_transaction()
RETURNS TRIGGER AS $$
BEGIN
  UPDATE "User_Wallet_Balances"
  SET balance = balance + NEW.amount,
      last_updated = NOW()
  WHERE user_id = NEW.user_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS update_wallet_balance_trigger ON "Wallet_Transactions";
CREATE TRIGGER update_wallet_balance_trigger
AFTER INSERT ON "Wallet_Transactions"
FOR EACH ROW
EXECUTE FUNCTION update_wallet_balance_after_transaction();

-- Trigger: Create wallet for new user automatically
CREATE OR REPLACE FUNCTION initialize_user_wallet()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO "User_Wallet_Balances" (user_id, balance)
  VALUES (NEW.user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS create_wallet_for_new_user ON "User_Accounts";
CREATE TRIGGER create_wallet_for_new_user
AFTER INSERT ON "User_Accounts"
FOR EACH ROW
EXECUTE FUNCTION initialize_user_wallet();
