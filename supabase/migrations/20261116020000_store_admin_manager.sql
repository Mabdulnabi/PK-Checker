-- 20261116020000_store_admin_manager.sql
-- Store manager in the admin dashboard: coupons by percent or fixed amount (optionally for some products)
-- with a usage log, the payment method on each order, delivery editing, stock as accounts or keys,
-- and a customer notification when an order is delivered.

-- ── Coupons ──
ALTER TABLE public.store_coupons ALTER COLUMN percent_off DROP NOT NULL;
ALTER TABLE public.store_coupons DROP CONSTRAINT IF EXISTS store_coupons_percent_off_check;
ALTER TABLE public.store_coupons
  ADD COLUMN IF NOT EXISTS type           text NOT NULL DEFAULT 'percent',
  ADD COLUMN IF NOT EXISTS amount_off_egp numeric(10,2),
  ADD COLUMN IF NOT EXISTS description    text,
  ADD COLUMN IF NOT EXISTS product_ids    uuid[];
ALTER TABLE public.store_coupons DROP CONSTRAINT IF EXISTS store_coupons_value_check;
ALTER TABLE public.store_coupons ADD CONSTRAINT store_coupons_value_check CHECK (
  (type = 'percent' AND percent_off BETWEEN 1 AND 100) OR (type = 'fixed' AND amount_off_egp > 0));

CREATE TABLE IF NOT EXISTS public.store_coupon_usages (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code       text NOT NULL REFERENCES public.store_coupons(code) ON UPDATE CASCADE ON DELETE CASCADE,
  user_id    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  order_id   uuid REFERENCES public.store_orders(id) ON DELETE SET NULL,
  product_id uuid REFERENCES public.store_products(id) ON DELETE SET NULL,
  discount_egp numeric(10,2),
  used_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS store_coupon_usages_code_idx ON public.store_coupon_usages (code, used_at DESC);
ALTER TABLE public.store_coupon_usages ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_coupon_usages FROM anon, authenticated;
GRANT SELECT ON public.store_coupon_usages TO authenticated;
DROP POLICY IF EXISTS store_coupon_usages_admin ON public.store_coupon_usages;
CREATE POLICY store_coupon_usages_admin ON public.store_coupon_usages FOR SELECT TO authenticated
  USING (public.has_permission('manage_store'));

-- Discount in EGP for a plan, or NULL when the code can't be used for it.
CREATE OR REPLACE FUNCTION public.store_coupon_discount(p_code text, p_plan_id uuid)
RETURNS numeric LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE c record; pl record;
BEGIN
  SELECT * INTO c FROM public.store_coupons
  WHERE code = upper(trim(p_code)) AND active
    AND (expires_at IS NULL OR expires_at > now())
    AND (max_uses IS NULL OR used_count < max_uses);
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT * INTO pl FROM public.store_plans WHERE id = p_plan_id;
  IF NOT FOUND THEN RETURN NULL; END IF;
  IF c.product_ids IS NOT NULL AND cardinality(c.product_ids) > 0 AND NOT (pl.product_id = ANY (c.product_ids)) THEN RETURN NULL; END IF;
  IF c.type = 'fixed' THEN RETURN least(pl.price_egp, c.amount_off_egp); END IF;
  RETURN pl.price_egp - round(pl.price_egp * (100 - c.percent_off) / 100.0);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_coupon_discount(text, uuid) FROM PUBLIC, anon, authenticated;

DROP FUNCTION IF EXISTS public.store_coupon_check(text);
CREATE OR REPLACE FUNCTION public.store_coupon_check(p_code text, p_plan_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE d numeric; c record; price numeric;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
  d := public.store_coupon_discount(p_code, p_plan_id);
  IF d IS NULL THEN RETURN jsonb_build_object('valid', false); END IF;
  SELECT type, percent_off, amount_off_egp INTO c FROM public.store_coupons WHERE code = upper(trim(p_code));
  SELECT price_egp INTO price FROM public.store_plans WHERE id = p_plan_id;
  RETURN jsonb_build_object('valid', true, 'type', c.type, 'percent', c.percent_off, 'amount', c.amount_off_egp,
                            'discount', d, 'total', price - d);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_coupon_check(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_coupon_check(text, uuid) TO authenticated;

-- ── Orders: payment method, coupons by amount, usage log ──
ALTER TABLE public.store_orders ADD COLUMN IF NOT EXISTS payment_method text;

CREATE OR REPLACE FUNCTION public.store_create_order(p_plan_id uuid, p_coupon text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  uid uuid := auth.uid();
  pl record; pr record;
  disc numeric := 0; total numeric; oid uuid := gen_random_uuid();
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
  SELECT * INTO pl FROM public.store_plans WHERE id = p_plan_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'plan not available'; END IF;
  SELECT * INTO pr FROM public.store_products WHERE id = pl.product_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'product not available'; END IF;
  IF coalesce(trim(p_coupon), '') <> '' THEN
    disc := public.store_coupon_discount(p_coupon, p_plan_id);
    IF disc IS NULL THEN RAISE EXCEPTION 'invalid_coupon'; END IF;
  END IF;
  IF pr.delivery_type = 'instant' AND NOT EXISTS (
       SELECT 1 FROM public.store_stock_items WHERE plan_id = pl.id AND status = 'available') THEN
    RAISE EXCEPTION 'out_of_stock';
  END IF;
  total := greatest(0, pl.price_egp - disc);
  INSERT INTO public.store_orders (id, user_id, product_id, plan_id, product_name, plan_name, price_egp, list_price_egp,
                                   old_price_egp, discount_egp, coupon_code, delivery_type, status, duration_days)
  VALUES (oid, uid, pr.id, pl.id, pr.name_en, pl.name_en, total, pl.price_egp, pl.old_price_egp,
          disc, CASE WHEN disc > 0 THEN upper(trim(p_coupon)) END, pr.delivery_type, 'pending_payment', pl.duration_days);
  RETURN jsonb_build_object('order_id', oid, 'total', total, 'discount', disc, 'list_price', pl.price_egp);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_create_order(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_create_order(uuid, text) TO authenticated;

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
    INSERT INTO public.store_coupon_usages (code, user_id, order_id, product_id, discount_egp)
    SELECT o.coupon_code, o.user_id, o.id, o.product_id, o.discount_egp
    WHERE EXISTS (SELECT 1 FROM public.store_coupons WHERE code = o.coupon_code);
  END IF;
  RETURN 'done';
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_fulfil_order(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.store_pay_order(p_order_id uuid)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE o record;
BEGIN
  SELECT * INTO o FROM public.store_orders WHERE id = p_order_id AND user_id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'order not found'; END IF;
  IF o.status = 'pending_payment' AND o.payment_method IS NULL THEN
    UPDATE public.store_orders
    SET payment_method = CASE WHEN o.price_egp = 0 AND o.coupon_code IS NOT NULL THEN 'coupon:' || o.coupon_code ELSE 'wallet' END
    WHERE id = o.id;
  END IF;
  RETURN public.store_fulfil_order(p_order_id);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_pay_order(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_pay_order(uuid) TO authenticated;

-- Gateway payments: record the gateway on the order before completing it (rest unchanged).
CREATE OR REPLACE FUNCTION public.confirm_topup(p_user_id uuid, p_payment_id uuid, p_credits integer, p_gateway text, p_provider_ref text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  v_claimed integer; v_pay payments%ROWTYPE; v_pkg_id uuid; v_grant uuid;
  v_egp numeric; v_order uuid; v_store_err text;
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
          UPDATE public.store_orders SET payment_method = p_gateway WHERE id = v_order AND payment_method IS NULL;
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

-- ── Admin: deliveries ──
-- Delivers (or re-delivers) a subscription order and notifies the customer.
CREATE OR REPLACE FUNCTION public.store_admin_deliver_subscription(p_order_id uuid, p_details jsonb, p_deliver_at timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE o record; v_at timestamptz := coalesce(p_deliver_at, now());
BEGIN
  IF NOT public.has_permission('manage_store') THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO o FROM public.store_orders WHERE id = p_order_id AND delivery_type = 'subscription' AND status IN ('paid', 'delivered');
  IF NOT FOUND THEN RAISE EXCEPTION 'order not found'; END IF;
  UPDATE public.store_orders
  SET delivery_enc = public.store_encrypt(p_details),
      deliver_at   = CASE WHEN o.status = 'delivered' AND o.deliver_at IS NOT NULL THEN o.deliver_at ELSE v_at END,
      end_date     = CASE WHEN o.status = 'delivered' AND o.end_date IS NOT NULL THEN o.end_date ELSE v_at + (o.duration_days || ' days')::interval END,
      status       = 'delivered'
  WHERE id = p_order_id;
  INSERT INTO public.notifications (user_id, type, title_ar, title_en, body_ar, body_en)
  VALUES (o.user_id, 'store_delivery',
          CASE WHEN o.status = 'delivered' THEN 'تم تحديث بيانات طلبك' ELSE 'تم تسليم طلبك ✅' END,
          CASE WHEN o.status = 'delivered' THEN 'Your order details were updated' ELSE 'Your order was delivered ✅' END,
          o.product_name || ' — افتح الأدوات الأكاديمية ← طلباتي لعرض البيانات.',
          o.product_name || ' — open Academic Tools → My orders to view the details.');
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_admin_deliver_subscription(uuid, jsonb, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_admin_deliver_subscription(uuid, jsonb, timestamptz) TO authenticated;

CREATE OR REPLACE FUNCTION public.store_admin_order_details(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE o record; enc bytea;
BEGIN
  IF NOT public.has_permission('manage_store') THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO o FROM public.store_orders WHERE id = p_order_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'order not found'; END IF;
  IF o.delivery_type = 'instant' THEN SELECT credential_enc INTO enc FROM public.store_stock_items WHERE id = o.stock_item_id;
  ELSE enc := o.delivery_enc; END IF;
  RETURN CASE WHEN enc IS NULL THEN NULL ELSE public.store_decrypt(enc) END;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_admin_order_details(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_admin_order_details(uuid) TO authenticated;

-- Takes a delivery back: the subscription returns to "waiting for delivery".
CREATE OR REPLACE FUNCTION public.store_admin_clear_delivery(p_order_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF NOT public.has_permission('manage_store') THEN RAISE EXCEPTION 'not allowed'; END IF;
  UPDATE public.store_orders SET delivery_enc = NULL, deliver_at = NULL, end_date = NULL, viewed_at = NULL, status = 'paid'
  WHERE id = p_order_id AND delivery_type = 'subscription' AND status = 'delivered';
  IF NOT FOUND THEN RAISE EXCEPTION 'order not found'; END IF;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_admin_clear_delivery(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_admin_clear_delivery(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.store_admin_extend_order(p_order_id uuid, p_days int)
RETURNS timestamptz LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE d timestamptz;
BEGIN
  IF NOT public.has_permission('manage_store') THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_days IS NULL OR p_days < 1 OR p_days > 3650 THEN RAISE EXCEPTION 'invalid days'; END IF;
  UPDATE public.store_orders SET end_date = greatest(coalesce(end_date, now()), now()) + (p_days || ' days')::interval
  WHERE id = p_order_id AND status = 'delivered' RETURNING end_date INTO d;
  IF d IS NULL THEN RAISE EXCEPTION 'order not found'; END IF;
  RETURN d;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_admin_extend_order(uuid, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_admin_extend_order(uuid, int) TO authenticated;

-- ── Admin: stock as accounts or keys ──
-- p_items: [{"type":"account","email":"..","password":"..","note":".."} | {"type":"key","key":"..","note":".."}]
CREATE OR REPLACE FUNCTION public.store_admin_add_stock(p_plan_id uuid, p_items jsonb)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
DECLARE it jsonb; n int := 0; t text;
BEGIN
  IF NOT public.has_permission('manage_store') THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF jsonb_typeof(p_items) <> 'array' THEN RAISE EXCEPTION 'items must be an array'; END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    t := CASE WHEN it->>'type' = 'key' THEN 'key' ELSE 'account' END;
    IF t = 'key' AND coalesce(trim(it->>'key'), '') = '' THEN CONTINUE; END IF;
    IF t = 'account' AND (coalesce(trim(it->>'email'), '') = '' OR coalesce(it->>'password', '') = '') THEN CONTINUE; END IF;
    INSERT INTO public.store_stock_items (plan_id, credential_enc)
    VALUES (p_plan_id, public.store_encrypt(CASE WHEN t = 'key'
      THEN jsonb_build_object('type', 'key', 'key', trim(it->>'key'), 'note', coalesce(it->>'note', ''))
      ELSE jsonb_build_object('type', 'account', 'email', trim(it->>'email'), 'password', it->>'password', 'note', coalesce(it->>'note', '')) END));
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$;

-- Edits an unsold item. Empty fields keep their current value.
CREATE OR REPLACE FUNCTION public.store_admin_update_stock(p_item_id uuid, p_item jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
DECLARE s record; cur jsonb; nxt jsonb; t text;
BEGIN
  IF NOT public.has_permission('manage_store') THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO s FROM public.store_stock_items WHERE id = p_item_id AND status = 'available' FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'item not available'; END IF;
  cur := public.store_decrypt(s.credential_enc);
  t := coalesce(nullif(p_item->>'type', ''), cur->>'type', 'account');
  IF t = 'key' THEN
    nxt := jsonb_build_object('type', 'key',
      'key', coalesce(nullif(trim(p_item->>'key'), ''), CASE WHEN cur->>'type' = 'key' THEN cur->>'key' END),
      'note', coalesce(p_item->>'note', cur->>'note', ''));
    IF coalesce(nxt->>'key', '') = '' THEN RAISE EXCEPTION 'key required'; END IF;
  ELSE
    nxt := jsonb_build_object('type', 'account',
      'email', coalesce(nullif(trim(p_item->>'email'), ''), CASE WHEN coalesce(cur->>'type', 'account') = 'account' THEN cur->>'email' END),
      'password', coalesce(nullif(p_item->>'password', ''), CASE WHEN coalesce(cur->>'type', 'account') = 'account' THEN cur->>'password' END),
      'note', coalesce(p_item->>'note', cur->>'note', ''));
    IF coalesce(nxt->>'email', '') = '' OR coalesce(nxt->>'password', '') = '' THEN RAISE EXCEPTION 'email and password required'; END IF;
  END IF;
  UPDATE public.store_stock_items SET credential_enc = public.store_encrypt(nxt) WHERE id = p_item_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_admin_update_stock(uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_admin_update_stock(uuid, jsonb) TO authenticated;

-- All stock for the manager. Passwords are not returned; keys are.
CREATE OR REPLACE FUNCTION public.store_admin_stock_all()
RETURNS TABLE(id uuid, plan_id uuid, status text, item_type text, email text, item_key text, note text,
              created_at timestamptz, sold_at timestamptz, assigned_name text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
BEGIN
  IF NOT public.has_permission('manage_store') THEN RAISE EXCEPTION 'not allowed'; END IF;
  RETURN QUERY
    SELECT s.id, s.plan_id, s.status, coalesce(x.d->>'type', 'account'), x.d->>'email', x.d->>'key', x.d->>'note',
           s.created_at, s.sold_at, p.full_name
    FROM public.store_stock_items s
    CROSS JOIN LATERAL (SELECT public.store_decrypt(s.credential_enc) AS d) x
    LEFT JOIN public.store_orders o ON o.id = s.order_id
    LEFT JOIN public.users_profile p ON p.user_id = o.user_id
    ORDER BY s.created_at DESC
    LIMIT 5000;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_admin_stock_all() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_admin_stock_all() TO authenticated;
