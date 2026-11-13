-- 20261115010000_admin_approve_payment_and_permissions.sql
--
-- 1. Payments that the automatic check (verify-sms, verify-easykash, crypto verifiers) could not match
--    are approved by an admin. The approval activates the slots through the same path as confirm_topup().
--    Before this, the admin button only wrote a legacy wallet credit, so no slots were granted.
--
-- 2. Writes that were only checked with is_admin() now also need the matching permission.

-- 1) Admin approval of a payment the automatic check could not match (wrong amount, not found, sheet down).
--    The transfer reference is claimed in processed_payment_refs first, the same way confirm_topup() does,
--    so a reference already used by another payment can never grant slots again.
CREATE OR REPLACE FUNCTION public.admin_approve_payment(p_payment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_pay     payments%ROWTYPE;
  v_pkg     uuid;
  v_grant   uuid;
  v_claimed integer;
BEGIN
  IF NOT public.has_permission('manage_credits') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  SELECT * INTO v_pay FROM payments WHERE id = p_payment_id AND status = 'pending' FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_PENDING');
  END IF;

  -- Claim the transfer reference (or a manual key when there is none). Nothing is written yet if it is taken.
  INSERT INTO processed_payment_refs (gateway, provider_ref, payment_id)
  VALUES (v_pay.gateway, COALESCE(v_pay.transaction_id, 'admin:' || v_pay.id::text), v_pay.id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'REFERENCE_ALREADY_USED');
  END IF;

  SELECT sp.id INTO v_pkg
  FROM slot_packages sp
  WHERE sp.legacy_pack_id = v_pay.pack_id OR sp.id::text = v_pay.pack_id
  LIMIT 1;
  IF v_pkg IS NULL THEN
    RAISE EXCEPTION 'PACKAGE_NOT_FOUND';   -- raises: the reference claim and everything else roll back
  END IF;

  UPDATE payments SET status = 'completed', verified_at = now() WHERE id = p_payment_id;

  -- Same as confirm_topup(): validity counts from the purchase time.
  v_grant := grant_slots(v_pay.user_id, v_pkg, 'purchase', v_pay.id::text, v_pay.created_at);

  RETURN jsonb_build_object('ok', true, 'grantId', v_grant);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_approve_payment(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_approve_payment(uuid) TO authenticated;

-- 2) Permission-based write checks.
-- wallet_transactions: the admin dashboard no longer writes here directly (approval uses the RPC above).
DROP POLICY IF EXISTS "Admins insert wallet_transactions" ON public.wallet_transactions;
CREATE POLICY "Admins insert wallet_transactions" ON public.wallet_transactions
  FOR INSERT TO public
  WITH CHECK (public.has_permission('manage_credits'));

-- slot_packages: managing packages needs manage_credits.
DROP POLICY IF EXISTS "admins manage packages" ON public.slot_packages;
CREATE POLICY "admins manage packages" ON public.slot_packages
  FOR ALL TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.has_permission('manage_credits'));

-- check_settings: the service on/off and processing mode need manage_settings.
DROP POLICY IF EXISTS "Admins update check_settings" ON public.check_settings;
CREATE POLICY "Admins update check_settings" ON public.check_settings
  FOR UPDATE TO public
  USING (public.is_admin())
  WITH CHECK (public.has_permission('manage_settings'));

-- ui_config: texts, icons and colours need manage_ui_design.
DROP POLICY IF EXISTS "Admins can update ui_config" ON public.ui_config;
CREATE POLICY "Admins can update ui_config" ON public.ui_config
  FOR UPDATE TO public
  USING (public.is_admin())
  WITH CHECK (public.has_permission('manage_ui_design'));
