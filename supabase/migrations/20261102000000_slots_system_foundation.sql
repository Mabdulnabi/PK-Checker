-- ============================================================
-- Slots system: foundation (additive only).
-- Nothing here changes existing behaviour: confirm_topup, redeem_code and
-- the check flow still use credits until the new Check tab ships together
-- with the switch migration. Credits are converted by plan_credit_migration()
-- (read-only) and, after review, by migrate_credits_to_slots().
-- ============================================================

-- 1. Packages (managed from the admin Slots tab)
CREATE TABLE IF NOT EXISTS public.slot_packages (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slot_type       text NOT NULL CHECK (slot_type IN ('plag_ai', 'plag_only')),
  slots           integer NOT NULL CHECK (slots > 0),
  price_egp       numeric(12,2) NOT NULL CHECK (price_egp >= 0),
  expiry_days     integer CHECK (expiry_days IS NULL OR expiry_days > 0), -- NULL = never expires
  name_ar         text NOT NULL,
  name_en         text NOT NULL,
  is_active       boolean NOT NULL DEFAULT true,
  sort_order      integer NOT NULL DEFAULT 0,
  legacy_pack_id  text UNIQUE,           -- id of the old TOPUP_PACKS entry this row replaces
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Seed the four current Plagiarism + AI packs so existing sales keep the same
-- price, file count and validity.
INSERT INTO public.slot_packages (slot_type, slots, price_egp, expiry_days, name_ar, name_en, sort_order, legacy_pack_id)
VALUES
  ('plag_ai', 1,  100,  2,    'باقة فحص واحد',   'Single check',  1, 'pack_1'),
  ('plag_ai', 5,  480,  5,    'باقة 5 فحوصات',   '5 checks',      2, 'pack_5'),
  ('plag_ai', 10, 950,  10,   'باقة 10 فحوصات',  '10 checks',     3, 'pack_10'),
  ('plag_ai', 25, 2300, 15,   'باقة 25 فحص',     '25 checks',     4, 'pack_25')
ON CONFLICT (legacy_pack_id) DO NOTHING;

-- 2. Grants: slots a customer owns, one row per purchase / redeem / migration
CREATE TABLE IF NOT EXISTS public.customer_slot_grants (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  package_id   uuid REFERENCES public.slot_packages(id) ON DELETE SET NULL,
  slot_type    text NOT NULL CHECK (slot_type IN ('plag_ai', 'plag_only')),
  slots_total  integer NOT NULL CHECK (slots_total > 0),
  granted_at   timestamptz NOT NULL,      -- original purchase time, never the migration time
  expires_at   timestamptz,               -- NULL = never expires
  source       text NOT NULL CHECK (source IN ('purchase', 'redeem', 'migration', 'admin')),
  source_ref   text,                      -- payment id, redeem code id, or credit tx id
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (source, source_ref)             -- the same purchase or conversion can't be granted twice
);
CREATE INDEX IF NOT EXISTS idx_slot_grants_user ON public.customer_slot_grants (user_id, slot_type);

-- 3. Usages: one row per check that reserved a slot
CREATE TABLE IF NOT EXISTS public.slot_usages (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  grant_id         uuid NOT NULL REFERENCES public.customer_slot_grants(id) ON DELETE RESTRICT,
  slot_type        text NOT NULL CHECK (slot_type IN ('plag_ai', 'plag_only')),
  order_id         uuid,
  idempotency_key  text NOT NULL UNIQUE,  -- a retry with the same key never reserves twice
  status           text NOT NULL DEFAULT 'reserved' CHECK (status IN ('reserved', 'released')),
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_slot_usages_grant ON public.slot_usages (grant_id) WHERE status = 'reserved';

-- 4. RLS: customers read their own rows, admins read everything. Writes only via RPCs.
ALTER TABLE public.slot_packages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.customer_slot_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.slot_usages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "active packages readable" ON public.slot_packages;
CREATE POLICY "active packages readable" ON public.slot_packages
  FOR SELECT TO anon, authenticated USING (is_active OR public.is_admin());

DROP POLICY IF EXISTS "admins manage packages" ON public.slot_packages;
CREATE POLICY "admins manage packages" ON public.slot_packages
  FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS "own or admin grants" ON public.customer_slot_grants;
CREATE POLICY "own or admin grants" ON public.customer_slot_grants
  FOR SELECT TO authenticated USING (user_id = auth.uid() OR public.is_admin());

DROP POLICY IF EXISTS "own or admin usages" ON public.slot_usages;
CREATE POLICY "own or admin usages" ON public.slot_usages
  FOR SELECT TO authenticated USING (user_id = auth.uid() OR public.is_admin());

REVOKE ALL ON public.customer_slot_grants FROM anon, authenticated;
REVOKE ALL ON public.slot_usages FROM anon, authenticated;
GRANT SELECT ON public.customer_slot_grants TO authenticated;
GRANT SELECT ON public.slot_usages TO authenticated;
GRANT SELECT ON public.slot_packages TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.slot_packages TO authenticated; -- still gated by the RLS policy above

-- 5. Customer summary: what the Check tab cards and the file dropdown show.
CREATE OR REPLACE FUNCTION public.slot_summary()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH live AS (
    SELECT g.id, g.slot_type, g.expires_at, g.granted_at,
           g.slots_total - COALESCE((
             SELECT count(*) FROM slot_usages u
             WHERE u.grant_id = g.id AND u.status = 'reserved'
           ), 0) AS remaining,
           p.name_ar, p.name_en
    FROM customer_slot_grants g
    LEFT JOIN slot_packages p ON p.id = g.package_id
    WHERE g.user_id = auth.uid()
      AND (g.expires_at IS NULL OR g.expires_at > now())
  )
  SELECT jsonb_build_object(
    'by_type', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'slot_type', t.slot_type,
               'remaining', t.remaining,
               'next_expires_at', t.next_expires_at,
               'unlimited', t.unlimited) ORDER BY t.slot_type)
      FROM (
        SELECT l.slot_type,
               sum(l.remaining) AS remaining,
               min(l.expires_at) FILTER (WHERE l.remaining > 0) AS next_expires_at,
               bool_or(l.expires_at IS NULL AND l.remaining > 0) AS unlimited
        FROM live l
        GROUP BY l.slot_type
      ) t
    ), '[]'::jsonb),
    'grants', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'grant_id', l.id,
               'slot_type', l.slot_type,
               'remaining', l.remaining,
               'expires_at', l.expires_at,
               'name_ar', l.name_ar,
               'name_en', l.name_en) ORDER BY l.expires_at ASC NULLS LAST, l.granted_at)
      FROM live l
      WHERE l.remaining > 0
    ), '[]'::jsonb)
  );
$$;

REVOKE EXECUTE ON FUNCTION public.slot_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.slot_summary() TO authenticated;

-- 6. Reserve one slot for a check. Service role only: the edge function
-- verifies the user and the API first, then calls this.
-- Earliest-expiring grant of the requested type goes first, and rows are
-- locked so two requests can't take the same last slot.
CREATE OR REPLACE FUNCTION public.reserve_slot(
  p_user_id uuid, p_slot_type text, p_idempotency_key text, p_order_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_usage     slot_usages%ROWTYPE;
  v_grant     customer_slot_grants%ROWTYPE;
  v_reserved  integer;
BEGIN
  IF p_slot_type NOT IN ('plag_ai', 'plag_only') THEN RAISE EXCEPTION 'INVALID_SLOT_TYPE'; END IF;
  IF p_idempotency_key IS NULL OR length(p_idempotency_key) < 8 THEN RAISE EXCEPTION 'INVALID_IDEMPOTENCY_KEY'; END IF;

  -- Same request retried: return the existing reservation, never reserve twice.
  SELECT * INTO v_usage FROM slot_usages WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_usage.user_id <> p_user_id THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
    RETURN jsonb_build_object('usage_id', v_usage.id, 'grant_id', v_usage.grant_id,
                              'status', v_usage.status, 'replayed', true);
  END IF;

  FOR v_grant IN
    SELECT g.* FROM customer_slot_grants g
    WHERE g.user_id = p_user_id
      AND g.slot_type = p_slot_type
      AND (g.expires_at IS NULL OR g.expires_at > now())
    ORDER BY g.expires_at ASC NULLS LAST, g.granted_at ASC
    FOR UPDATE
  LOOP
    SELECT count(*) INTO v_reserved FROM slot_usages u
    WHERE u.grant_id = v_grant.id AND u.status = 'reserved';

    IF v_grant.slots_total - v_reserved > 0 THEN
      INSERT INTO slot_usages (user_id, grant_id, slot_type, order_id, idempotency_key)
      VALUES (p_user_id, v_grant.id, p_slot_type, p_order_id, p_idempotency_key)
      RETURNING * INTO v_usage;
      RETURN jsonb_build_object('usage_id', v_usage.id, 'grant_id', v_grant.id,
                                'status', 'reserved', 'replayed', false);
    END IF;
  END LOOP;

  RAISE EXCEPTION 'NO_SLOT_AVAILABLE';
END;
$$;

-- Release a reservation when the check was never accepted by the provider.
CREATE OR REPLACE FUNCTION public.release_slot(p_idempotency_key text)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH r AS (
    UPDATE slot_usages SET status = 'released', updated_at = now()
    WHERE idempotency_key = p_idempotency_key AND status = 'reserved'
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM r);
$$;

REVOKE EXECUTE ON FUNCTION public.reserve_slot(uuid, text, text, uuid) FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.release_slot(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_slot(uuid, text, text, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.release_slot(text) TO service_role;

-- 7. Grant slots from a package. The expiry is counted from granted_at (the
-- original purchase time), so a conversion never resets the validity.
CREATE OR REPLACE FUNCTION public.grant_slots(
  p_user_id uuid, p_package_id uuid, p_source text, p_source_ref text, p_granted_at timestamptz,
  p_expires_override timestamptz DEFAULT NULL, p_override_set boolean DEFAULT false
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pkg   slot_packages%ROWTYPE;
  v_id    uuid;
  v_exp   timestamptz;
BEGIN
  SELECT * INTO v_pkg FROM slot_packages WHERE id = p_package_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PACKAGE_NOT_FOUND'; END IF;

  IF p_override_set THEN
    v_exp := p_expires_override;
  ELSIF v_pkg.expiry_days IS NULL THEN
    v_exp := NULL;
  ELSE
    v_exp := p_granted_at + make_interval(days => v_pkg.expiry_days);
  END IF;

  INSERT INTO customer_slot_grants (user_id, package_id, slot_type, slots_total, granted_at, expires_at, source, source_ref)
  VALUES (p_user_id, v_pkg.id, v_pkg.slot_type, v_pkg.slots, p_granted_at, v_exp, p_source, p_source_ref)
  ON CONFLICT (source, source_ref) DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id;  -- NULL when this source_ref was already granted
END;
$$;

REVOKE EXECUTE ON FUNCTION public.grant_slots(uuid, uuid, text, text, timestamptz, timestamptz, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.grant_slots(uuid, uuid, text, text, timestamptz, timestamptz, boolean) TO service_role;

-- 8. Conversion plan (read-only). For each customer it replays the wallet in
-- time order, applies debits to the oldest credits first (FIFO), and reports
-- what remains per credit batch, converted at 20 credits = 1 Plagiarism + AI slot.
-- Each batch is matched to its completed payment, so the package and the
-- original purchase date come from that payment.
CREATE OR REPLACE FUNCTION public.plan_credit_migration()
RETURNS TABLE (
  pk_number         integer,
  user_id           uuid,
  batch_tx_id       uuid,
  batch_at          timestamptz,
  batch_credits     numeric,
  remaining_credits numeric,
  slots             integer,
  leftover_credits  numeric,
  payment_id        uuid,
  package_id        uuid,
  expires_at        timestamptz,
  note              text
)
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  u           record;
  tx          record;
  b           record;
  v_debit     numeric;
  v_take      numeric;
  v_pay       record;
  v_pkg       slot_packages%ROWTYPE;
  v_max_days  integer;
  v_last_bal  numeric;
BEGIN
  SELECT max(expiry_days) INTO v_max_days FROM slot_packages WHERE is_active;

  FOR u IN
    SELECT pn.user_id, pn.pk_number FROM users_profile_numbered pn
    WHERE EXISTS (SELECT 1 FROM wallet_transactions w WHERE w.user_id = pn.user_id)
  LOOP
    CREATE TEMP TABLE IF NOT EXISTS _mig_batches (
      tx_id uuid PRIMARY KEY, batch_ts timestamptz, remaining numeric
    ) ON COMMIT DROP;
    DELETE FROM _mig_batches;

    FOR tx IN
      SELECT w.id, w.type, w.amount, w.description, w.created_at, w.balance_after
      FROM wallet_transactions w WHERE w.user_id = u.user_id
      ORDER BY w.created_at, w.id
    LOOP
      IF tx.type IN ('credit', 'admin_credit', 'refund') THEN
        INSERT INTO _mig_batches VALUES (tx.id, tx.created_at, tx.amount)
        ON CONFLICT (tx_id) DO NOTHING;
      ELSIF tx.type IN ('debit', 'expiry') THEN
        v_debit := tx.amount;
        FOR b IN SELECT * FROM _mig_batches mb WHERE mb.remaining > 0 ORDER BY mb.batch_ts, mb.tx_id LOOP
          EXIT WHEN v_debit <= 0;
          v_take := LEAST(b.remaining, v_debit);
          UPDATE _mig_batches mb SET remaining = mb.remaining - v_take WHERE mb.tx_id = b.tx_id;
          v_debit := v_debit - v_take;
        END LOOP;
      END IF;
      v_last_bal := tx.balance_after;
    END LOOP;

    FOR b IN SELECT * FROM _mig_batches mb WHERE mb.remaining > 0 ORDER BY mb.batch_ts LOOP
      pk_number := u.pk_number;
      user_id := u.user_id;
      batch_tx_id := b.tx_id;
      batch_at := b.batch_ts;
      SELECT w.amount INTO batch_credits FROM wallet_transactions w WHERE w.id = b.tx_id;
      remaining_credits := b.remaining;
      slots := floor(b.remaining / 20)::integer;
      leftover_credits := b.remaining - slots * 20;

      -- Match the batch to the payment confirmed at the same moment.
      SELECT p.id, p.pack_id, p.created_at INTO v_pay
      FROM payments p
      WHERE p.user_id = u.user_id AND p.status = 'completed'
        AND p.verified_at BETWEEN b.batch_ts - interval '2 minutes' AND b.batch_ts + interval '2 minutes'
      ORDER BY abs(extract(epoch FROM p.verified_at - b.batch_ts))
      LIMIT 1;

      payment_id := v_pay.id;
      SELECT sp.id INTO package_id FROM slot_packages sp WHERE sp.legacy_pack_id = v_pay.pack_id;

      IF v_pay.id IS NOT NULL AND package_id IS NOT NULL THEN
        SELECT * INTO v_pkg FROM slot_packages WHERE id = package_id;
        -- Validity counts from the original purchase, not from the migration.
        expires_at := CASE WHEN v_pkg.expiry_days IS NULL THEN NULL
                           ELSE v_pay.created_at + make_interval(days => v_pkg.expiry_days) END;
        note := 'matched_payment';
      ELSE
        -- No purchase behind this credit (admin grant, redeem code, or a payment
        -- approved manually). Counted from the credit date with the longest standard window.
        package_id := NULL;
        expires_at := b.batch_ts + make_interval(days => COALESCE(v_max_days, 15));
        note := 'unmatched_default_window';
      END IF;

      IF u.pk_number = 1 THEN
        slots := 0;
        note := 'excluded_pk001';
      END IF;

      RETURN NEXT;
    END LOOP;
  END LOOP;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.plan_credit_migration() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.plan_credit_migration() TO service_role;
