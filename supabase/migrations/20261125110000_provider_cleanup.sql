-- 1) "Exclude in-text citations" kept on the order, so a file sent later from the queue keeps the filter.
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS exclude_citations boolean NOT NULL DEFAULT false;

-- 2) The file is removed from TurniScan (POST /v1/scan/delete) once its reports are stored here:
--    when the customer deletes it, or 2.5 hours after completion (after the AI Highlights retries).
--    TurniScan itself deletes after 24 hours, so older files are not tried.
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS provider_deleted_at timestamptz;

CREATE OR REPLACE FUNCTION public.orders_due_provider_delete()
RETURNS TABLE(id uuid, external_order_id text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT o.id, o.external_order_id FROM orders o
  WHERE o.status = 'completed' AND o.provider_deleted_at IS NULL
    AND o.external_order_id IS NOT NULL AND o.report_url IS NOT NULL
    AND o.completed_at < now() - interval '150 minutes'
    AND o.completed_at > now() - interval '23 hours'
    AND NOT EXISTS (SELECT 1 FROM public.orders_waiting_highlights() w WHERE w.id = o.id)
  ORDER BY o.completed_at LIMIT 20;
$$;
REVOKE EXECUTE ON FUNCTION public.orders_due_provider_delete() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.orders_due_provider_delete() TO service_role;

-- The 15-minute job now does both: AI Highlights retries and the TurniScan cleanup.
SELECT cron.unschedule('fetch-ai-highlights') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'fetch-ai-highlights');
SELECT cron.schedule(
  'fetch-ai-highlights',
  '*/15 * * * *',
  $$ SELECT net.http_post(
       url := 'https://ixpgqhwausnfjphitsty.supabase.co/functions/v1/turnitin-webhook',
       headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', public.get_internal_cron_secret()),
       body := '{"action": "highlights_sweep"}'::jsonb,
       timeout_milliseconds := 120000
     )
     WHERE EXISTS (SELECT 1 FROM public.orders_waiting_highlights())
        OR EXISTS (SELECT 1 FROM public.orders_due_provider_delete()); $$
);
