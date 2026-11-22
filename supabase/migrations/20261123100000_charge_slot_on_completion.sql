-- When an order is completed (reports delivered, by the API or by the admin by hand) and its slot is
-- not taken, the slot is taken now: a slot given back after a failure is taken again, and an order
-- that never had one takes one from the customer's balance (earliest-expiring package first).
-- If the customer has no slot left, nothing is charged and the admin gets a notification.
CREATE OR REPLACE FUNCTION public.trg_charge_slot_on_completion()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_type  text := CASE WHEN NEW.check_type = 'sim_only' THEN 'plag_only' ELSE 'plag_ai' END;
  v_usage slot_usages%ROWTYPE;
  v_grant uuid;
  v_has_usage boolean;
BEGIN
  IF NEW.status <> 'completed' OR OLD.status = 'completed' OR NEW.user_id IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_usage FROM slot_usages WHERE order_id = NEW.id ORDER BY (status = 'reserved') DESC, created_at DESC LIMIT 1;
  v_has_usage := FOUND;
  IF v_has_usage AND v_usage.status = 'reserved' THEN
    RETURN NEW;  -- already charged
  END IF;

  -- A package of the right type with a slot left (the usage's own package first).
  SELECT g.id INTO v_grant
    FROM customer_slot_grants g
   WHERE g.user_id = NEW.user_id AND g.slot_type = COALESCE(v_usage.slot_type, v_type)
     AND (g.expires_at IS NULL OR g.expires_at > now())
     AND g.slots_total > (SELECT count(*) FROM slot_usages u WHERE u.grant_id = g.id AND u.status = 'reserved')
   ORDER BY (g.id IS NOT DISTINCT FROM v_usage.grant_id) DESC, g.expires_at ASC NULLS LAST, g.granted_at ASC
   LIMIT 1
   FOR UPDATE OF g;

  IF v_grant IS NULL THEN
    INSERT INTO admin_notifications (type, user_id, order_id, title_ar, title_en, body_ar, body_en)
    VALUES ('slot_charge_failed', NEW.user_id, NEW.id,
            'تسليم بدون خصم فحص', 'Delivered without a slot charge',
            'الطلب ' || COALESCE(NEW.display_id, NEW.id::text) || ' اتسلم والعميل مالوش رصيد فحوصات، فماتخصمش منه فحص.',
            'Order ' || COALESCE(NEW.display_id, NEW.id::text) || ' was delivered but the customer had no slot left, so none was charged.');
    RETURN NEW;
  END IF;

  IF v_has_usage THEN
    UPDATE slot_usages SET status = 'reserved', grant_id = v_grant, updated_at = now() WHERE id = v_usage.id;
  ELSE
    INSERT INTO slot_usages (user_id, grant_id, slot_type, order_id, idempotency_key)
    VALUES (NEW.user_id, v_grant, v_type, NEW.id, 'order:' || NEW.id::text)
    ON CONFLICT (idempotency_key) DO UPDATE SET status = 'reserved', grant_id = EXCLUDED.grant_id, updated_at = now();
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_charge_slot_on_completion ON public.orders;
CREATE TRIGGER trg_charge_slot_on_completion AFTER UPDATE ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.trg_charge_slot_on_completion();

-- Wallet records never mention manual handling.
UPDATE public.wallet_transactions SET description = 'خصم فحص' WHERE description = 'خصم كريديت — تسليم يدوي بعد استرداد سابق';
DO $$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.deduct_order_credits_on_delivery'::regproc);
  d := replace(d, '''خصم كريديت — تسليم يدوي بعد استرداد سابق''', '''خصم فحص''');
  EXECUTE d;
END $$;
