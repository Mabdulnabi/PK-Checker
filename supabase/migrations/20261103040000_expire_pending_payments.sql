-- Pending payments that were not confirmed within one hour are closed as failed.
CREATE OR REPLACE FUNCTION public.expire_pending_payments()
RETURNS integer
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH closed AS (
    UPDATE payments
    SET status = 'failed', failure_reason = COALESCE(failure_reason, 'expired: not confirmed within 1 hour')
    WHERE status = 'pending' AND created_at < now() - interval '1 hour'
    RETURNING id
  )
  SELECT count(*)::int FROM closed;
$$;

REVOKE EXECUTE ON FUNCTION public.expire_pending_payments() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_pending_payments() TO service_role;

-- Runs every 10 minutes.
SELECT cron.unschedule('expire-pending-payments')
WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'expire-pending-payments');
SELECT cron.schedule('expire-pending-payments', '*/10 * * * *', $$ SELECT public.expire_pending_payments(); $$);
