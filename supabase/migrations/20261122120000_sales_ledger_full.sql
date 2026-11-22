-- Revenue and profit now count everything:
--  * Completed payments, including the 6 old spreadsheet imports (sheet-row-…).
--  * USD payments at the EGP price of the package bought (no fixed rate), else amount x 50.
--  * Packages the admin adds by hand: revenue = package price, cost = provider cost of all its slots.
--    The account-creation gift package adds only its cost (no money came in for it).
--  * Slots the admin deducts by hand take back their value and cost (per-slot price of the 1-slot package).
--  * Redeemed vouchers, as before.
-- Provider cost is always taken for every slot sold or given, used or not yet used.
CREATE OR REPLACE FUNCTION public.admin_sales_ledger()
 RETURNS TABLE(at timestamp with time zone, source text, revenue_egp numeric, cost_egp numeric, profit_egp numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  WITH unit AS (   -- price and provider cost of one slot, from the 1-slot package (fallback 100 EGP / 0.85 USD)
    SELECT COALESCE((SELECT price_egp / NULLIF(slots, 0) FROM slot_packages WHERE slots = 1 ORDER BY price_egp LIMIT 1), 100) AS price,
           COALESCE((SELECT provider_cost_usd FROM slot_packages WHERE slots = 1 ORDER BY price_egp LIMIT 1), 0.85) AS cost_usd
  ),
  pay AS (
    SELECT COALESCE(p.verified_at, p.created_at) AS at,
           CASE WHEN COALESCE(p.transaction_id, '') LIKE 'sheet-row-%' THEN 'sheet' ELSE 'payment' END AS source,
           CASE WHEN p.currency = 'USD' THEN COALESCE(sp.price_egp, p.amount * 50) ELSE p.amount END AS rev,
           CASE WHEN sp.slots IS NOT NULL THEN sp.slots * sp.provider_cost_usd * 50
                ELSE COALESCE(p.credits, 0) * (SELECT cost_usd FROM unit) * 50 END AS cost
    FROM payments p
    LEFT JOIN LATERAL (
      SELECT s.slots, s.provider_cost_usd, s.price_egp
      FROM slot_packages s
      WHERE s.legacy_pack_id = p.pack_id OR s.id::text = p.pack_id
      LIMIT 1
    ) sp ON true
    WHERE p.status = 'completed'
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
  adj AS (
    SELECT a.created_at AS at,
           'adjust'::text AS source,
           CASE WHEN a.action = 'deduct_slots' THEN -a.slots * COALESCE(pk.price_egp / NULLIF(pk.slots, 0), (SELECT price FROM unit))
                WHEN COALESCE(a.note, '') ILIKE '%إنشاء الحساب%' THEN 0
                WHEN pk.id IS NOT NULL THEN pk.price_egp / NULLIF(pk.slots, 0) * a.slots
                ELSE a.slots * (SELECT price FROM unit) END AS rev,
           (CASE WHEN a.action = 'deduct_slots' THEN -1 ELSE 1 END)
             * a.slots * COALESCE(pk.provider_cost_usd, (SELECT cost_usd FROM unit)) * 50 AS cost
    FROM admin_slot_adjustments a
    LEFT JOIN slot_packages pk ON pk.id = a.package_id
    WHERE a.slots IS NOT NULL AND a.slots <> 0
  ),
  all_rows AS (
    SELECT * FROM pay
    UNION ALL SELECT * FROM red
    UNION ALL SELECT * FROM adj
  )
  SELECT x.at, x.source, round(x.rev, 2), round(x.cost, 2), round(x.rev - x.cost, 2)
  FROM all_rows x
  WHERE public.is_admin();
$function$;
