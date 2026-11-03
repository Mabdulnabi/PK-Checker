-- Admin balance adjustments by package (slots), with a log of every adjustment.

CREATE TABLE IF NOT EXISTS public.admin_slot_adjustments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at  timestamptz NOT NULL DEFAULT now(),
  user_id     uuid NOT NULL,
  admin_id    uuid,
  action      text NOT NULL CHECK (action IN ('add_package', 'deduct_slots')),
  slot_type   text,
  slots       integer NOT NULL,
  package_id  uuid,
  note        text
);

ALTER TABLE public.admin_slot_adjustments ENABLE ROW LEVEL SECURITY;
CREATE POLICY admin_slot_adjustments_read ON public.admin_slot_adjustments
  FOR SELECT TO authenticated USING (is_admin());

-- Add N copies of a package to a customer.
CREATE OR REPLACE FUNCTION public.admin_grant_package(p_user_id uuid, p_package_id uuid, p_count integer, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pkg   slot_packages%ROWTYPE;
  v_i     integer;
  v_grant uuid;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_count IS NULL OR p_count < 1 THEN RAISE EXCEPTION 'INVALID_COUNT'; END IF;
  SELECT * INTO v_pkg FROM slot_packages WHERE id = p_package_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PACKAGE_NOT_FOUND'; END IF;
  FOR v_i IN 1..p_count LOOP
    v_grant := grant_slots(p_user_id, p_package_id, 'admin', gen_random_uuid()::text, now());
  END LOOP;
  INSERT INTO admin_slot_adjustments (user_id, admin_id, action, slot_type, slots, package_id, note)
  VALUES (p_user_id, auth.uid(), 'add_package', v_pkg.slot_type, v_pkg.slots * p_count, p_package_id, p_note);
  RETURN jsonb_build_object('ok', true, 'slots', v_pkg.slots * p_count);
END;
$$;

-- Remove slots of one type from a customer (oldest expiry first). Each removed slot is
-- a reservation without an order, so the balance, the history and the revenue follow it.
CREATE OR REPLACE FUNCTION public.admin_deduct_slots(p_user_id uuid, p_slot_type text, p_count integer, p_note text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  g       record;
  v_need  integer := p_count;
  v_left  integer;
  v_i     integer;
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_count IS NULL OR p_count < 1 THEN RAISE EXCEPTION 'INVALID_COUNT'; END IF;
  FOR g IN
    SELECT gr.id, gr.slot_type,
           gr.slots_total - (SELECT count(*) FROM slot_usages u WHERE u.grant_id = gr.id AND u.status = 'reserved') AS remaining
    FROM customer_slot_grants gr
    WHERE gr.user_id = p_user_id AND gr.slot_type = p_slot_type
      AND (gr.expires_at IS NULL OR gr.expires_at > now())
    ORDER BY gr.expires_at ASC NULLS LAST, gr.granted_at
  LOOP
    EXIT WHEN v_need <= 0;
    v_left := LEAST(g.remaining, v_need);
    FOR v_i IN 1..v_left LOOP
      INSERT INTO slot_usages (user_id, grant_id, slot_type, order_id, idempotency_key, status)
      VALUES (p_user_id, g.id, g.slot_type, NULL, 'admin-deduct:' || gen_random_uuid()::text, 'reserved');
    END LOOP;
    v_need := v_need - v_left;
  END LOOP;
  IF v_need > 0 THEN RAISE EXCEPTION 'NOT_ENOUGH_SLOTS'; END IF;

  INSERT INTO admin_slot_adjustments (user_id, admin_id, action, slot_type, slots, note)
  VALUES (p_user_id, auth.uid(), 'deduct_slots', p_slot_type, p_count, p_note);
  RETURN jsonb_build_object('ok', true, 'slots', p_count);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_grant_package(uuid, uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_grant_package(uuid, uuid, integer, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_deduct_slots(uuid, text, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_deduct_slots(uuid, text, integer, text) TO authenticated;
