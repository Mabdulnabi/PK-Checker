-- My Files: include the order number (display_id) in the customer's files list.
CREATE OR REPLACE FUNCTION public.my_checked_files()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.submitted_at DESC), '[]'::jsonb)
  FROM (
    SELECT o.id,
           o.display_id,
           o.file_name,
           o.check_type,
           o.status,
           o.submitted_at,
           o.completed_at,
           o.similarity_score,
           o.ai_score,
           (o.report_url IS NOT NULL) AS has_sim_report,
           (o.ai_report_url IS NOT NULL) AS has_ai_report,
           o.error_reason,
           g.slot_type,
           p.name_ar,
           p.name_en
    FROM orders o
    LEFT JOIN LATERAL (
      SELECT u.grant_id FROM slot_usages u
      WHERE u.order_id = o.id AND u.user_id = o.user_id AND u.status = 'reserved'
      ORDER BY u.created_at LIMIT 1
    ) su ON true
    LEFT JOIN customer_slot_grants g ON g.id = su.grant_id
    LEFT JOIN slot_packages p ON p.id = g.package_id
    WHERE o.user_id = auth.uid()
      AND o.purged_at IS NULL
  ) x;
$$;

REVOKE EXECUTE ON FUNCTION public.my_checked_files() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_checked_files() TO authenticated;
