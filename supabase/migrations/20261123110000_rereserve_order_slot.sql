-- Used by submit-check when an admin resends a failed order: the order's slot, given back when it
-- failed, is taken again from the customer's balance (its own package first, then the one expiring
-- soonest). Returns 'reserved', 'already' (still held) or 'no_slot'. Service role only.
CREATE OR REPLACE FUNCTION public.rereserve_order_slot(p_order_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_usage slot_usages%ROWTYPE;
  v_grant uuid;
BEGIN
  SELECT * INTO v_usage FROM slot_usages WHERE idempotency_key = 'order:' || p_order_id::text FOR UPDATE;
  IF NOT FOUND THEN RETURN 'none'; END IF;
  IF v_usage.status = 'reserved' THEN RETURN 'already'; END IF;

  SELECT g.id INTO v_grant
    FROM customer_slot_grants g
   WHERE g.user_id = v_usage.user_id AND g.slot_type = v_usage.slot_type
     AND (g.expires_at IS NULL OR g.expires_at > now())
     AND g.slots_total > (SELECT count(*) FROM slot_usages u WHERE u.grant_id = g.id AND u.status = 'reserved')
   ORDER BY (g.id = v_usage.grant_id) DESC, g.expires_at ASC NULLS LAST, g.granted_at ASC
   LIMIT 1
   FOR UPDATE OF g;
  IF v_grant IS NULL THEN RETURN 'no_slot'; END IF;

  UPDATE slot_usages SET status = 'reserved', grant_id = v_grant, updated_at = now() WHERE id = v_usage.id;
  RETURN 'reserved';
END;
$function$;
REVOKE ALL ON FUNCTION public.rereserve_order_slot(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.rereserve_order_slot(uuid) TO service_role;
