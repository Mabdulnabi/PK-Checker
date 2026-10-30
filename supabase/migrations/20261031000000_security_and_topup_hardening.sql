-- ============================================================
-- Security hardening + atomic top-up confirmation
--   1. Remove anonymous/PUBLIC EXECUTE on every public function
--   2. Keep is_admin/has_permission callable (RLS policies need them)
--   3. Remove EXECUTE from authenticated for cron-only and trigger functions
--   4. Admin-only checks inside broadcast and backup RPCs
--   5. Fixed search_path on functions that lacked one
--   6. confirm_topup(): one transaction for ref-claim + credit + payment update
--   7. redeem_code(): rate limit on failed attempts (returns errors, no raise)
-- ============================================================

-- 1 + 2. Lock down the RPC surface
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon;
GRANT  EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated, service_role;
GRANT  EXECUTE ON FUNCTION public.is_admin() TO anon;
GRANT  EXECUTE ON FUNCTION public.has_permission(text) TO anon;

-- 3. Cron-only and trigger functions: nobody signed-in should call these directly
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('auto_reject_stuck_orders','check_stuck_orders','expire_old_pending_payments',
                        'expire_wallet_credits','prune_old_credit_backups','cleanup_expired_order_source_files')
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', r.sig);
  END LOOP;

  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prorettype = 'trigger'::regtype
  LOOP
    EXECUTE format('REVOKE EXECUTE ON FUNCTION %s FROM authenticated', r.sig);
  END LOOP;
END $$;

-- 4a. Broadcast management: admins only
CREATE OR REPLACE FUNCTION public.admin_update_broadcast(p_broadcast_id bigint, p_title_ar text, p_title_en text, p_body_ar text, p_body_en text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_old_title_ar text;
  v_uid uuid;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;

  SELECT title_ar INTO v_old_title_ar FROM broadcast_messages WHERE id = p_broadcast_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'broadcast not found'; END IF;

  UPDATE broadcast_messages
  SET title_ar = p_title_ar, title_en = p_title_en,
      body_ar  = p_body_ar,  body_en  = p_body_en
  WHERE id = p_broadcast_id;

  FOR v_uid IN
    SELECT user_id FROM notifications
    WHERE type = 'broadcast' AND title_ar = v_old_title_ar
  LOOP
    DELETE FROM notifications
    WHERE type = 'broadcast' AND title_ar = v_old_title_ar AND user_id = v_uid;

    INSERT INTO notifications (user_id, type, title_ar, title_en, body_ar, body_en, is_read)
    VALUES (v_uid, 'broadcast', p_title_ar, p_title_en, p_body_ar, p_body_en, false);
  END LOOP;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_delete_broadcast(p_broadcast_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_title_ar text;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;

  SELECT title_ar INTO v_title_ar FROM broadcast_messages WHERE id = p_broadcast_id;
  IF NOT FOUND THEN RETURN; END IF;
  DELETE FROM notifications WHERE type = 'broadcast' AND title_ar = v_title_ar;
  DELETE FROM broadcast_messages WHERE id = p_broadcast_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_toggle_broadcast_visibility(p_broadcast_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_row broadcast_messages%ROWTYPE;
  v_new_hidden boolean;
  v_uid uuid;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;

  SELECT * INTO v_row FROM broadcast_messages WHERE id = p_broadcast_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('error','not found'); END IF;

  v_new_hidden := NOT v_row.is_hidden;
  UPDATE broadcast_messages SET is_hidden = v_new_hidden WHERE id = p_broadcast_id;

  IF v_new_hidden THEN
    DELETE FROM notifications
    WHERE type = 'broadcast'
      AND title_ar = v_row.title_ar;
  ELSE
    FOR v_uid IN
      SELECT user_id FROM users_profile
      WHERE NOT EXISTS (
        SELECT 1 FROM notifications n
        WHERE n.user_id = users_profile.user_id
          AND n.type = 'broadcast'
          AND n.title_ar = v_row.title_ar
      )
    LOOP
      INSERT INTO notifications (user_id, type, title_ar, title_en, body_ar, body_en, is_read)
      VALUES (v_uid, 'broadcast', v_row.title_ar, v_row.title_en, v_row.body_ar, v_row.body_en, false);
    END LOOP;
  END IF;

  RETURN jsonb_build_object('is_hidden', v_new_hidden);
END;
$function$;

-- 4b. Backups: cron (no auth.uid) and admins only
CREATE OR REPLACE FUNCTION public.backup_credits_now(p_type text DEFAULT 'auto'::text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_snapshot jsonb;
  v_count integer;
  v_id uuid;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;

  SELECT jsonb_build_object(
    'wallet_transactions', COALESCE(jsonb_agg(to_jsonb(wt)), '[]'::jsonb)
  ), count(*)
  INTO v_snapshot, v_count
  FROM wallet_transactions wt;

  INSERT INTO credit_backups (backup_type, snapshot, row_count, created_by)
  VALUES (p_type, v_snapshot, v_count, current_setting('request.jwt.claims', true)::json->>'email')
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.cleanup_old_credit_backups()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_count int;
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;

  DELETE FROM credit_backups WHERE created_at < NOW() - INTERVAL '14 days';
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$function$;

-- 5. Fixed search_path on functions that lacked one
DO $$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS sig
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proconfig IS NULL AND p.prokind = 'f'
      AND p.proname IN ('generate_order_display_id','gen_tx_code','assign_pk_number',
                        'notify_admin_wallet_topup','notify_admin_new_order','notify_admin_order_completed',
                        'notify_admin_new_user','lock_order_rating_after_set',
                        'auto_reject_stuck_orders','expire_old_pending_payments')
  LOOP
    EXECUTE format('ALTER FUNCTION %s SET search_path = public, extensions, pg_temp', r.sig);
  END LOOP;
END $$;

-- 6. Atomic top-up confirmation (service_role only, called by verify-* edge functions)
CREATE OR REPLACE FUNCTION public.confirm_topup(
  p_user_id uuid, p_payment_id uuid, p_credits integer, p_gateway text, p_provider_ref text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_claimed integer;
  v_before numeric;
  v_after numeric;
BEGIN
  -- Claim the provider reference first. A duplicate returns alreadyProcessed
  -- without touching the wallet.
  INSERT INTO processed_payment_refs (gateway, provider_ref, payment_id)
  VALUES (p_gateway, p_provider_ref, p_payment_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN jsonb_build_object('ok', false, 'alreadyProcessed', true,
                              'error', 'This transaction was already processed');
  END IF;

  -- Serialise credits per user so two confirmations can't read the same balance.
  PERFORM 1 FROM users_profile WHERE user_id = p_user_id FOR UPDATE;

  SELECT balance_after INTO v_before
  FROM wallet_transactions
  WHERE user_id = p_user_id
  ORDER BY created_at DESC
  LIMIT 1;
  v_before := COALESCE(v_before, 0);
  v_after  := v_before + p_credits;

  INSERT INTO wallet_transactions (user_id, type, amount, balance_before, balance_after, description)
  VALUES (p_user_id, 'credit', p_credits, v_before, v_after, 'شحن رصيد — ' || p_gateway);

  UPDATE payments
  SET status = 'completed', verified_at = now(), transaction_id = p_provider_ref
  WHERE id = p_payment_id;

  RETURN jsonb_build_object('ok', true, 'newBalance', v_after);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.confirm_topup(uuid, uuid, integer, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.confirm_topup(uuid, uuid, integer, text, text) TO service_role;

-- 7. Redeem attempts: rate limit on failures (per user, 15-minute window)
CREATE TABLE IF NOT EXISTS public.redeem_attempts (
  id           bigint generated always as identity primary key,
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  attempted_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.redeem_attempts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.redeem_attempts FROM anon, authenticated;

CREATE OR REPLACE FUNCTION public.redeem_code(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid := auth.uid();
  v_norm           text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_credits        integer;
  v_recent_fails   integer;
  v_balance_before numeric;
  v_balance_after  numeric;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  SELECT count(*) INTO v_recent_fails
  FROM redeem_attempts
  WHERE user_id = v_uid AND attempted_at > now() - interval '15 minutes';
  IF v_recent_fails >= 5 THEN
    RETURN jsonb_build_object('error', 'TOO_MANY_ATTEMPTS');
  END IF;

  IF length(v_norm) <> 16 THEN
    INSERT INTO redeem_attempts (user_id) VALUES (v_uid);
    RETURN jsonb_build_object('error', 'INVALID_CODE');
  END IF;

  UPDATE redeem_codes
     SET redeemed_by = v_uid, redeemed_at = now()
   WHERE replace(code, '-', '') = v_norm
     AND redeemed_at IS NULL
  RETURNING credits INTO v_credits;

  IF v_credits IS NULL THEN
    INSERT INTO redeem_attempts (user_id) VALUES (v_uid);
    IF EXISTS (SELECT 1 FROM redeem_codes WHERE replace(code, '-', '') = v_norm) THEN
      RETURN jsonb_build_object('error', 'CODE_ALREADY_USED');
    END IF;
    RETURN jsonb_build_object('error', 'INVALID_CODE');
  END IF;

  PERFORM 1 FROM users_profile WHERE user_id = v_uid FOR UPDATE;

  SELECT balance_after INTO v_balance_before
  FROM wallet_transactions
  WHERE user_id = v_uid
  ORDER BY created_at DESC
  LIMIT 1;
  v_balance_before := COALESCE(v_balance_before, 0);
  v_balance_after  := v_balance_before + v_credits;

  INSERT INTO wallet_transactions (user_id, type, amount, balance_before, balance_after, description)
  VALUES (v_uid, 'credit', v_credits, v_balance_before, v_balance_after, 'كود خصم');

  RETURN jsonb_build_object('credits', v_credits, 'balance_after', v_balance_after);
END;
$function$;

-- 8. Vault secret readers: service_role only (edge functions read them with the service key).
--    get_payment_api_secret had no caller check, so any signed-in user could read API keys.
REVOKE EXECUTE ON FUNCTION public.get_payment_api_secret(text) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.get_resend_api_key() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.get_payment_api_secret(text) TO service_role;
GRANT  EXECUTE ON FUNCTION public.get_resend_api_key() TO service_role;
