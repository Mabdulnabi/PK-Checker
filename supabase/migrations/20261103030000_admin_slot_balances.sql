-- Admin view of every customer's remaining slots (plag + AI and plag only).
CREATE OR REPLACE FUNCTION public.admin_slot_balances()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE WHEN NOT is_admin() THEN '[]'::jsonb ELSE COALESCE((
    SELECT jsonb_agg(jsonb_build_object('user_id', b.user_id, 'plag_ai', b.plag_ai, 'plag_only', b.plag_only))
    FROM (
      SELECT g.user_id,
             COALESCE(SUM(GREATEST(0, g.slots_total - COALESCE(u.used, 0))) FILTER (WHERE g.slot_type = 'plag_ai' AND (g.expires_at IS NULL OR g.expires_at > now())), 0)::int AS plag_ai,
             COALESCE(SUM(GREATEST(0, g.slots_total - COALESCE(u.used, 0))) FILTER (WHERE g.slot_type = 'plag_only' AND (g.expires_at IS NULL OR g.expires_at > now())), 0)::int AS plag_only
      FROM customer_slot_grants g
      LEFT JOIN LATERAL (
        SELECT count(*)::int AS used FROM slot_usages su WHERE su.grant_id = g.id AND su.status = 'reserved'
      ) u ON true
      GROUP BY g.user_id
    ) b
  ), '[]'::jsonb) END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_slot_balances() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_slot_balances() TO authenticated;
