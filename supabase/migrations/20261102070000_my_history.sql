-- My History: summary cards and the account activity ledger for the customer.
-- Rows: slot grants (purchase / redeem / migration), payments not linked to a grant,
-- and every check (successful, failed, or still running).
CREATE OR REPLACE FUNCTION public.my_history()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
WITH grants AS (
  SELECT g.id, g.source, g.source_ref, g.slot_type, g.slots_total, g.granted_at, g.expires_at,
         (SELECT count(*) FROM slot_usages u WHERE u.grant_id = g.id AND u.status = 'reserved')::int AS used
  FROM customer_slot_grants g
  WHERE g.user_id = auth.uid()
),
ev_grants AS (
  SELECT 'grant'::text AS kind,
         g.granted_at AS at,
         g.slot_type,
         g.slots_total::int AS change,
         'completed'::text AS status,
         CASE WHEN g.source = 'purchase' THEN p.transaction_id
              WHEN g.source = 'redeem'   THEN r.code
              ELSE NULL END AS txn,
         NULL::text AS order_number,
         NULL::text AS file_name,
         NULL::text AS check_type,
         g.source,
         p.gateway,
         p.amount,
         p.currency
  FROM grants g
  LEFT JOIN payments p      ON g.source = 'purchase' AND p.id::text = g.source_ref
  LEFT JOIN redeem_codes r  ON g.source = 'redeem'   AND r.id::text = g.source_ref
),
ev_pay AS (
  SELECT 'purchase'::text AS kind,
         p.created_at AS at,
         NULL::text AS slot_type,
         0 AS change,
         CASE WHEN p.status = 'completed' THEN 'success'
              WHEN p.status = 'pending'   THEN 'pending'
              ELSE 'failed' END AS status,
         p.transaction_id AS txn,
         NULL::text AS order_number,
         NULL::text AS file_name,
         NULL::text AS check_type,
         'purchase'::text AS source,
         p.gateway,
         p.amount,
         p.currency
  FROM payments p
  WHERE p.user_id = auth.uid()
    AND NOT EXISTS (
      SELECT 1 FROM customer_slot_grants g
      WHERE g.source = 'purchase' AND g.source_ref = p.id::text
    )
),
ev_scan AS (
  SELECT 'scan'::text AS kind,
         o.submitted_at AS at,
         CASE WHEN o.check_type = 'sim_only' THEN 'plag_only' ELSE 'plag_ai' END AS slot_type,
         -(SELECT count(*) FROM slot_usages u
           WHERE u.order_id = o.id AND u.user_id = o.user_id AND u.status = 'reserved')::int AS change,
         CASE WHEN o.status = 'completed' THEN 'completed'
              WHEN o.status IN ('error', 'rejected', 'failed_invalid', 'cancelled') THEN 'failed'
              ELSE 'checking' END AS status,
         NULL::text AS txn,
         o.display_id AS order_number,
         o.file_name,
         o.check_type,
         'scan'::text AS source,
         NULL::text AS gateway,
         NULL::numeric AS amount,
         NULL::text AS currency
  FROM orders o
  WHERE o.user_id = auth.uid()
),
events AS (
  SELECT * FROM ev_grants
  UNION ALL SELECT * FROM ev_pay
  UNION ALL SELECT * FROM ev_scan
)
SELECT jsonb_build_object(
  'summary', jsonb_build_object(
    'available', (SELECT COALESCE(sum(GREATEST(0, slots_total - used)), 0)::int FROM grants
                  WHERE expires_at IS NULL OR expires_at > now()),
    'total_added', (SELECT COALESCE(sum(slots_total), 0)::int FROM grants),
    'checked_ok', (SELECT count(*)::int FROM orders WHERE user_id = auth.uid() AND status = 'completed'),
    'next_expiry', (SELECT min(expires_at) FROM grants
                    WHERE expires_at > now() AND slots_total - used > 0)
  ),
  'events', COALESCE((
    SELECT jsonb_agg(to_jsonb(e) ORDER BY e.at DESC NULLS LAST)
    FROM events e
  ), '[]'::jsonb)
);
$$;

REVOKE EXECUTE ON FUNCTION public.my_history() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_history() TO authenticated;
