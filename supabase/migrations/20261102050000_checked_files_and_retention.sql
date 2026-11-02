-- Files list for the Check page, and the 48-hour retention rule.
-- A finished check's report files are deleted 48 hours after it finished.
-- The order row stays (billing history); its report files and paths are cleared
-- and purged_at is set, which hides it from the files list.

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS purged_at timestamptz;

-- Statuses that mean the check is finished (no more results coming).
-- The customer's list and the purge job both use this.
CREATE OR REPLACE FUNCTION public.orders_due_for_purge()
RETURNS TABLE(id uuid)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT o.id
  FROM orders o
  WHERE o.purged_at IS NULL
    AND o.status IN ('completed', 'error', 'rejected', 'failed_invalid', 'cancelled')
    AND COALESCE(o.completed_at, o.updated_at) < now() - interval '48 hours'
  LIMIT 200;
$$;

REVOKE EXECUTE ON FUNCTION public.orders_due_for_purge() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.orders_due_for_purge() TO service_role;

CREATE OR REPLACE FUNCTION public.mark_order_purged(p_order_id uuid)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  UPDATE orders
  SET purged_at = now(), report_url = NULL, ai_report_url = NULL, updated_at = now()
  WHERE id = p_order_id AND purged_at IS NULL;
$$;

REVOKE EXECUTE ON FUNCTION public.mark_order_purged(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_order_purged(uuid) TO service_role;

-- The customer's files, newest first. Each file carries the package it was
-- checked with (through its reserved slot) and the real scores from the provider.
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

-- Hourly purge: calls the manage-files edge function, which deletes the due files
-- from storage and marks the orders. The function only ever acts on rows that are
-- already past 48 hours, so it is safe to call from the scheduler.
SELECT cron.unschedule('purge-expired-order-files')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'purge-expired-order-files');

SELECT cron.schedule(
  'purge-expired-order-files',
  '20 * * * *',
  $$ SELECT net.http_post(
       url := 'https://ixpgqhwausnfjphitsty.supabase.co/functions/v1/manage-files',
       headers := '{"Content-Type": "application/json"}'::jsonb,
       body := '{"action": "purge_due"}'::jsonb
     ); $$
);
