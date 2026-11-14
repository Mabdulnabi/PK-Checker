-- 20261115030000_customer_notification_percentages.sql
-- Customer notifications (PWA push and in-app) show the similarity % and the AI % of a finished check.
-- AI shows "*%" when the AI report hides the score (under 20%). Similarity-only checks show no AI part.

-- 1) Score text for a finished order, in Arabic or English.
CREATE OR REPLACE FUNCTION public.order_scores_text(p_sim numeric, p_ai numeric, p_ai_url text, p_check_type text, p_lang text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $$
  SELECT concat_ws(' · ',
    CASE WHEN p_sim IS NOT NULL
         THEN (CASE WHEN p_lang = 'en' THEN 'Similarity ' ELSE 'التشابه ' END) || round(p_sim)::text || '%'
    END,
    CASE WHEN p_check_type IS DISTINCT FROM 'sim_only' AND p_ai_url IS NOT NULL
         THEN 'AI ' || COALESCE(round(p_ai)::text || '%', '*%')
    END
  );
$$;

-- 2) Customer PWA push when the check is ready (or has a problem).
CREATE OR REPLACE FUNCTION public.cpush_on_order_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status = 'completed' THEN
    PERFORM push_user(
      NEW.user_id,
      '✅ الفحص خلص', '✅ Your check is ready',
      concat_ws(' · ', COALESCE(NEW.file_name, 'ملفك'),
                order_scores_text(NEW.similarity_score, NEW.ai_score, NEW.ai_report_url, NEW.check_type, 'ar'),
                'افتح النتيجة'),
      concat_ws(' · ', COALESCE(NEW.file_name, 'Your file'),
                order_scores_text(NEW.similarity_score, NEW.ai_score, NEW.ai_report_url, NEW.check_type, 'en'),
                'open your result'),
      '/dashboard.html', 'order-' || NEW.id::text);
  ELSIF NEW.status IN ('error', 'rejected', 'failed_invalid') THEN
    PERFORM push_user(NEW.user_id, '⚠️ في مشكلة في الفحص', '⚠️ There was a problem with your check', COALESCE(NEW.file_name, 'ملفك') || ' · افتح ملفاتي للتفاصيل', COALESCE(NEW.file_name, 'Your file') || ' · open My Files for details', '/dashboard.html', 'order-' || NEW.id::text);
  END IF;
  RETURN NEW;
END;
$function$;

-- 3) In-app notification when the order status changes (the bell in the dashboard).
CREATE OR REPLACE FUNCTION public.notify_on_order_status_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'completed' THEN
    INSERT INTO notifications (user_id, type, title_ar, title_en, body_ar, body_en, related_order_id)
    VALUES (
      NEW.user_id, 'order_completed',
      'طلبك جاهز', 'Your order is complete',
      concat_ws(' — ', NEW.file_name,
                NULLIF(order_scores_text(NEW.similarity_score, NEW.ai_score, NEW.ai_report_url, NEW.check_type, 'ar'), ''),
                'التقرير جاهز للتحميل الآن.'),
      concat_ws(' — ', NEW.file_name,
                NULLIF(order_scores_text(NEW.similarity_score, NEW.ai_score, NEW.ai_report_url, NEW.check_type, 'en'), ''),
                'the report is ready to download now.'),
      NEW.id
    );
  ELSIF NEW.status = 'error' OR NEW.status = 'failed_invalid' THEN
    INSERT INTO notifications (user_id, type, title_ar, title_en, body_ar, body_en, related_order_id)
    VALUES (
      NEW.user_id, 'order_rejected',
      'تم رفض طلبك', 'Your order was rejected',
      NEW.file_name || ' — تم رفض الطلب وإعادة الكريديت إلى رصيدك.',
      NEW.file_name || ' — the order was rejected and credits were refunded.',
      NEW.id
    );
  ELSIF NEW.status = 'pending' OR NEW.status = 'processing' THEN
    INSERT INTO notifications (user_id, type, title_ar, title_en, body_ar, body_en, related_order_id)
    VALUES (
      NEW.user_id, 'order_processing',
      'طلبك قيد الفحص', 'Your order is processing',
      NEW.file_name || ' — بدأ الفحص الآن، النتيجة خلال دقائق.',
      NEW.file_name || ' — processing started, results in a few minutes.',
      NEW.id
    );
  END IF;

  RETURN NEW;
END;
$function$;
