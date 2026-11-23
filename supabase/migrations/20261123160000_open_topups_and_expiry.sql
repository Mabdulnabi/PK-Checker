-- 1) The customer's unfinished top-up, kept on the account (not only in one browser), so it can be
--    finished from the phone or the computer: package, payment method, transfer reference (PKC-…)
--    and the pending payment made for it. One per customer; only they can read or change it.
CREATE TABLE IF NOT EXISTS public.open_topups (
  user_id     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  pack_id     text NOT NULL,
  tab         text NOT NULL DEFAULT 'topup',
  gateway     text,
  pay_ref     text,
  pay_id      uuid,
  row_id      uuid,
  row_gateway text,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.open_topups ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "own open top-up" ON public.open_topups;
CREATE POLICY "own open top-up" ON public.open_topups
  FOR ALL TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- 2) Every hour: a pending top-up with no transaction number after 24 hours is closed (expired),
--    and unfinished top-ups older than 24 hours are forgotten. Payments that have a transaction
--    number are never touched (they wait for review).
CREATE OR REPLACE FUNCTION public.expire_abandoned_topups()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE n integer;
BEGIN
  UPDATE payments
     SET status = 'expired', failure_reason = 'expired: no transaction number after 24 hours', updated_at = now()
   WHERE status = 'pending'
     AND coalesce(transaction_id, '') = ''
     AND created_at < now() - interval '24 hours';
  GET DIAGNOSTICS n = ROW_COUNT;
  DELETE FROM open_topups WHERE updated_at < now() - interval '24 hours';
  RETURN n;
END;
$function$;
REVOKE ALL ON FUNCTION public.expire_abandoned_topups() FROM PUBLIC, anon, authenticated;

SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'expire-abandoned-topups';
SELECT cron.schedule('expire-abandoned-topups', '17 * * * *', $$ SELECT public.expire_abandoned_topups(); $$);
