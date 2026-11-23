-- Queue refinements:
--  * queue_attempt_at: the queue claims an order with this timestamp while it tries to send it, so the
--    order stays 'queued' the whole time (the customer sees "Queued" without flicker).
--  * My Files gets sent_at, so "Checking" counts from when TurniScan accepted the file.
--  * The queue runs every 30 seconds (a send can take a while for large files).
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS queue_attempt_at timestamptz;

CREATE OR REPLACE FUNCTION public.my_checked_files()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.submitted_at DESC), '[]'::jsonb)
  FROM (
    SELECT o.id,
           o.display_id,
           o.file_name,
           o.check_type,
           o.status,
           o.submitted_at,
           o.sent_at,
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
$function$;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'process-check-queue';
SELECT cron.schedule('process-check-queue', '30 seconds', $$
  SELECT net.http_post(
    url := 'https://ixpgqhwausnfjphitsty.supabase.co/functions/v1/submit-check',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', public.get_internal_cron_secret()),
    body := '{"action":"process_queue"}'::jsonb,
    timeout_milliseconds := 150000
  )
  WHERE EXISTS (SELECT 1 FROM public.orders WHERE status = 'queued');
$$);
