-- Packages are linked to payments by pack_key: the legacy id when there is one, otherwise the
-- package id. New packages work without a legacy id.
CREATE OR REPLACE FUNCTION public.list_slot_packages()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'pack_key', COALESCE(sp.legacy_pack_id, sp.id::text),
           'legacy_pack_id', sp.legacy_pack_id,
           'slots', sp.slots,
           'price_egp', sp.price_egp,
           'expiry_days', sp.expiry_days,
           'name_ar', sp.name_ar,
           'name_en', sp.name_en
         ) ORDER BY sp.sort_order), '[]'::jsonb)
  FROM slot_packages sp
  WHERE sp.is_active
    AND sp.slot_type = 'plag_ai';
$$;

REVOKE EXECUTE ON FUNCTION public.list_slot_packages() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_slot_packages() TO authenticated;

-- confirm_topup finds the package by legacy id, or by package id for new packages.
CREATE OR REPLACE FUNCTION public.confirm_topup(p_user_id uuid, p_payment_id uuid, p_credits integer, p_gateway text, p_provider_ref text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_claimed  integer;
  v_pay      payments%ROWTYPE;
  v_pkg_id   uuid;
  v_grant    uuid;
BEGIN
  INSERT INTO processed_payment_refs (gateway, provider_ref, payment_id)
  VALUES (p_gateway, p_provider_ref, p_payment_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN jsonb_build_object('ok', false, 'alreadyProcessed', true,
                              'error', 'This transaction was already processed');
  END IF;

  SELECT * INTO v_pay FROM payments WHERE id = p_payment_id AND user_id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_NOT_FOUND'; END IF;

  SELECT sp.id INTO v_pkg_id FROM slot_packages sp
  WHERE sp.legacy_pack_id = v_pay.pack_id OR sp.id::text = v_pay.pack_id
  LIMIT 1;
  IF v_pkg_id IS NULL THEN RAISE EXCEPTION 'PACKAGE_NOT_FOUND'; END IF;

  v_grant := grant_slots(p_user_id, v_pkg_id, 'purchase', p_payment_id::text, v_pay.created_at);

  UPDATE payments
  SET status = 'completed', verified_at = now(), transaction_id = p_provider_ref
  WHERE id = p_payment_id;

  RETURN jsonb_build_object('ok', true, 'grantId', v_grant);
END;
$function$;
