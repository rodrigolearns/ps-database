-- =============================================
-- Seed Data for User_Accounts and Papers
-- =============================================

-- Insert sample users into User_Accounts
-- (Ensure that these UUIDs are static for testing purposes)
INSERT INTO "User_Accounts" (auth_id, email, full_name, username, bio, orcid, affiliations, research_interests, role)
VALUES
  ('11111111-1111-1111-1111-111111111111', 'superadmin@test.com', 'Super Admin', 'superadmin', 'System administrator', '0000-0001-0000-0000', '[]', ARRAY['Admin'], 'superadmin'),
  ('22222222-2222-2222-2222-222222222222', 'admin1@test.com', 'Admin One', 'admin1', 'Administrator', '0000-0001-0000-0001', '[]', ARRAY['Management'], 'admin'),
  ('33333333-3333-3333-3333-333333333333', 'editor1@test.com', 'Editor One', 'editor1', 'Editor', '0000-0001-0000-0002', '[]', ARRAY['Editorial'], 'editor'),
  ('44444444-4444-4444-4444-444444444444', 'user1@test.com', 'User One', 'user1', 'Regular user', '0000-0001-0000-0003', '[]', ARRAY['Research'], 'user'),
  ('55555555-5555-5555-5555-555555555555', 'user2@test.com', 'User Two', 'user2', 'Regular user', '0000-0001-0000-0004', '[]', ARRAY['Science'], 'user')
ON CONFLICT DO NOTHING;

-- Optionally, update wallet balances for testing.
-- Since the wallet is automatically created by the trigger,
-- you can update the balances with additional statements if needed.
UPDATE "User_Wallet_Balances"
SET balance = 100
WHERE user_id IN (
  SELECT user_id FROM "User_Accounts" WHERE username IN ('superadmin', 'admin1')
);
UPDATE "User_Wallet_Balances"
SET balance = 50
WHERE user_id IN (
  SELECT user_id FROM "User_Accounts" WHERE username IN ('editor1', 'user1', 'user2')
);

-- Insert sample papers into Papers table
INSERT INTO "Papers" (title, abstract, storage_reference, uploaded_by, embedding_vector)
VALUES
  (
    'Test Paper One', 
    'This is the abstract for Test Paper One.', 
    'https://example.com/testpaper1.pdf', 
    (SELECT user_id FROM "User_Accounts" WHERE username = 'user1'), 
    '{}'  -- empty embedding_vector; a background process will update it later
  ),
  (
    'Test Paper Two', 
    'This is the abstract for Test Paper Two.', 
    'https://example.com/testpaper2.pdf', 
    (SELECT user_id FROM "User_Accounts" WHERE username = 'user2'),
    '{}'  -- empty embedding_vector
  )
ON CONFLICT DO NOTHING;
