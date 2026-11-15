-- 20261115110000_academic_tools_checkout.sql
-- Academic Tools checkout: coupons, a pending order created at checkout, payment from the store wallet,
-- and store payments through the existing gateways (confirm_topup gets a separate store branch;
-- the slot top-up path is unchanged).

ALTER TABLE public.store_orders DROP CONSTRAINT IF EXISTS store_orders_status_check;
ALTER TABLE public.store_orders ADD CONSTRAINT store_orders_status_check
  CHECK (status IN ('pending_payment', 'paid', 'delivered', 'refunded'));
ALTER TABLE public.store_orders
  ADD COLUMN IF NOT EXISTS coupon_code    text,
  ADD COLUMN IF NOT EXISTS discount_egp   numeric(10,2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS list_price_egp numeric(10,2);

-- Coupons: percent off. Admins manage them; customers can only check a code through store_coupon_check.
CREATE TABLE IF NOT EXISTS public.store_coupons (
  code        text PRIMARY KEY CHECK (code = upper(code) AND length(code) BETWEEN 2 AND 40),
  percent_off int NOT NULL CHECK (percent_off BETWEEN 1 AND 100),
  max_uses    int CHECK (max_uses IS NULL OR max_uses > 0),
  used_count  int NOT NULL DEFAULT 0,
  expires_at  timestamptz,
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.store_coupons ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_coupons FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.store_coupons TO authenticated;
DROP POLICY IF EXISTS store_coupons_admin ON public.store_coupons;
CREATE POLICY store_coupons_admin ON public.store_coupons FOR ALL TO authenticated
  USING (public.has_permission('manage_store')) WITH CHECK (public.has_permission('manage_store'));

CREATE OR REPLACE FUNCTION public.store_coupon_percent(p_code text)
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  SELECT percent_off FROM public.store_coupons
  WHERE code = upper(trim(p_code)) AND active
    AND (expires_at IS NULL OR expires_at > now())
    AND (max_uses IS NULL OR used_count < max_uses);
$$;
REVOKE EXECUTE ON FUNCTION public.store_coupon_percent(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.store_coupon_check(p_code text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE pct int;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
  pct := public.store_coupon_percent(p_code);
  RETURN jsonb_build_object('valid', pct IS NOT NULL, 'percent', coalesce(pct, 0));
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_coupon_check(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_coupon_check(text) TO authenticated;

-- Checkout step 1: a pending order at its final price (whole EGP when a coupon applies).
CREATE OR REPLACE FUNCTION public.store_create_order(p_plan_id uuid, p_coupon text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  uid uuid := auth.uid();
  pl record; pr record;
  pct int := 0; total numeric; oid uuid := gen_random_uuid();
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
  SELECT * INTO pl FROM public.store_plans WHERE id = p_plan_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'plan not available'; END IF;
  SELECT * INTO pr FROM public.store_products WHERE id = pl.product_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'product not available'; END IF;
  IF coalesce(trim(p_coupon), '') <> '' THEN
    pct := public.store_coupon_percent(p_coupon);
    IF pct IS NULL THEN RAISE EXCEPTION 'invalid_coupon'; END IF;
  END IF;
  IF pr.delivery_type = 'instant' AND NOT EXISTS (
       SELECT 1 FROM public.store_stock_items WHERE plan_id = pl.id AND status = 'available') THEN
    RAISE EXCEPTION 'out_of_stock';
  END IF;
  total := CASE WHEN pct > 0 THEN round(pl.price_egp * (100 - pct) / 100.0) ELSE pl.price_egp END;
  INSERT INTO public.store_orders (id, user_id, product_id, plan_id, product_name, plan_name, price_egp, list_price_egp,
                                   old_price_egp, discount_egp, coupon_code, delivery_type, status, duration_days)
  VALUES (oid, uid, pr.id, pl.id, pr.name_en, pl.name_en, total, pl.price_egp, pl.old_price_egp,
          pl.price_egp - total, CASE WHEN pct > 0 THEN upper(trim(p_coupon)) END, pr.delivery_type, 'pending_payment', pl.duration_days);
  RETURN jsonb_build_object('order_id', oid, 'total', total, 'discount', pl.price_egp - total, 'percent', pct, 'list_price', pl.price_egp);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_create_order(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_create_order(uuid, text) TO authenticated;

-- Completes a pending order from its owner's store wallet. Instant products take one stock item.
-- Safe to call twice: a finished order is returned as it is.
CREATE OR REPLACE FUNCTION public.store_fulfil_order(p_order_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE o record; bal numeric; stock_id uuid;
BEGIN
  SELECT * INTO o FROM public.store_orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'order not found'; END IF;
  IF o.status <> 'pending_payment' THEN RETURN o.status; END IF;

  INSERT INTO public.store_wallet (user_id, balance_egp) VALUES (o.user_id, 0) ON CONFLICT (user_id) DO NOTHING;
  SELECT balance_egp INTO bal FROM public.store_wallet WHERE user_id = o.user_id FOR UPDATE;
  IF bal < o.price_egp THEN RAISE EXCEPTION 'insufficient_balance'; END IF;

  IF o.delivery_type = 'instant' THEN
    SELECT id INTO stock_id FROM public.store_stock_items
    WHERE plan_id = o.plan_id AND status = 'available'
    ORDER BY created_at LIMIT 1
    FOR UPDATE SKIP LOCKED;
    IF stock_id IS NULL THEN RAISE EXCEPTION 'out_of_stock'; END IF;
    UPDATE public.store_stock_items SET status = 'sold', order_id = o.id, sold_at = now() WHERE id = stock_id;
  END IF;

  IF o.price_egp > 0 THEN
    UPDATE public.store_wallet SET balance_egp = balance_egp - o.price_egp, updated_at = now() WHERE user_id = o.user_id;
    INSERT INTO public.store_wallet_tx (user_id, amount_egp, kind, order_id, note)
    VALUES (o.user_id, -o.price_egp, 'purchase', o.id, o.product_name || ' - ' || o.plan_name);
  END IF;

  UPDATE public.store_orders SET
    status        = CASE WHEN o.delivery_type = 'instant' THEN 'delivered' ELSE 'paid' END,
    stock_item_id = stock_id,
    deliver_at    = CASE WHEN o.delivery_type = 'instant' THEN now() END,
    end_date      = CASE WHEN o.delivery_type = 'instant' THEN now() + (o.duration_days || ' days')::interval END,
    created_at    = now()
  WHERE id = o.id;

  IF o.coupon_code IS NOT NULL THEN
    UPDATE public.store_coupons SET used_count = used_count + 1 WHERE code = o.coupon_code;
  END IF;
  RETURN 'done';
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_fulfil_order(uuid) FROM PUBLIC, anon, authenticated;

-- Customer: pay a pending order of their own from the store wallet (also used for free orders).
CREATE OR REPLACE FUNCTION public.store_pay_order(p_order_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.store_orders WHERE id = p_order_id AND user_id = auth.uid()) THEN
    RAISE EXCEPTION 'order not found';
  END IF;
  RETURN public.store_fulfil_order(p_order_id);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_pay_order(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_pay_order(uuid) TO authenticated;

-- Gateways: a payment whose pack_id starts with "store" credits the store wallet with the verified amount
-- (USD x 50), then completes the referenced order of the same customer. If the order can't complete
-- (e.g. out of stock), the money stays in the store wallet.
CREATE OR REPLACE FUNCTION public.confirm_topup(p_user_id uuid, p_payment_id uuid, p_credits integer, p_gateway text, p_provider_ref text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_claimed   integer;
  v_pay       payments%ROWTYPE;
  v_pkg_id    uuid;
  v_grant     uuid;
  v_egp       numeric;
  v_order     uuid;
  v_store_err text;
BEGIN
  SELECT * INTO v_pay FROM payments WHERE id = p_payment_id AND user_id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_NOT_FOUND'; END IF;
  IF v_pay.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'alreadyProcessed', v_pay.status = 'completed', 'error', 'Payment is not pending');
  END IF;
  INSERT INTO processed_payment_refs (gateway, provider_ref, payment_id) VALUES (p_gateway, p_provider_ref, p_payment_id) ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN jsonb_build_object('ok', false, 'alreadyProcessed', true, 'error', 'This transaction was already processed');
  END IF;

  IF coalesce(v_pay.pack_id, '') LIKE 'store%' THEN
    v_egp := CASE WHEN upper(coalesce(v_pay.currency, 'USD')) IN ('USD', 'USDT') THEN round(v_pay.amount * 50, 2) ELSE v_pay.amount END;
    INSERT INTO public.store_wallet (user_id, balance_egp) VALUES (p_user_id, 0) ON CONFLICT (user_id) DO NOTHING;
    UPDATE public.store_wallet SET balance_egp = balance_egp + v_egp, updated_at = now() WHERE user_id = p_user_id;
    INSERT INTO public.store_wallet_tx (user_id, amount_egp, kind, note)
    VALUES (p_user_id, v_egp, 'topup', p_gateway || coalesce(' ' || v_pay.reference, ''));
    UPDATE payments SET status = 'completed', verified_at = now(), transaction_id = p_provider_ref WHERE id = p_payment_id;
    IF v_pay.pack_id LIKE 'store-order:%' THEN
      BEGIN
        v_order := substring(v_pay.pack_id from 13)::uuid;
        IF EXISTS (SELECT 1 FROM public.store_orders WHERE id = v_order AND user_id = p_user_id) THEN
          PERFORM public.store_fulfil_order(v_order);
        END IF;
      EXCEPTION WHEN OTHERS THEN
        v_store_err := SQLERRM;
      END;
    END IF;
    RETURN jsonb_build_object('ok', true, 'store', true, 'storeError', v_store_err);
  END IF;

  SELECT sp.id INTO v_pkg_id FROM slot_packages sp WHERE sp.legacy_pack_id = v_pay.pack_id OR sp.id::text = v_pay.pack_id LIMIT 1;
  IF v_pkg_id IS NULL THEN RAISE EXCEPTION 'PACKAGE_NOT_FOUND'; END IF;
  v_grant := grant_slots(p_user_id, v_pkg_id, 'purchase', p_payment_id::text, now());
  UPDATE payments SET status = 'completed', verified_at = now(), transaction_id = p_provider_ref WHERE id = p_payment_id;
  UPDATE payments SET status = 'superseded', failure_reason = 'superseded by a completed payment'
  WHERE user_id = p_user_id AND pack_id IS NOT DISTINCT FROM v_pay.pack_id AND status = 'pending' AND id <> p_payment_id;
  RETURN jsonb_build_object('ok', true, 'grantId', v_grant);
END;
$function$;
