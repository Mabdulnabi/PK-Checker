-- 20261115010000_admin_approve_payment_and_permissions.sql
--
-- 1. Manual payments (InstaPay, Vodafone Cash, ...) need an admin approval, and the approval
--    must activate the slots exactly like an automatic gateway does through confirm_topup().
--    Before this, the admin button only wrote a legacy wallet credit, so no slots were granted.
--    admin_approve_payment() claims the payment (pending -> completed) and grants the slots
--    in one transaction: if the grant fails, the claim is rolled back too.
--
-- 2. Writes that were only checked with is_admin() now also need the matching permission.

-- 1) Admin approval of a manual payment: claims it and grants its slots.
CREATE OR REPLACE FUNCTION public.admin_approve_payment(p_payment_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_pay   payments%ROWTYPE;
  v_pkg   uuid;
  v_grant uuid;
BEGIN
  IF NOT public.has_permission('manage_credits') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  -- Atomic claim: only a pending payment can be approved, so a second click or a stale list does nothing.
  UPDATE payments
  SET status = 'completed', verified_at = now()
  WHERE id = p_payment_id AND status = 'pending'
  RETURNING * INTO v_pay;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'NOT_PENDING');
  END IF;

  SELECT sp.id INTO v_pkg
  FROM slot_packages sp
  WHERE sp.legacy_pack_id = v_pay.pack_id OR sp.id::text = v_pay.pack_id
  LIMIT 1;
  IF v_pkg IS NULL THEN
    RAISE EXCEPTION 'PACKAGE_NOT_FOUND';   -- raises: the claim above is rolled back as well
  END IF;

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
