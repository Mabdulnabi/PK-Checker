-- 20261117130000_store_notifications.sql
-- Store (Academic Tools) notifications. Store payments were sending the check top-up push
-- ("💳 تم شحن رصيدك — تمت إضافة الفحوصات لحسابك") because every completed payment did.
--   * store wallet top-up paid  -> "تم شحن محفظة المتجر" (+ amount)
--   * store order paid          -> no payment push; the order notification below says it
--   * order paid, waiting for the admin (subscription) -> "تم استلام طلبك"
--   * order delivered instantly                       -> "طلبك جاهز"
--   * subscription delivered by the admin             -> push only (the in-app one is
--     already added by store_admin_deliver_subscription)
-- Check payments keep their notifications as they were.

CREATE OR REPLACE FUNCTION public.cpush_on_payment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_egp numeric;
BEGIN
  IF coalesce(NEW.pack_id, '') LIKE 'store%' THEN
    IF NEW.pack_id = 'store-topup' THEN
      -- Same conversion as confirm_topup uses for the store wallet.
      v_egp := CASE WHEN upper(coalesce(NEW.currency, 'USD')) IN ('USD', 'USDT') THEN round(NEW.amount * 50, 2) ELSE NEW.amount END;
      INSERT INTO public.notifications (user_id, type, title_ar, title_en, body_ar, body_en)
      VALUES (NEW.user_id, 'store_topup', 'تم شحن محفظة المتجر', 'Store wallet topped up',
              'اتضاف ' || trim(to_char(v_egp, 'FM999999990.##')) || ' ج.م لمحفظة الأدوات الأكاديمية.',
              trim(to_char(v_egp, 'FM999999990.##')) || ' EGP was added to your Academic Tools wallet.');
      PERFORM push_user(NEW.user_id, '💳 تم شحن محفظة المتجر', '💳 Store wallet topped up',
              'اتضاف ' || trim(to_char(v_egp, 'FM999999990.##')) || ' ج.م لمحفظة الأدوات الأكاديمية',
              trim(to_char(v_egp, 'FM999999990.##')) || ' EGP was added to your Academic Tools wallet',
              '/dashboard.html', 'pay-' || NEW.id::text);
    END IF;
    RETURN NEW;
  END IF;
  PERFORM push_user(NEW.user_id, '💳 تم شحن رصيدك', '💳 Your balance was topped up', 'تمت إضافة الفحوصات لحسابك', 'Checks were added to your account', '/dashboard.html', 'pay-' || NEW.id::text);
  RETURN NEW;
END;
$$;

-- Admin pushes: say when a payment is for the store.
CREATE OR REPLACE FUNCTION public.push_on_payment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_what text := CASE
  WHEN NEW.pack_id = 'store-topup' THEN ' · شحن محفظة المتجر'
  WHEN coalesce(NEW.pack_id, '') LIKE 'store-order:%' THEN ' · طلب متجر'
  ELSE '' END;
BEGIN
  IF NEW.status = 'pending' THEN
    PERFORM push_admins('💳 طلب شحن جديد', NEW.amount::text || ' ' || COALESCE(NEW.currency, '') || ' · ' || COALESCE(NEW.gateway, '') || v_what, '/admin-dashboard.html', 'pay-' || NEW.id::text);
  ELSIF NEW.status = 'completed' AND OLD.status IS DISTINCT FROM 'completed' THEN
    PERFORM push_admins('✅ شحن مؤكد', NEW.amount::text || ' ' || COALESCE(NEW.currency, '') || ' · ' || COALESCE(NEW.gateway, '') || v_what, '/admin-dashboard.html', 'pay-' || NEW.id::text);
  END IF;
  RETURN NEW;
END;
$$;

-- Order notifications, whichever way the order was paid (store wallet or a gateway).
CREATE OR REPLACE FUNCTION public.notify_on_store_order()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_old text := CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END;
  v_name text := coalesce(NEW.product_name, '') || CASE WHEN coalesce(NEW.plan_name, '') <> '' THEN ' - ' || NEW.plan_name ELSE '' END;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM v_old THEN RETURN NEW; END IF;

  IF NEW.status = 'paid' AND (v_old IS NULL OR v_old = 'pending_payment') THEN
    INSERT INTO public.notifications (user_id, type, title_ar, title_en, body_ar, body_en)
    VALUES (NEW.user_id, 'store_order', 'تم استلام طلبك 🛒', 'Order received 🛒',
            v_name || ' — هنجهزه ونبعتلك البيانات قريب في الأدوات الأكاديمية ← طلباتي.',
            v_name || ' — we are preparing it and will send the details soon in Academic Tools → My orders.');
    PERFORM push_user(NEW.user_id, '🛒 تم استلام طلبك', '🛒 Order received',
            v_name || ' — هنبعتلك البيانات قريب', v_name || ' — we will send the details soon',
            '/dashboard.html', 'store-' || NEW.id::text);
    PERFORM push_admins('🛒 طلب متجر محتاج تسليم', v_name || ' · ' || NEW.price_egp::text || ' ج.م', '/admin-dashboard.html', 'store-' || NEW.id::text);

  ELSIF NEW.status = 'delivered' AND (v_old IS NULL OR v_old = 'pending_payment') THEN
    INSERT INTO public.notifications (user_id, type, title_ar, title_en, body_ar, body_en)
    VALUES (NEW.user_id, 'store_delivery', 'طلبك جاهز ✅', 'Your order is ready ✅',
            v_name || ' — افتح الأدوات الأكاديمية ← طلباتي لعرض البيانات.',
            v_name || ' — open Academic Tools → My orders to view the details.');
    PERFORM push_user(NEW.user_id, '✅ طلبك جاهز', '✅ Your order is ready',
            v_name || ' — البيانات في الأدوات الأكاديمية ← طلباتي', v_name || ' — the details are in Academic Tools → My orders',
            '/dashboard.html', 'store-' || NEW.id::text);

  ELSIF NEW.status = 'delivered' AND v_old = 'paid' THEN
    -- Delivered by the admin: store_admin_deliver_subscription adds the in-app notification.
    PERFORM push_user(NEW.user_id, '✅ تم تسليم طلبك', '✅ Your order was delivered',
            v_name || ' — البيانات في الأدوات الأكاديمية ← طلباتي', v_name || ' — the details are in Academic Tools → My orders',
            '/dashboard.html', 'store-' || NEW.id::text);
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_notify_store_order ON public.store_orders;
CREATE TRIGGER trg_notify_store_order
AFTER INSERT OR UPDATE OF status ON public.store_orders
FOR EACH ROW EXECUTE FUNCTION public.notify_on_store_order();
