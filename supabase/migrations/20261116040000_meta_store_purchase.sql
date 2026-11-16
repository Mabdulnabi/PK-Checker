-- 20261116040000_meta_store_purchase.sql
-- Store sales reach Meta as Purchase when the order is paid, whatever the method (store wallet,
-- gateway or coupon), valued at the order amount. Store payments (wallet top-ups and gateway
-- payments for an order) no longer send Purchase themselves, so a top-up that is later spent
-- is never counted twice. Check-package payments are unchanged.

CREATE OR REPLACE FUNCTION public.meta_on_payment_completed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  -- Store money is reported when it is spent on an order (meta_on_store_order_paid).
  IF coalesce(NEW.pack_id, '') LIKE 'store%' THEN RETURN NEW; END IF;
  PERFORM meta_send('Purchase', 'purchase-' || NEW.id::text, NEW.user_id, NEW.amount,
                    CASE WHEN NEW.currency = 'USDT' THEN 'USD' ELSE COALESCE(NEW.currency, 'EGP') END);
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.meta_on_store_order_paid()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  -- Free orders (100% coupon) are not a sale.
  IF coalesce(NEW.price_egp, 0) > 0 THEN
    PERFORM meta_send('Purchase', 'store-order-' || NEW.id::text, NEW.user_id, NEW.price_egp, 'EGP');
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'meta_on_store_order_paid failed: %', SQLERRM;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_meta_store_purchase ON public.store_orders;
CREATE TRIGGER trg_meta_store_purchase
  AFTER UPDATE OF status ON public.store_orders
  FOR EACH ROW
  WHEN (OLD.status = 'pending_payment' AND NEW.status IN ('paid', 'delivered'))
  EXECUTE FUNCTION public.meta_on_store_order_paid();
