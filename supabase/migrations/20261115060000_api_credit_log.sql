-- 20261115060000_api_credit_log.sql
-- Provider (TurniScan) balance around every submission and every result, so a double charge
-- or a charge on a refused check can be traced per order.
-- Rows are written by the edge functions (service role). Admins can read them.

CREATE TABLE IF NOT EXISTS public.api_credit_log (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  created_at     timestamptz NOT NULL DEFAULT now(),
  order_id       uuid REFERENCES public.orders(id) ON DELETE SET NULL,
  event          text NOT NULL,            -- submit | completed | failed
  api_before     numeric,
  api_after      numeric,
  api_delta      numeric,                  -- api_after - api_before
  slots_reserved integer,                  -- our reserved slots for the order at logging time
  note           text
);

CREATE INDEX IF NOT EXISTS api_credit_log_created_idx ON public.api_credit_log (created_at DESC);
CREATE INDEX IF NOT EXISTS api_credit_log_order_idx ON public.api_credit_log (order_id);

ALTER TABLE public.api_credit_log ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read api_credit_log" ON public.api_credit_log;
CREATE POLICY "Admins read api_credit_log" ON public.api_credit_log
  FOR SELECT TO authenticated
  USING (public.is_admin());

REVOKE ALL ON public.api_credit_log FROM anon, authenticated;
GRANT SELECT ON public.api_credit_log TO authenticated;
