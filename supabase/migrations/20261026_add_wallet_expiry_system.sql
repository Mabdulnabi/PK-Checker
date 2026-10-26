-- ============================================================
-- Wallet Expiry System
-- Run this in Supabase SQL Editor (or apply_migration)
-- ============================================================

-- 1. Add expires_at column (NULL = never expires)
ALTER TABLE wallet_transactions
  ADD COLUMN IF NOT EXISTS expires_at timestamptz DEFAULT NULL;

-- 2. Add source_tx_id — links an expiry row back to the original credit row
ALTER TABLE wallet_transactions
  ADD COLUMN IF NOT EXISTS source_tx_id uuid DEFAULT NULL
  REFERENCES wallet_transactions(id) ON DELETE SET NULL;

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_wallet_tx_expires_at
  ON wallet_transactions (expires_at)
  WHERE expires_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_wallet_tx_source_tx_id
  ON wallet_transactions (source_tx_id)
  WHERE source_tx_id IS NOT NULL;

-- 3. Allow 'expiry' as a valid type value
DO $$
BEGIN
  BEGIN
    ALTER TABLE wallet_transactions DROP CONSTRAINT IF EXISTS wallet_transactions_type_check;
  EXCEPTION WHEN undefined_object THEN NULL;
  END;
  BEGIN
    ALTER TABLE wallet_transactions
      ADD CONSTRAINT wallet_transactions_type_check
      CHECK (type IN ('credit','debit','refund','expiry'));
  EXCEPTION WHEN duplicate_object THEN NULL;
  END;
END;
$$;

-- 4. Helper: pack_id → expiry days (matches dashboard.html TOPUP_PACKS)
CREATE OR REPLACE FUNCTION get_pack_expiry_days(p_pack_id text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_pack_id
    WHEN 'pack_1'              THEN 2
    WHEN 'pack_5'              THEN 5
    WHEN 'pack_10'             THEN 10
    WHEN 'pack_25'             THEN 15
    WHEN 'pack_daily_starter'  THEN 1
    WHEN 'pack_daily_pro'      THEN 1
    WHEN 'pack_daily_master'   THEN 1
    WHEN 'pack_daily_elite'    THEN 1
    WHEN 'pack_daily_ultimate' THEN 1
    ELSE NULL  -- no expiry
  END;
$$;

-- 5. expire_wallet_credits()
--    Called daily by pg_cron at 01:00 UTC.
--    For every credit transaction whose expires_at has passed and hasn't
--    yet been processed, inserts an 'expiry' debit transaction.
--    Uses FIFO: debits since the credit was added are attributed first,
--    so only the truly remaining portion of that credit batch is expired.
CREATE OR REPLACE FUNCTION expire_wallet_credits()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  r                  RECORD;
  v_current_balance  numeric;
  v_credits_to_expire numeric;
  v_debits_since     numeric;
BEGIN
  FOR r IN
    SELECT wt.id           AS tx_id,
           wt.user_id,
           wt.amount       AS original_credits,
           wt.created_at   AS credited_at,
           wt.expires_at,
           wt.payment_id
    FROM   wallet_transactions wt
    WHERE  wt.type       = 'credit'
      AND  wt.expires_at IS NOT NULL
      AND  wt.expires_at <= now()
      AND  NOT EXISTS (
             SELECT 1 FROM wallet_transactions e
             WHERE  e.user_id      = wt.user_id
               AND  e.type         = 'expiry'
               AND  e.source_tx_id = wt.id
           )
    ORDER BY wt.expires_at
  LOOP
    -- Latest balance for this user
    SELECT COALESCE(balance_after, 0) INTO v_current_balance
    FROM   wallet_transactions
    WHERE  user_id = r.user_id
    ORDER  BY created_at DESC
    LIMIT  1;

    -- Debits (usage + prior expiries) that happened AFTER this credit was added
    SELECT COALESCE(SUM(amount), 0) INTO v_debits_since
    FROM   wallet_transactions
    WHERE  user_id    = r.user_id
      AND  type      IN ('debit', 'expiry')
      AND  created_at > r.credited_at;

    -- Credits still "live" from this batch = what wasn't consumed yet
    v_credits_to_expire := GREATEST(0, r.original_credits - v_debits_since);
    -- Safety: never deduct more than what's actually in the balance
    v_credits_to_expire := LEAST(v_credits_to_expire, v_current_balance);

    -- Always insert a marker row (amount = 0 when nothing left) so this
    -- tx is never re-scanned tomorrow
    INSERT INTO wallet_transactions (
      user_id, type, amount,
      balance_before, balance_after,
      description, source_tx_id
    ) VALUES (
      r.user_id,
      'expiry',
      v_credits_to_expire,
      v_current_balance,
      v_current_balance - v_credits_to_expire,
      'انتهاء صلاحية الكريدت — ' || COALESCE(r.payment_id::text, r.tx_id::text),
      r.tx_id
    );
  END LOOP;
END;
$$;

-- 6. Schedule: run every day at 01:00 UTC
--    Requires pg_cron extension (enabled by default on Supabase Pro).
--    If you get "extension cron does not exist", enable it first:
--      CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.unschedule('expire-wallet-credits-daily');  -- drop old if re-running
SELECT cron.schedule(
  'expire-wallet-credits-daily',
  '0 1 * * *',
  'SELECT expire_wallet_credits()'
);
