-- Rejecting an order gives its slot back (the slot reserved for that order is released).
-- Idempotent: releasing an already released slot does nothing.
CREATE OR REPLACE FUNCTION public.admin_refund_order_slot(p_order_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  RETURN release_slot('order:' || p_order_id::text);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_refund_order_slot(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_refund_order_slot(uuid) TO authenticated;
