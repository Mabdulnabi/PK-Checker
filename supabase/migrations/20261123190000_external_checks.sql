-- External checks: checks the admin runs directly on TurniScan, outside the platform, entered by hand
-- (Revenue card "+"). They count in revenue, cost and profit (admin_sales_ledger, source 'external')
-- and touch no customer balance.
--   revenue = checks x unit_price, cost = checks x unit_cost (both in the row's currency; USD x 50 = EGP,
--   the rate the rest of the ledger uses).
-- A cancelled entry (cancelled_at set) stays stored but no longer counts. Rows are never deleted.
CREATE TABLE IF NOT EXISTS public.external_checks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  at           timestamptz NOT NULL DEFAULT now(),        -- when the checks were done
  checks       integer NOT NULL CHECK (checks > 0),
  check_type   text NOT NULL DEFAULT 'sim_ai' CHECK (check_type IN ('sim_ai', 'sim_only')),
  currency     text NOT NULL DEFAULT 'EGP' CHECK (currency IN ('EGP', 'USD')),
  unit_price   numeric(12,2) NOT NULL CHECK (unit_price >= 0),   -- sale price of one check
  unit_cost    numeric(12,4) NOT NULL CHECK (unit_cost >= 0),    -- external (TurniScan) price of one check
  customer     text,
  pay_method   text,
  reference    text,
  ts_file_id   text,
  note         text,
  created_by   uuid DEFAULT auth.uid(),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  cancelled_at timestamptz,
  cancelled_by uuid
);

ALTER TABLE public.external_checks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS external_checks_admin_read ON public.external_checks;
CREATE POLICY external_checks_admin_read ON public.external_checks
  FOR SELECT TO authenticated USING (public.is_admin());
DROP POLICY IF EXISTS external_checks_admin_insert ON public.external_checks;
CREATE POLICY external_checks_admin_insert ON public.external_checks
  FOR INSERT TO authenticated WITH CHECK (public.is_admin());
DROP POLICY IF EXISTS external_checks_admin_update ON public.external_checks;
CREATE POLICY external_checks_admin_update ON public.external_checks
  FOR UPDATE TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());
-- No DELETE policy: entries are cancelled, never deleted.

-- Revenue: add the external checks to admin_sales_ledger (the rest of the function is unchanged).
DO $mig$
DECLARE
  d text;
BEGIN
  d := pg_get_functiondef('public.admin_sales_ledger'::regproc);
  IF position('external_checks' in d) > 0 THEN
    RETURN;   -- already applied
  END IF;
  d := replace(d, $old$  all_rows AS ($old$, $new$  ext AS (   -- checks done directly on TurniScan, entered by the admin
    SELECT e.at,
           'external'::text AS source,
           e.checks * e.unit_price * CASE WHEN e.currency = 'USD' THEN 50 ELSE 1 END AS rev,
           e.checks * e.unit_cost  * CASE WHEN e.currency = 'USD' THEN 50 ELSE 1 END AS cost
    FROM external_checks e
    WHERE e.cancelled_at IS NULL
  ),
  all_rows AS ($new$);
  d := replace(d, $old$UNION ALL SELECT * FROM adj$old$, $new$UNION ALL SELECT * FROM adj
    UNION ALL SELECT * FROM ext$new$);
  IF position('FROM ext' in d) = 0 OR position('ext AS (' in d) = 0 THEN
    RAISE EXCEPTION 'admin_sales_ledger: expected text not found';
  END IF;
  EXECUTE d;
END
$mig$;
