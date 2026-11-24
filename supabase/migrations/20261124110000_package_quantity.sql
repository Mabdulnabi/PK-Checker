-- Buying a check package more than once in one payment (1 to 10).
--  * payments.quantity: how many of the package are bought (store payments always 1).
--  * set_payment_price: the amount is the package price x quantity (in USD the one-package price,
--    rounded up to 0.10 as before, times the quantity, the same as the site shows).
--  * confirm_topup: the minimum amount is checked for the whole quantity, and ONE package is given
--    with all the checks (slots x quantity) and the validity x quantity (5 days x 2 = 10 days).
--  * admin_sales_ledger: revenue and provider cost of a USD payment count the whole quantity.
--  * open_topups.quantity: an open top-up keeps the chosen quantity.
ALTER TABLE public.payments ADD COLUMN IF NOT EXISTS quantity integer NOT NULL DEFAULT 1;
DO $$ BEGIN
  ALTER TABLE public.payments ADD CONSTRAINT payments_quantity_range CHECK (quantity BETWEEN 1 AND 10);
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
ALTER TABLE public.open_topups ADD COLUMN IF NOT EXISTS quantity integer NOT NULL DEFAULT 1;

CREATE OR REPLACE FUNCTION public.set_payment_price()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_cur text; v_egp numeric; v_pkg record; v_order record; v_qty integer := 1;
BEGIN
  -- Admins and server functions (service role, no auth.uid()) keep the values they write.
  IF auth.uid() IS NULL OR public.is_admin() THEN RETURN NEW; END IF;

  NEW.status := 'pending';
  NEW.verified_at := NULL;
  v_cur := CASE WHEN upper(coalesce(NEW.currency, '')) = 'EGP' THEN 'EGP' ELSE 'USD' END;
  NEW.currency := v_cur;

  IF NEW.pack_id = 'store-topup' THEN
    NEW.quantity := 1;
    IF NEW.amount IS NULL OR NEW.amount <= 0
       OR (v_cur = 'USD' AND (NEW.amount < 1 OR NEW.amount > 1000))
       OR (v_cur = 'EGP' AND (NEW.amount < 10 OR NEW.amount > 50000)) THEN
      RAISE EXCEPTION 'INVALID_AMOUNT';
    END IF;
    RETURN NEW;
  ELSIF coalesce(NEW.pack_id, '') LIKE 'store-order:%' THEN
    NEW.quantity := 1;
    SELECT * INTO v_order FROM public.store_orders
    WHERE id::text = substring(NEW.pack_id from 13) AND user_id = auth.uid();
    IF NOT FOUND OR v_order.status <> 'pending_payment' THEN RAISE EXCEPTION 'ORDER_NOT_PAYABLE'; END IF;
    v_egp := v_order.price_egp;
  ELSE
    SELECT * INTO v_pkg FROM public.slot_packages
    WHERE legacy_pack_id = NEW.pack_id OR id::text = NEW.pack_id
    ORDER BY (legacy_pack_id = NEW.pack_id) DESC LIMIT 1;
    IF NOT FOUND OR NOT v_pkg.is_active THEN RAISE EXCEPTION 'PACKAGE_NOT_AVAILABLE'; END IF;
    v_qty := least(10, greatest(1, coalesce(NEW.quantity, 1)));
    NEW.quantity := v_qty;
    v_egp := v_pkg.price_egp;
  END IF;

  IF v_egp IS NULL OR v_egp <= 0 THEN RAISE EXCEPTION 'NOTHING_TO_PAY'; END IF;
  NEW.amount := CASE WHEN v_cur = 'EGP' THEN round(v_egp) ELSE ceil(v_egp / 50 * 10) / 10 END * v_qty;
  RETURN NEW;
END;
$$;

DO $mig$
DECLARE d text;
BEGIN
  -- confirm_topup: minimum amount for the whole quantity; one package with slots and validity x quantity.
  d := pg_get_functiondef('public.confirm_topup'::regproc);
  IF position('v_pay.quantity' in d) = 0 THEN
    d := replace(d, $o$      IF coalesce(v_pay.amount, 0) < v_expected * 0.9 THEN$o$,
                    $n$      v_expected := v_expected * greatest(1, coalesce(v_pay.quantity, 1));
      IF coalesce(v_pay.amount, 0) < v_expected * 0.9 THEN$n$);
    d := replace(d, $o$  v_grant := grant_slots(p_user_id, v_pkg_id, 'purchase', p_payment_id::text, now());$o$,
                    $n$  v_grant := grant_slots(p_user_id, v_pkg_id, 'purchase', p_payment_id::text, now());
  -- Bought more than once: one package with all the checks, and its validity multiplied too.
  IF coalesce(v_pay.quantity, 1) > 1 AND v_grant IS NOT NULL THEN
    UPDATE customer_slot_grants g
       SET slots_total = g.slots_total * v_pay.quantity,
           expires_at = CASE WHEN g.expires_at IS NULL THEN NULL
                             ELSE g.expires_at + make_interval(days => coalesce((SELECT sp.expiry_days FROM slot_packages sp WHERE sp.id = v_pkg_id), 0) * (v_pay.quantity - 1)) END
     WHERE g.id = v_grant;
  END IF;$n$);
    IF (length(d) - length(replace(d, 'v_pay.quantity', ''))) / length('v_pay.quantity') < 4 THEN
      RAISE EXCEPTION 'confirm_topup: expected text not found';
    END IF;
    EXECUTE d;
  END IF;

  -- Revenue: a USD payment counts its package price and cost for the whole quantity.
  d := pg_get_functiondef('public.admin_sales_ledger'::regproc);
  IF position('p.quantity' in d) = 0 THEN
    d := replace(d, 'COALESCE(sp.price_egp, p.amount * 50)', 'COALESCE(sp.price_egp * coalesce(p.quantity, 1), p.amount * 50)');
    d := replace(d, 'sp.slots * sp.provider_cost_usd * 50', 'sp.slots * coalesce(p.quantity, 1) * sp.provider_cost_usd * 50');
    IF (length(d) - length(replace(d, 'p.quantity', ''))) / length('p.quantity') < 2 THEN
      RAISE EXCEPTION 'admin_sales_ledger: expected text not found';
    END IF;
    EXECUTE d;
  END IF;
END
$mig$;
