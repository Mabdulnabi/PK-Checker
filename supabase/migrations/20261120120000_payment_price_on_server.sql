-- 20261120120000_payment_price_on_server.sql
-- The price of a payment is set by the database, never by the browser.
-- Before: the customer's page wrote payments.amount itself, the verify functions (Binance, Bybit,
-- BEP20, SMS, EasyKash) only checked that the transfer matched that amount, and confirm_topup gave
-- the full package. A customer who edited the amount could pay less and still get the package.
--
-- 1) set_payment_price (BEFORE INSERT): for customer-created payments the amount comes from
--    - a check package: slot_packages.price_egp (EGP as is, USD at 50 EGP = 1 USD rounded up to 0.10,
--      the same as the site shows)
--    - a store order ("store-order:<id>"): the order total
--    - a store wallet top-up ("store-topup"): the amount the customer chose, within limits
--    Unknown or inactive packages are refused.
-- 2) confirm_topup refuses a check-package payment whose amount is below the package price
--    (covers payments created before this change).

CREATE OR REPLACE FUNCTION public.set_payment_price()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_cur text; v_egp numeric; v_pkg record; v_order record;
BEGIN
  -- Admins and server functions (service role, no auth.uid()) keep the values they write.
  IF auth.uid() IS NULL OR public.is_admin() THEN RETURN NEW; END IF;

  NEW.status := 'pending';
  NEW.verified_at := NULL;
  v_cur := CASE WHEN upper(coalesce(NEW.currency, '')) = 'EGP' THEN 'EGP' ELSE 'USD' END;
  NEW.currency := v_cur;

  IF NEW.pack_id = 'store-topup' THEN
    IF NEW.amount IS NULL OR NEW.amount <= 0
       OR (v_cur = 'USD' AND (NEW.amount < 1 OR NEW.amount > 1000))
       OR (v_cur = 'EGP' AND (NEW.amount < 10 OR NEW.amount > 50000)) THEN
      RAISE EXCEPTION 'INVALID_AMOUNT';
    END IF;
    RETURN NEW;
  ELSIF coalesce(NEW.pack_id, '') LIKE 'store-order:%' THEN
    SELECT * INTO v_order FROM public.store_orders
    WHERE id::text = substring(NEW.pack_id from 13) AND user_id = auth.uid();
    IF NOT FOUND OR v_order.status <> 'pending_payment' THEN RAISE EXCEPTION 'ORDER_NOT_PAYABLE'; END IF;
    v_egp := v_order.price_egp;
  ELSE
    SELECT * INTO v_pkg FROM public.slot_packages
    WHERE legacy_pack_id = NEW.pack_id OR id::text = NEW.pack_id
    ORDER BY (legacy_pack_id = NEW.pack_id) DESC LIMIT 1;
    IF NOT FOUND OR NOT v_pkg.is_active THEN RAISE EXCEPTION 'PACKAGE_NOT_AVAILABLE'; END IF;
    v_egp := v_pkg.price_egp;
  END IF;

  IF v_egp IS NULL OR v_egp <= 0 THEN RAISE EXCEPTION 'NOTHING_TO_PAY'; END IF;
  NEW.amount := CASE WHEN v_cur = 'EGP' THEN round(v_egp) ELSE ceil(v_egp / 50 * 10) / 10 END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_payment_price ON public.payments;
CREATE TRIGGER trg_set_payment_price BEFORE INSERT ON public.payments
  FOR EACH ROW EXECUTE FUNCTION public.set_payment_price();

CREATE OR REPLACE FUNCTION public.confirm_topup(p_user_id uuid, p_payment_id uuid, p_credits integer, p_gateway text, p_provider_ref text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_claimed integer; v_pay payments%ROWTYPE; v_pkg_id uuid; v_grant uuid;
  v_egp numeric; v_order uuid; v_store_err text; v_price numeric; v_expected numeric;
BEGIN
  SELECT * INTO v_pay FROM payments WHERE id = p_payment_id AND user_id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_NOT_FOUND'; END IF;
  IF v_pay.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'alreadyProcessed', v_pay.status = 'completed', 'error', 'Payment is not pending');
  END IF;

  -- A check package is only given for at least its price (10% margin for a price changed meanwhile).
  IF coalesce(v_pay.pack_id, '') NOT LIKE 'store%' THEN
    SELECT sp.price_egp INTO v_price FROM slot_packages sp
    WHERE sp.legacy_pack_id = v_pay.pack_id OR sp.id::text = v_pay.pack_id LIMIT 1;
    IF v_price IS NOT NULL THEN
      v_expected := CASE WHEN upper(coalesce(v_pay.currency, 'USD')) = 'EGP' THEN round(v_price) ELSE ceil(v_price / 50 * 10) / 10 END;
      IF coalesce(v_pay.amount, 0) < v_expected * 0.9 THEN
        UPDATE payments SET failure_reason = 'amount below the package price (' || coalesce(v_pay.amount, 0) || ' < ' || v_expected || ')'
        WHERE id = p_payment_id;
        RETURN jsonb_build_object('ok', false, 'error', 'AMOUNT_BELOW_PRICE');
      END IF;
    END IF;
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
