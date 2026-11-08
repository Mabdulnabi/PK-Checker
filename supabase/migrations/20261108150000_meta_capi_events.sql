-- Meta Conversions API: server-side Purchase and CompleteRegistration events.
-- The token lives in Vault as meta_capi_token; the edge function reads it with the service role.

CREATE OR REPLACE FUNCTION public.meta_get_token()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $$
  SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'meta_capi_token' LIMIT 1;
$$;
REVOKE ALL ON FUNCTION public.meta_get_token() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.meta_get_token() TO service_role;

CREATE OR REPLACE FUNCTION public.meta_send(p_event text, p_event_id text, p_user_id uuid, p_value numeric, p_currency text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'vault', 'net', 'auth'
AS $$
DECLARE
  v_secret text;
  v_email  text;
BEGIN
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'push_secret' LIMIT 1;
  IF v_secret IS NULL THEN RETURN; END IF;
  SELECT email INTO v_email FROM auth.users WHERE id = p_user_id;
  PERFORM net.http_post(
    url := 'https://ixpgqhwausnfjphitsty.supabase.co/functions/v1/meta-capi',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body := jsonb_build_object('event_name', p_event, 'event_id', p_event_id, 'email', v_email,
                               'external_id', p_user_id::text, 'value', p_value, 'currency', p_currency)
  );
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'meta_send failed: %', SQLERRM;
END;
$$;

CREATE OR REPLACE FUNCTION public.meta_on_payment_completed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  PERFORM meta_send('Purchase', 'purchase-' || NEW.id::text, NEW.user_id, NEW.amount,
                    CASE WHEN NEW.currency = 'USDT' THEN 'USD' ELSE COALESCE(NEW.currency, 'EGP') END);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_meta_purchase ON public.payments;
CREATE TRIGGER trg_meta_purchase AFTER UPDATE OF status ON public.payments
  FOR EACH ROW WHEN (NEW.status = 'completed' AND OLD.status IS DISTINCT FROM NEW.status)
  EXECUTE FUNCTION public.meta_on_payment_completed();

CREATE OR REPLACE FUNCTION public.meta_on_new_member()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  PERFORM meta_send('CompleteRegistration', 'reg-' || NEW.user_id::text, NEW.user_id, NULL, NULL);
  RETURN NEW;
END;
$$;
DROP TRIGGER IF EXISTS trg_meta_registration ON public.users_profile;
CREATE TRIGGER trg_meta_registration AFTER INSERT ON public.users_profile
  FOR EACH ROW EXECUTE FUNCTION public.meta_on_new_member();
