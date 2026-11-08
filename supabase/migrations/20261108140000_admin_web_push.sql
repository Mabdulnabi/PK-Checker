-- Admin web push: each admin device subscribes; the database sends an event for every important action.
-- Secrets (the webhook secret and the VAPID keys) live in Supabase Vault, never in the client code.

-- 1. Subscriptions (one row per device/browser)
CREATE TABLE IF NOT EXISTS public.admin_push_subscriptions (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_id    uuid NOT NULL DEFAULT auth.uid(),
  endpoint    text NOT NULL UNIQUE,
  p256dh      text NOT NULL,
  auth        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.admin_push_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS push_sub_select ON public.admin_push_subscriptions;
CREATE POLICY push_sub_select ON public.admin_push_subscriptions FOR SELECT TO authenticated
  USING (is_admin() AND admin_id = auth.uid());
DROP POLICY IF EXISTS push_sub_insert ON public.admin_push_subscriptions;
CREATE POLICY push_sub_insert ON public.admin_push_subscriptions FOR INSERT TO authenticated
  WITH CHECK (is_admin() AND admin_id = auth.uid());
DROP POLICY IF EXISTS push_sub_update ON public.admin_push_subscriptions;
CREATE POLICY push_sub_update ON public.admin_push_subscriptions FOR UPDATE TO authenticated
  USING (is_admin() AND admin_id = auth.uid()) WITH CHECK (is_admin() AND admin_id = auth.uid());
DROP POLICY IF EXISTS push_sub_delete ON public.admin_push_subscriptions;
CREATE POLICY push_sub_delete ON public.admin_push_subscriptions FOR DELETE TO authenticated
  USING (is_admin() AND admin_id = auth.uid());

-- 2. Secrets in Vault
CREATE OR REPLACE FUNCTION public.push_init_secrets()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'push_secret') THEN
    PERFORM vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'push_secret', 'admin push webhook secret');
  END IF;
END;
$$;
SELECT public.push_init_secrets();

-- Only the edge function (service role) reads the VAPID keys.
CREATE OR REPLACE FUNCTION public.push_set_vapid(p_public text, p_private text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.decrypted_secrets WHERE name = 'vapid_public') THEN
    PERFORM vault.create_secret(p_public, 'vapid_public', 'VAPID public key');
    PERFORM vault.create_secret(p_private, 'vapid_private', 'VAPID private key');
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.push_get_vapid()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $$
  SELECT jsonb_build_object(
    'public', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'vapid_public' LIMIT 1),
    'private', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'vapid_private' LIMIT 1));
$$;

CREATE OR REPLACE FUNCTION public.push_get_secret()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $$
  SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'push_secret' LIMIT 1;
$$;

REVOKE ALL ON FUNCTION public.push_set_vapid(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.push_get_vapid() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.push_get_secret() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_set_vapid(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.push_get_vapid() TO service_role;
GRANT EXECUTE ON FUNCTION public.push_get_secret() TO service_role;

-- 3. Sender: posts the event to the admin-push edge function. Never breaks the action that caused it.
CREATE OR REPLACE FUNCTION public.push_admins(p_title text, p_body text, p_url text, p_tag text)
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
    url := 'https://ixpgqhwausnfjphitsty.supabase.co/functions/v1/admin-push',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body := jsonb_build_object('title', p_title, 'body', p_body, 'url', p_url, 'tag', p_tag)
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'push_admins failed: %', SQLERRM;
END;
$$;

-- 4. Events
CREATE OR REPLACE FUNCTION public.push_on_new_member()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  PERFORM push_admins('👤 عميل جديد', COALESCE(NULLIF(NEW.full_name, ''), 'مستخدم جديد') || ' انضم للموقع',
                      '/admin-dashboard.html', 'new-member');
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_push_new_member ON public.users_profile;
CREATE TRIGGER trg_push_new_member AFTER INSERT ON public.users_profile
  FOR EACH ROW EXECUTE FUNCTION public.push_on_new_member();

CREATE OR REPLACE FUNCTION public.push_on_chat_message()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.sender_type IS DISTINCT FROM 'user' THEN RETURN NEW; END IF;
  PERFORM push_admins('💬 رسالة جديدة من ' || COALESCE(NULLIF(NEW.sender_name, ''), 'عميل'),
                      COALESCE(left(NEW.message, 120), 'ملف مرفق'),
                      '/admin-dashboard.html', 'chat-' || NEW.conversation_id::text);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_push_chat ON public.chat_messages;
CREATE TRIGGER trg_push_chat AFTER INSERT ON public.chat_messages
  FOR EACH ROW EXECUTE FUNCTION public.push_on_chat_message();

CREATE OR REPLACE FUNCTION public.push_on_ticket()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  PERFORM push_admins('🎫 تذكرة دعم جديدة', COALESCE(NEW.title, 'بدون عنوان'),
                      '/admin-dashboard.html', 'ticket-' || NEW.id::text);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_push_ticket ON public.support_tickets;
CREATE TRIGGER trg_push_ticket AFTER INSERT ON public.support_tickets
  FOR EACH ROW EXECUTE FUNCTION public.push_on_ticket();

CREATE OR REPLACE FUNCTION public.push_on_payment()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.status = 'pending' THEN
    PERFORM push_admins('💳 طلب شحن جديد',
                        NEW.amount::text || ' ' || COALESCE(NEW.currency, '') || ' · ' || COALESCE(NEW.gateway, ''),
                        '/admin-dashboard.html', 'pay-' || NEW.id::text);
  ELSIF NEW.status = 'completed' AND OLD.status IS DISTINCT FROM 'completed' THEN
    PERFORM push_admins('✅ شحن مؤكد',
                        NEW.amount::text || ' ' || COALESCE(NEW.currency, '') || ' · ' || COALESCE(NEW.gateway, ''),
                        '/admin-dashboard.html', 'pay-' || NEW.id::text);
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_push_payment_new ON public.payments;
CREATE TRIGGER trg_push_payment_new AFTER INSERT ON public.payments
  FOR EACH ROW WHEN (NEW.status = 'pending') EXECUTE FUNCTION public.push_on_payment();
DROP TRIGGER IF EXISTS trg_push_payment_done ON public.payments;
CREATE TRIGGER trg_push_payment_done AFTER UPDATE OF status ON public.payments
  FOR EACH ROW WHEN (NEW.status = 'completed' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.push_on_payment();

CREATE OR REPLACE FUNCTION public.push_on_order_status()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  IF NEW.status = 'run' THEN
    PERFORM push_admins('📤 تم إرسال ملف للفحص', COALESCE(NEW.file_name, 'ملف'),
                        '/admin-dashboard.html', 'order-' || NEW.id::text);
  ELSIF NEW.status = 'completed' THEN
    PERFORM push_admins('✅ فحص ناجح',
                        COALESCE(NEW.file_name, 'ملف') || ' · التشابه ' || COALESCE(NEW.similarity_score::text, '?') || '%',
                        '/admin-dashboard.html', 'order-' || NEW.id::text);
  ELSIF NEW.status IN ('error', 'rejected', 'failed_invalid') THEN
    PERFORM push_admins('❌ فشل الفحص', COALESCE(NEW.file_name, 'ملف') || ' — ' || COALESCE(NEW.error_reason, 'بدون سبب'),
                        '/admin-dashboard.html', 'order-' || NEW.id::text);
  END IF;
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_push_order_status ON public.orders;
CREATE TRIGGER trg_push_order_status AFTER UPDATE OF status ON public.orders
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status) EXECUTE FUNCTION public.push_on_order_status();
