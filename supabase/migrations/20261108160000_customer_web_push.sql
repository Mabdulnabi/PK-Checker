-- Customer web push: each customer's device subscribes from My Account.
-- Events: check finished or failed, top-up confirmed, admin reply in live chat, admin reply to a ticket.

CREATE TABLE IF NOT EXISTS public.customer_push_subscriptions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL DEFAULT auth.uid(),
  endpoint    text NOT NULL UNIQUE,
  p256dh      text NOT NULL,
  auth        text NOT NULL,
  lang        text NOT NULL DEFAULT 'ar',
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.customer_push_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS cps_own_select ON public.customer_push_subscriptions;
CREATE POLICY cps_own_select ON public.customer_push_subscriptions FOR SELECT TO authenticated USING (user_id = auth.uid());
DROP POLICY IF EXISTS cps_own_insert ON public.customer_push_subscriptions;
CREATE POLICY cps_own_insert ON public.customer_push_subscriptions FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS cps_own_update ON public.customer_push_subscriptions;
CREATE POLICY cps_own_update ON public.customer_push_subscriptions FOR UPDATE TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
DROP POLICY IF EXISTS cps_own_delete ON public.customer_push_subscriptions;
CREATE POLICY cps_own_delete ON public.customer_push_subscriptions FOR DELETE TO authenticated USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION public.push_user(p_user_id uuid, p_title_ar text, p_title_en text, p_body_ar text, p_body_en text, p_url text, p_tag text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault', 'net'
AS $$
DECLARE
  v_secret text;
BEGIN
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'push_secret' LIMIT 1;
  IF v_secret IS NULL THEN RETURN; END IF;
  PERFORM net.http_post(
    url := 'https://ixpgqhwausnfjphitsty.supabase.co/functions/v1/customer-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body := jsonb_build_object('user_id', p_user_id, 'title_ar', p_title_ar, 'title_en', p_title_en,
                               'body_ar', p_body_ar, 'body_en', p_body_en, 'url', p_url, 'tag', p_tag)
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'push_user failed: %', SQLERRM;
END;
$$;

CREATE OR REPLACE FUNCTION public.cpush_on_order_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.status = 'completed' THEN
    PERFORM push_user(NEW.user_id, '✅ الفحص خلص', '✅ Your check is ready',
      COALESCE(NEW.file_name, 'ملفك') || ' · افتح النتيجة', COALESCE(NEW.file_name, 'Your file') || ' · open your result',
      '/dashboard.html', 'order-' || NEW.id::text);
  ELSIF NEW.status IN ('error', 'rejected', 'failed_invalid') THEN
    PERFORM push_user(NEW.user_id, '⚠️ في مشكلة في الفحص', '⚠️ There was a problem with your check',
      COALESCE(NEW.file_name, 'ملفك') || ' · افتح ملفاتي للتفاصيل', COALESCE(NEW.file_name, 'Your file') || ' · open My Files for details',
      '/dashboard.html', 'order-' || NEW.id::text);
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_cpush_order ON public.orders;
CREATE TRIGGER trg_cpush_order AFTER UPDATE OF status ON public.orders
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION public.cpush_on_order_status();

CREATE OR REPLACE FUNCTION public.cpush_on_payment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  PERFORM push_user(NEW.user_id, '💳 تم شحن رصيدك', '💳 Your balance was topped up',
    'تمت إضافة الفحوصات لحسابك', 'Checks were added to your account',
    '/dashboard.html', 'pay-' || NEW.id::text);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_cpush_payment ON public.payments;
CREATE TRIGGER trg_cpush_payment AFTER UPDATE OF status ON public.payments
  FOR EACH ROW WHEN (NEW.status = 'completed' AND OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION public.cpush_on_payment();

CREATE OR REPLACE FUNCTION public.cpush_on_chat_reply()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE v_user uuid;
BEGIN
  IF NEW.sender_type IS DISTINCT FROM 'admin' THEN RETURN NEW; END IF;
  SELECT user_id INTO v_user FROM chat_conversations WHERE id = NEW.conversation_id;
  IF v_user IS NULL THEN RETURN NEW; END IF;
  PERFORM push_user(v_user, '💬 رد جديد من الدعم', '💬 New reply from support',
    COALESCE(left(NEW.message, 120), 'ملف مرفق'), COALESCE(left(NEW.message, 120), 'Attachment'),
    '/dashboard.html', 'chat-' || NEW.conversation_id::text);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_cpush_chat ON public.chat_messages;
CREATE TRIGGER trg_cpush_chat AFTER INSERT ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION public.cpush_on_chat_reply();

CREATE OR REPLACE FUNCTION public.cpush_on_ticket_reply()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  PERFORM push_user(NEW.user_id, '🎫 رد على تذكرتك', '🎫 Reply to your ticket',
    COALESCE(NEW.title, 'تذكرتك'), COALESCE(NEW.title, 'Your ticket'),
    '/dashboard.html', 'ticket-' || NEW.id::text);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_cpush_ticket ON public.support_tickets;
CREATE TRIGGER trg_cpush_ticket AFTER UPDATE OF admin_reply ON public.support_tickets
  FOR EACH ROW WHEN (NEW.admin_reply IS NOT NULL AND NEW.admin_reply IS DISTINCT FROM OLD.admin_reply)
  EXECUTE FUNCTION public.cpush_on_ticket_reply();
