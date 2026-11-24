-- Developer API (phase 1): customers connect their own site to PK Checker with an API key.
-- Same shape as TurniScan's API (POST /v1/scan/submit, GET /v1/scan/status, GET /v1/scan/download,
-- GET /v1/account/balance), served by the pk-api edge function. Each file is charged one check from
-- the customer's own balance, like a file sent from the site.
-- While in testing, keys can be created only by testing accounts (tester_accounts, PK001).

-- Keys: only a SHA-256 hash is stored; the key itself is shown once, when it is created.
CREATE TABLE IF NOT EXISTS public.api_keys (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name         text NOT NULL DEFAULT 'API key',
  key_hash     text NOT NULL UNIQUE,
  key_prefix   text NOT NULL,          -- first characters, to tell keys apart
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);
CREATE INDEX IF NOT EXISTS api_keys_user_idx ON public.api_keys (user_id);
ALTER TABLE public.api_keys ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS api_keys_read_own ON public.api_keys;
CREATE POLICY api_keys_read_own ON public.api_keys
  FOR SELECT TO authenticated USING (user_id = auth.uid() OR public.is_admin());
-- No insert/update/delete policies: keys are made and revoked through the functions below.

-- Requests per key and minute (60 a minute, like TurniScan).
CREATE TABLE IF NOT EXISTS public.api_rate (
  key_id  uuid NOT NULL REFERENCES public.api_keys(id) ON DELETE CASCADE,
  minute  timestamptz NOT NULL,
  hits    integer NOT NULL DEFAULT 0,
  PRIMARY KEY (key_id, minute)
);
ALTER TABLE public.api_rate ENABLE ROW LEVEL SECURITY;   -- server only

-- Orders made through the API.
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS source text NOT NULL DEFAULT 'web';
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS api_key_id uuid REFERENCES public.api_keys(id) ON DELETE SET NULL;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS custom_id text;

-- Who may use the API right now (testing: tester accounts only).
CREATE OR REPLACE FUNCTION public.api_access_allowed(p_user uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$ SELECT EXISTS (SELECT 1 FROM tester_accounts t WHERE t.user_id = p_user); $$;

-- A new key for the signed-in customer. Returns the key once; only its hash is kept. Up to 5 active keys.
CREATE OR REPLACE FUNCTION public.create_api_key(p_name text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
DECLARE v_key text; v_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'NOT_SIGNED_IN'; END IF;
  IF NOT public.api_access_allowed(auth.uid()) THEN RAISE EXCEPTION 'API_NOT_AVAILABLE'; END IF;
  IF (SELECT count(*) FROM api_keys WHERE user_id = auth.uid() AND revoked_at IS NULL) >= 5 THEN
    RAISE EXCEPTION 'TOO_MANY_KEYS';
  END IF;
  v_key := 'pk_live_' || encode(gen_random_bytes(24), 'hex');
  INSERT INTO api_keys (user_id, name, key_hash, key_prefix)
  VALUES (auth.uid(), left(coalesce(nullif(trim(p_name), ''), 'API key'), 60), encode(digest(v_key, 'sha256'), 'hex'), left(v_key, 14))
  RETURNING id INTO v_id;
  RETURN jsonb_build_object('id', v_id, 'key', v_key, 'prefix', left(v_key, 14));
END;
$$;

CREATE OR REPLACE FUNCTION public.revoke_api_key(p_id uuid)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
BEGIN
  UPDATE api_keys SET revoked_at = now()
   WHERE id = p_id AND revoked_at IS NULL AND (user_id = auth.uid() OR public.is_admin());
  RETURN FOUND;
END;
$$;

-- Server side (pk-api): the key's owner, and one request counted. Returns NULL for an unknown,
-- revoked or not-allowed key; 'rate' = over 60 requests this minute.
CREATE OR REPLACE FUNCTION public.api_key_check(p_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $$
DECLARE v record; v_hits integer;
BEGIN
  SELECT id, user_id INTO v FROM api_keys
   WHERE key_hash = encode(digest(p_key, 'sha256'), 'hex') AND revoked_at IS NULL;
  IF NOT FOUND OR NOT public.api_access_allowed(v.user_id) THEN RETURN NULL; END IF;
  INSERT INTO api_rate (key_id, minute, hits) VALUES (v.id, date_trunc('minute', now()), 1)
  ON CONFLICT (key_id, minute) DO UPDATE SET hits = api_rate.hits + 1
  RETURNING hits INTO v_hits;
  UPDATE api_keys SET last_used_at = now() WHERE id = v.id;
  DELETE FROM api_rate WHERE minute < now() - interval '1 hour';
  RETURN jsonb_build_object('key_id', v.id, 'user_id', v.user_id, 'rate', v_hits > 60);
END;
$$;
REVOKE ALL ON FUNCTION public.api_key_check(text) FROM PUBLIC, anon, authenticated;

-- Balance in TurniScan's shape: checks left in active packages (both types).
CREATE OR REPLACE FUNCTION public.api_balance(p_user uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $$
  WITH g AS (
    SELECT g.slot_type, g.slots_total,
           (SELECT count(*) FROM slot_usages u WHERE u.grant_id = g.id AND u.status = 'reserved')::int AS used
    FROM customer_slot_grants g
    WHERE g.user_id = p_user AND (g.expires_at IS NULL OR g.expires_at > now())
  )
  SELECT jsonb_build_object(
    'total_credits', coalesce(sum(slots_total), 0)::int,
    'used_credits', coalesce(sum(least(used, slots_total)), 0)::int,
    'available_credits', coalesce(sum(greatest(0, slots_total - used)), 0)::int,
    'plag_ai_available', coalesce(sum(greatest(0, slots_total - used)) FILTER (WHERE slot_type = 'plag_ai'), 0)::int,
    'plag_only_available', coalesce(sum(greatest(0, slots_total - used)) FILTER (WHERE slot_type = 'plag_only'), 0)::int)
  FROM g;
$$;
REVOKE ALL ON FUNCTION public.api_balance(uuid) FROM PUBLIC, anon, authenticated;
