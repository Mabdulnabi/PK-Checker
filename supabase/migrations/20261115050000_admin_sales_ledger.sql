-- 20261115050000_admin_sales_ledger.sql
-- Admin revenue and profit, one row per sale:
--   * every completed payment (automatic confirmation or admin approval), at its EGP value
--   * every redeemed voucher, at its value
-- Cost of a sale = the package's provider cost per check x slots x 50 EGP (the agreed cost basis).
-- Profit = revenue - cost. Old vouchers without a package use 5 EGP per credit, 20 credits per check.
-- Payments in the old sheet import ("sheet-row-") are left out of the periods.

CREATE OR REPLACE FUNCTION public.admin_sales_ledger()
RETURNS TABLE(at timestamptz, source text, revenue_egp numeric, cost_egp numeric, profit_egp numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH pay AS (
    SELECT COALESCE(p.verified_at, p.created_at) AS at,
           'payment'::text AS source,
           CASE WHEN p.currency = 'USD' THEN p.amount * 50 ELSE p.amount END AS rev,
           COALESCE(sp.slots * sp.provider_cost_usd * 50, 0) AS cost
    FROM payments p
    LEFT JOIN LATERAL (
      SELECT s.slots, s.provider_cost_usd
      FROM slot_packages s
      WHERE s.legacy_pack_id = p.pack_id OR s.id::text = p.pack_id
      LIMIT 1
    ) sp ON true
    WHERE p.status = 'completed'
      AND COALESCE(p.transaction_id, '') NOT LIKE 'sheet-row-%'
  ),
  red AS (
    SELECT r.redeemed_at AS at,
           'redeem'::text AS source,
           COALESCE(pk.price_egp / NULLIF(pk.slots, 0) * r.credits, r.credits * 5) AS rev,
           COALESCE(pk.provider_cost_usd * 50 * r.credits, (r.credits / 20.0) * 0.85 * 50) AS cost
    FROM redeem_codes r
    LEFT JOIN slot_packages pk ON pk.id = r.package_id
    WHERE r.redeemed_at IS NOT NULL
  ),
  all_rows AS (
    SELECT * FROM pay
    UNION ALL
    SELECT * FROM red
  )
  SELECT x.at,
         x.source,
         round(x.rev, 2),
         round(x.cost, 2),
         round(x.rev - x.cost, 2)
  FROM all_rows x
  WHERE public.is_admin();
$$;

REVOKE EXECUTE ON FUNCTION public.admin_sales_ledger() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_sales_ledger() TO authenticated;
