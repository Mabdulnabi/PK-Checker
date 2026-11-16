-- 20261116030000_meta_browser_ids.sql
-- Server events (Purchase, CompleteRegistration) carry the visitor's browser IDs so Meta can match them:
-- fbp / fbc cookies, user agent and IP. They are saved by the dashboard only after the visitor accepts
-- cookies. Registration is queued and sent once those IDs arrive (or after 10 minutes without them).

CREATE TABLE IF NOT EXISTS public.meta_browser_ids (
  user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  fbp        text,
  fbc        text,
  user_agent text,
  ip         text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.meta_browser_ids ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.meta_browser_ids FROM anon, authenticated;

CREATE TABLE IF NOT EXISTS public.meta_pending_events (
  id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  event_name text NOT NULL,
  event_id   text NOT NULL UNIQUE,
  value      numeric,
  currency   text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS meta_pending_events_user_idx ON public.meta_pending_events (user_id);
ALTER TABLE public.meta_pending_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.meta_pending_events FROM anon, authenticated;

-- Sends one event to the meta-capi function, with the browser IDs saved for that user (if any).
CREATE OR REPLACE FUNCTION public.meta_send(p_event text, p_event_id text, p_user_id uuid, p_value numeric, p_currency text,
                                            p_event_time timestamptz DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'vault', 'net', 'auth'
AS $function$
DECLARE v_secret text; v_email text; v_fbp text; v_fbc text; v_ua text; v_ip text;
BEGIN
  SELECT decrypted_secret INTO v_secret FROM vault.decrypted_secrets WHERE name = 'push_secret' LIMIT 1;
  IF v_secret IS NULL THEN RETURN; END IF;
  SELECT email INTO v_email FROM auth.users WHERE id = p_user_id;
  SELECT fbp, fbc, user_agent, ip INTO v_fbp, v_fbc, v_ua, v_ip FROM public.meta_browser_ids WHERE user_id = p_user_id;
  PERFORM net.http_post(
    url := 'https://ixpgqhwausnfjphitsty.supabase.co/functions/v1/meta-capi',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret),
    body := jsonb_strip_nulls(jsonb_build_object(
      'event_name', p_event, 'event_id', p_event_id, 'email', v_email, 'external_id', p_user_id::text,
      'value', p_value, 'currency', p_currency,
      'event_time', CASE WHEN p_event_time IS NOT NULL THEN floor(extract(epoch FROM p_event_time))::bigint END,
      'fbp', v_fbp, 'fbc', v_fbc, 'client_user_agent', v_ua, 'client_ip_address', v_ip)));
EXCEPTION WHEN OTHERS THEN RAISE WARNING 'meta_send failed: %', SQLERRM;
END;
$function$;
DROP FUNCTION IF EXISTS public.meta_send(text, text, uuid, numeric, text);
REVOKE EXECUTE ON FUNCTION public.meta_send(text, text, uuid, numeric, text, timestamptz) FROM PUBLIC, anon, authenticated;

-- New member: queued, so it can go out with the browser IDs the dashboard saves a moment later.
CREATE OR REPLACE FUNCTION public.meta_on_new_member()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  INSERT INTO public.meta_pending_events (user_id, event_name, event_id)
  VALUES (NEW.user_id, 'CompleteRegistration', 'reg-' || NEW.user_id::text)
  ON CONFLICT (event_id) DO NOTHING;
  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'meta_on_new_member failed: %', SQLERRM;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION public.meta_on_payment_completed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM meta_send('Purchase', 'purchase-' || NEW.id::text, NEW.user_id, NEW.amount,
                    CASE WHEN NEW.currency = 'USDT' THEN 'USD' ELSE COALESCE(NEW.currency, 'EGP') END);
  RETURN NEW;
END;
$function$;

-- Sends and removes queued events: one user's (p_user_id), or everyone's older than p_older_than.
CREATE OR REPLACE FUNCTION public.meta_flush_pending(p_user_id uuid DEFAULT NULL, p_older_than interval DEFAULT NULL)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE e record; n int := 0;
BEGIN
  -- SKIP LOCKED: two flushes running at once never send the same event twice.
  FOR e IN
    SELECT * FROM public.meta_pending_events
    WHERE (p_user_id IS NOT NULL AND user_id = p_user_id)
       OR (p_user_id IS NULL AND p_older_than IS NOT NULL AND created_at < now() - p_older_than)
    ORDER BY id
    FOR UPDATE SKIP LOCKED
  LOOP
    DELETE FROM public.meta_pending_events WHERE id = e.id;
    PERFORM public.meta_send(e.event_name, e.event_id, e.user_id, e.value, e.currency, e.created_at);
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.meta_flush_pending(uuid, interval) FROM PUBLIC, anon, authenticated;

-- Called by the dashboard. With consent it saves the browser IDs (plus user agent and IP from the
-- request); without consent it saves nothing. Either way the user's queued events are sent.
CREATE OR REPLACE FUNCTION public.meta_save_browser_ids(p_fbp text DEFAULT NULL, p_fbc text DEFAULT NULL, p_user_agent text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
DECLARE
  uid uuid := auth.uid();
  h json;
  v_ip text;
  v_fbp text := nullif(trim(p_fbp), '');
  v_fbc text := nullif(trim(p_fbc), '');
  v_ua text := left(nullif(trim(p_user_agent), ''), 512);
BEGIN
  IF uid IS NULL THEN RETURN; END IF;
  IF v_fbp IS NOT NULL AND v_fbp !~ '^fb\.\d\.\d{10,16}\.\d{1,30}$' THEN v_fbp := NULL; END IF;
  IF v_fbc IS NOT NULL AND (v_fbc !~ '^fb\.\d\.\d{10,16}\.[A-Za-z0-9_-]+$' OR length(v_fbc) > 500) THEN v_fbc := NULL; END IF;
  IF v_fbp IS NOT NULL OR v_fbc IS NOT NULL THEN
    BEGIN h := current_setting('request.headers', true)::json; EXCEPTION WHEN OTHERS THEN h := NULL; END;
    v_ip := trim(split_part(coalesce(h->>'cf-connecting-ip', h->>'x-real-ip', h->>'x-forwarded-for', ''), ',', 1));
    IF v_ip !~ '^[0-9a-fA-F:.]{3,45}$' THEN v_ip := NULL; END IF;
    INSERT INTO public.meta_browser_ids AS m (user_id, fbp, fbc, user_agent, ip, updated_at)
    VALUES (uid, v_fbp, v_fbc, v_ua, v_ip, now())
    ON CONFLICT (user_id) DO UPDATE SET
      fbp = coalesce(EXCLUDED.fbp, m.fbp), fbc = coalesce(EXCLUDED.fbc, m.fbc),
      user_agent = coalesce(EXCLUDED.user_agent, m.user_agent), ip = coalesce(EXCLUDED.ip, m.ip), updated_at = now();
  END IF;
  PERFORM public.meta_flush_pending(uid, NULL);
END;
$function$;
REVOKE EXECUTE ON FUNCTION public.meta_save_browser_ids(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.meta_save_browser_ids(text, text, text) TO authenticated;

-- Registrations whose dashboard never saved IDs still go out, 10 minutes later.
DO $$ BEGIN
  PERFORM cron.unschedule('meta-flush-pending') WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'meta-flush-pending');
  PERFORM cron.schedule('meta-flush-pending', '*/5 * * * *', $c$SELECT public.meta_flush_pending(NULL, interval '10 minutes')$c$);
END $$;
