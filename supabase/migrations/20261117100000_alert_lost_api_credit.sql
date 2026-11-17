-- 20261117100000_alert_lost_api_credit.sql
-- TurniScan sometimes takes a credit and then fails (an HTML "Fatal error ... PDOException" page) without
-- running the check. The customer's slot is already given back; the API credit is lost and can only be
-- refunded by TurniScan. Admins get a push as soon as it happens, so the credit can be claimed.

CREATE OR REPLACE FUNCTION public.push_on_lost_api_credit()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE v_code text;
BEGIN
  IF NEW.event = 'submit' AND NEW.api_delta IS NOT NULL AND NEW.api_delta < 0
     AND coalesce(NEW.note, '') NOT IN ('accepted', 'outcome unknown') THEN
    SELECT display_id INTO v_code FROM public.orders WHERE id = NEW.order_id;
    PERFORM push_admins(
      '⚠️ اتخصم فحص من TurniScan بدون ما يتقبل',
      'طلب ' || coalesce(v_code, left(NEW.order_id::text, 8)) || ': الرصيد ' || NEW.api_before || ' ← ' || NEW.api_after
        || '. العميل اترجعله الفحص. اطلب استرجاع الفحص من TurniScan (سجل الـ API في لوحة التحكم).',
      '/admin-dashboard.html', 'lost-api-credit-' || NEW.id);
  END IF;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'push_on_lost_api_credit failed: %', SQLERRM;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_push_lost_api_credit ON public.api_credit_log;
CREATE TRIGGER trg_push_lost_api_credit AFTER INSERT ON public.api_credit_log
  FOR EACH ROW EXECUTE FUNCTION public.push_on_lost_api_credit();
