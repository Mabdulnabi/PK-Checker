-- 20261115020000_admin_views_notifications_redeem_revenue.sql

-- 1) Admin push for a finished order: show similarity AND AI (AI shows "*%" when the report hides the score).
CREATE OR REPLACE FUNCTION public.push_on_order_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_ai text;
BEGIN
  IF NEW.status = 'run' THEN
    PERFORM push_admins('📤 تم إرسال ملف للفحص', COALESCE(NEW.file_name, 'ملف'), '/admin-dashboard.html', 'order-' || NEW.id::text);
  ELSIF NEW.status = 'completed' THEN
    v_ai := CASE
      WHEN NEW.ai_report_url IS NULL THEN ''
      WHEN NEW.ai_score IS NULL THEN ' · AI *%'
      ELSE ' · AI ' || round(NEW.ai_score)::text || '%'
    END;
    PERFORM push_admins('✅ فحص ناجح',
      COALESCE(NEW.file_name, 'ملف') || ' · التشابه ' || COALESCE(round(NEW.similarity_score)::text, '?') || '%' || v_ai,
      '/admin-dashboard.html', 'order-' || NEW.id::text);
  ELSIF NEW.status IN ('error', 'rejected', 'failed_invalid') THEN
    PERFORM push_admins('❌ فشل الفحص', COALESCE(NEW.file_name, 'ملف') || ' — ' || COALESCE(NEW.error_reason, 'بدون سبب'), '/admin-dashboard.html', 'order-' || NEW.id::text);
  END IF;
  RETURN NEW;
END;
$function$;

-- 2) Customer e-mail on completion: the bearer token was written inside the function body.
--    Read it from the vault getter instead (same secret the other functions use).
DO $do$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef('public.notify_customer_email_on_order_completed()'::regprocedure) INTO v_def;
  v_def := replace(v_def,
    $tok$'Bearer gEEK6PTJzVh1Ve3eSu2b1q74nr1IEJb4FQvFhESuyTQ'$tok$,
    $tok$'Bearer ' || public.get_notif_webhook_secret()$tok$);
  EXECUTE v_def;
END;
$do$;

-- 3) Admin: the last 5 check operations of one customer (from the slot ledger, with the order).
CREATE OR REPLACE FUNCTION public.admin_customer_slot_history(p_user_id uuid)
RETURNS TABLE(created_at timestamptz, status text, slot_type text, display_id text, file_name text, check_type text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT su.created_at, su.status, su.slot_type, o.display_id, o.file_name, o.check_type
  FROM slot_usages su
  LEFT JOIN orders o ON o.id = su.order_id
  WHERE su.user_id = p_user_id AND public.is_admin()
  ORDER BY su.created_at DESC
  LIMIT 5;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_customer_slot_history(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_customer_slot_history(uuid) TO authenticated;

-- 4) Admin revenue: every redeemed voucher counts at its value, and its profit is value minus provider cost.
--    Packaged codes: price per slot x slots. Old codes without a package (wallet era): 5 EGP per credit,
--    with 20 credits per check as the cost basis (0.85 USD per check x 50 EGP).
CREATE OR REPLACE FUNCTION public.admin_redeem_ledger()
RETURNS TABLE(redeemed_at timestamptz, slots integer, revenue_egp numeric, cost_egp numeric, profit_egp numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT x.redeemed_at, x.slots, x.revenue_egp, x.cost_egp, round(x.revenue_egp - x.cost_egp, 2) AS profit_egp
  FROM (
    SELECT r.redeemed_at,
           r.credits AS slots,
           round(COALESCE(p.price_egp / NULLIF(p.slots, 0) * r.credits, r.credits * 5), 2) AS revenue_egp,
           round(COALESCE(p.provider_cost_usd * 50 * r.credits, (r.credits / 20.0) * 0.85 * 50), 2) AS cost_egp
    FROM redeem_codes r
    LEFT JOIN slot_packages p ON p.id = r.package_id
    WHERE r.redeemed_at IS NOT NULL
  ) x
  WHERE public.is_admin();
$$;

REVOKE EXECUTE ON FUNCTION public.admin_redeem_ledger() FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_redeem_ledger() TO authenticated;
