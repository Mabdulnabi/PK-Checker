-- Admin adjustments on one specific purchase of a customer (a grant), so a manual fix lands on the
-- same package the customer used. Adding back keeps the purchase's package and end date.

CREATE OR REPLACE FUNCTION public.admin_customer_grants(p_user_id uuid)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT CASE WHEN NOT is_admin() THEN '[]'::jsonb ELSE COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'grant_id', g.id,
      'slot_type', g.slot_type,
      'package', COALESCE(p.name_ar, 'باقة'),
      'slots_total', g.slots_total,
      'remaining', GREATEST(0, g.slots_total - COALESCE(u.used, 0)),
      'granted_at', g.granted_at,
      'expires_at', g.expires_at
    ) ORDER BY g.granted_at DESC)
    FROM customer_slot_grants g
    LEFT JOIN slot_packages p ON p.id = g.package_id
    LEFT JOIN LATERAL (
      SELECT count(*)::int AS used FROM slot_usages su WHERE su.grant_id = g.id AND su.status = 'reserved'
    ) u ON true
    WHERE g.user_id = p_user_id
  ), '[]'::jsonb) END;
$$;

REVOKE ALL ON FUNCTION public.admin_customer_grants(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_customer_grants(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_deduct_from_grant(p_grant_id uuid, p_count integer, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  g       customer_slot_grants%ROWTYPE;
  v_used  integer;
  v_i     integer;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_count IS NULL OR p_count < 1 THEN RAISE EXCEPTION 'INVALID_COUNT'; END IF;
  SELECT * INTO g FROM customer_slot_grants WHERE id = p_grant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GRANT_NOT_FOUND'; END IF;
  SELECT count(*) INTO v_used FROM slot_usages u WHERE u.grant_id = g.id AND u.status = 'reserved';
  IF g.slots_total - v_used < p_count THEN RAISE EXCEPTION 'NOT_ENOUGH_SLOTS'; END IF;
  FOR v_i IN 1..p_count LOOP
    INSERT INTO slot_usages (user_id, grant_id, slot_type, order_id, idempotency_key, status)
    VALUES (g.user_id, g.id, g.slot_type, NULL, 'admin-deduct:' || gen_random_uuid()::text, 'reserved');
  END LOOP;
  INSERT INTO admin_slot_adjustments (user_id, admin_id, action, slot_type, slots, package_id, note)
  VALUES (g.user_id, auth.uid(), 'deduct_slots', g.slot_type, p_count, g.package_id, p_note);
  RETURN jsonb_build_object('ok', true, 'slots', p_count);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_deduct_from_grant(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_deduct_from_grant(uuid, integer, text) TO authenticated;

CREATE OR REPLACE FUNCTION public.admin_add_to_grant(p_grant_id uuid, p_count integer, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  g    customer_slot_grants%ROWTYPE;
  v_id uuid;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_count IS NULL OR p_count < 1 THEN RAISE EXCEPTION 'INVALID_COUNT'; END IF;
  SELECT * INTO g FROM customer_slot_grants WHERE id = p_grant_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'GRANT_NOT_FOUND'; END IF;
  -- Same package, same end date as the purchase it is added to.
  INSERT INTO customer_slot_grants (user_id, package_id, slot_type, slots_total, granted_at, expires_at, source, source_ref)
  VALUES (g.user_id, g.package_id, g.slot_type, p_count, now(), g.expires_at, 'admin', gen_random_uuid()::text)
  RETURNING id INTO v_id;
  INSERT INTO admin_slot_adjustments (user_id, admin_id, action, slot_type, slots, package_id, note)
  VALUES (g.user_id, auth.uid(), 'add_package', g.slot_type, p_count, g.package_id, p_note);
  RETURN jsonb_build_object('ok', true, 'slots', p_count, 'grant_id', v_id);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_add_to_grant(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_add_to_grant(uuid, integer, text) TO authenticated;
