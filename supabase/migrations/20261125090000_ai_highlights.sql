-- AI Highlights report (TurniScan: GET /v1/scan/download?report_type=highlights).
-- The customer asks for it when sending the file (orders.ai_highlights). Once the check is completed,
-- turnitin-webhook downloads it and stores it in order-reports/ai-highlights/<order>/ai_highlights.pdf.
-- Turnitin only produces it for some files (low AI score), so it may never come: the customer sees the
-- blue button only when the file was actually received (ai_highlights_url).
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS ai_highlights boolean NOT NULL DEFAULT false;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS ai_highlights_url text;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS ai_highlights_tries smallint NOT NULL DEFAULT 0;

-- Only the server writes the stored report path and the retry count, never the customer.
CREATE OR REPLACE FUNCTION public.guard_customer_order_highlights()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF auth.uid() IS NOT NULL AND NOT public.is_admin() THEN
    IF TG_OP = 'INSERT' THEN
      NEW.ai_highlights_url := NULL;
      NEW.ai_highlights_tries := 0;
    ELSIF NEW.ai_highlights_url IS DISTINCT FROM OLD.ai_highlights_url
       OR NEW.ai_highlights_tries IS DISTINCT FROM OLD.ai_highlights_tries
       OR NEW.ai_highlights IS DISTINCT FROM OLD.ai_highlights THEN
      RAISE EXCEPTION 'NOT_ALLOWED: this order field is read-only for customers';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_guard_customer_order_highlights ON public.orders;
CREATE TRIGGER trg_guard_customer_order_highlights
  BEFORE INSERT OR UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.guard_customer_order_highlights();

-- My Files: whether the highlights report is there.
DO $mig$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.my_checked_files'::regproc);
  IF position('has_ai_highlights' in d) = 0 THEN
    d := replace(d, '           (o.ai_report_url IS NOT NULL) AS has_ai_report,', '           (o.ai_report_url IS NOT NULL) AS has_ai_report,
           (o.ai_highlights_url IS NOT NULL) AS has_ai_highlights,');
    IF position('has_ai_highlights' in d) = 0 THEN RAISE EXCEPTION 'my_checked_files: expected text not found'; END IF;
    EXECUTE d;
  END IF;
END
$mig$;

-- The 48-hour purge clears the highlights path too (the file itself is removed by manage-files).
CREATE OR REPLACE FUNCTION public.mark_order_purged(p_order_id uuid)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = public
AS $$
  UPDATE orders
  SET purged_at = now(), report_url = NULL, ai_report_url = NULL, ai_highlights_url = NULL, updated_at = now()
  WHERE id = p_order_id AND purged_at IS NULL;
$$;
REVOKE EXECUTE ON FUNCTION public.mark_order_purged(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.mark_order_purged(uuid) TO service_role;

-- Completed checks still waiting for their highlights report: tried again every 15 minutes, up to 8 times,
-- while the reports are kept (48 hours). An AI score above 20% never gets one, so it is not tried.
CREATE OR REPLACE FUNCTION public.orders_waiting_highlights()
RETURNS TABLE(id uuid, external_order_id text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$
  SELECT o.id, o.external_order_id FROM orders o
  WHERE o.ai_highlights AND o.status = 'completed' AND o.ai_highlights_url IS NULL
    AND o.purged_at IS NULL AND o.external_order_id IS NOT NULL AND o.check_type <> 'sim_only'
    AND o.ai_highlights_tries < 8 AND (o.ai_score IS NULL OR o.ai_score <= 20)
    AND o.completed_at > now() - interval '47 hours'
  ORDER BY o.completed_at LIMIT 20;
$$;
REVOKE EXECUTE ON FUNCTION public.orders_waiting_highlights() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.orders_waiting_highlights() TO service_role;

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
     WHERE EXISTS (SELECT 1 FROM public.orders_waiting_highlights()); $$
);
