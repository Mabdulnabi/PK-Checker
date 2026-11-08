-- Admin extends one purchase to a later end date. Only later dates are accepted; lifetime purchases are not extended.
ALTER TABLE public.admin_slot_adjustments DROP CONSTRAINT IF EXISTS admin_slot_adjustments_action_check;
ALTER TABLE public.admin_slot_adjustments ADD CONSTRAINT admin_slot_adjustments_action_check
  CHECK (action = ANY (ARRAY['add_package'::text, 'deduct_slots'::text, 'extend_grant'::text]));

CREATE OR REPLACE FUNCTION public.admin_extend_grant(p_grant_id uuid, p_new_expires timestamptz, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  g customer_slot_grants%ROWTYPE;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT * INTO g FROM customer_slot_grants WHERE id = p_grant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'GRANT_NOT_FOUND'; END IF;
  IF g.expires_at IS NULL THEN RAISE EXCEPTION 'LIFETIME_GRANT'; END IF;
  IF p_new_expires <= now() THEN RAISE EXCEPTION 'DATE_IN_PAST'; END IF;
  IF p_new_expires <= g.expires_at THEN RAISE EXCEPTION 'NOT_LATER_THAN_CURRENT'; END IF;

  UPDATE customer_slot_grants SET expires_at = p_new_expires WHERE id = g.id;

  INSERT INTO admin_slot_adjustments (user_id, admin_id, action, slot_type, slots, package_id, note)
  VALUES (g.user_id, auth.uid(), 'extend_grant', g.slot_type, 0, g.package_id,
          COALESCE(p_note || ' | ', '') || 'من ' || to_char(g.expires_at, 'YYYY-MM-DD HH24:MI') || ' إلى ' || to_char(p_new_expires, 'YYYY-MM-DD HH24:MI'));

  RETURN jsonb_build_object('ok', true, 'expires_at', p_new_expires);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_extend_grant(uuid, timestamptz, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_extend_grant(uuid, timestamptz, text) TO authenticated;
