-- Admin adds checks by count, without choosing a package.
-- Validity follows the slot validity switch: lifetime when the switch is off, 30 days when it is on.

CREATE OR REPLACE FUNCTION public.admin_grant_checks(p_user_id uuid, p_count integer, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_timed boolean;
  v_exp   timestamptz;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_count IS NULL OR p_count < 1 THEN RAISE EXCEPTION 'INVALID_COUNT'; END IF;

  v_timed := COALESCE((SELECT cs.slot_expiry_enabled FROM check_settings cs ORDER BY cs.id LIMIT 1), true);
  v_exp := CASE WHEN v_timed THEN now() + interval '30 days' ELSE NULL END;

  INSERT INTO customer_slot_grants (user_id, package_id, slot_type, slots_total, granted_at, expires_at, source, source_ref)
  VALUES (p_user_id, NULL, 'plag_ai', p_count, now(), v_exp, 'admin', gen_random_uuid()::text);

  INSERT INTO admin_slot_adjustments (user_id, admin_id, action, slot_type, slots, note)
  VALUES (p_user_id, auth.uid(), 'add_checks', 'plag_ai', p_count, p_note);

  RETURN jsonb_build_object('ok', true, 'slots', p_count);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_grant_checks(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_grant_checks(uuid, integer, text) TO authenticated;
