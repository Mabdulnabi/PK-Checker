-- Service outages give time back, and purchases stack while earlier slots are still live.
--
-- Outage = check_settings.service_enabled is false, or the master row of
-- service_availability is disabled (maintenance). While the service is down, the clock
-- stops: when it comes back, every grant that was live when the outage began (and still
-- has slots) gets the outage length added to its expiry. Grants bought during the outage
-- are not extended.

CREATE TABLE IF NOT EXISTS public.service_outages (
  id               bigserial PRIMARY KEY,
  started_at       timestamptz NOT NULL,
  ended_at         timestamptz,
  grants_extended  integer NOT NULL DEFAULT 0,
  created_at       timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.service_outages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS service_outages_admin_read ON public.service_outages;
CREATE POLICY service_outages_admin_read ON public.service_outages
  FOR SELECT TO authenticated USING (is_admin());
REVOKE ALL ON public.service_outages FROM PUBLIC, anon;

CREATE OR REPLACE FUNCTION public.service_is_down()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT (NOT COALESCE((SELECT cs.service_enabled FROM check_settings cs ORDER BY cs.id LIMIT 1), true))
      OR (NOT COALESCE((SELECT sa.enabled FROM service_availability sa WHERE sa.service = 'master'), true));
$$;

CREATE OR REPLACE FUNCTION public.sync_service_outage()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_down  boolean := service_is_down();
  v_open  service_outages%ROWTYPE;
  v_len   interval;
  v_n     integer;
BEGIN
  -- One caller at a time: two toggles must not open or close the same outage twice.
  PERFORM pg_advisory_xact_lock(hashtext('service_outage'));

  SELECT * INTO v_open FROM service_outages
  WHERE ended_at IS NULL ORDER BY started_at DESC LIMIT 1 FOR UPDATE;

  IF v_down AND NOT FOUND THEN
    INSERT INTO service_outages (started_at) VALUES (now());

  ELSIF NOT v_down AND FOUND THEN
    UPDATE service_outages SET ended_at = now() WHERE id = v_open.id;
    v_len := now() - v_open.started_at;

    -- Live before the outage, still holding slots, not yet used up: the clock stopped.
    UPDATE customer_slot_grants g
    SET expires_at = g.expires_at + v_len
    WHERE g.expires_at IS NOT NULL
      AND g.granted_at < v_open.started_at
      AND g.expires_at > v_open.started_at
      AND g.slots_total - (
        SELECT count(*) FROM slot_usages u WHERE u.grant_id = g.id AND u.status = 'reserved'
      ) > 0;
    GET DIAGNOSTICS v_n = ROW_COUNT;

    UPDATE service_outages SET grants_extended = v_n WHERE id = v_open.id;
  END IF;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.sync_service_outage() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.trg_sync_service_outage()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  PERFORM sync_service_outage();
  RETURN NULL;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.trg_sync_service_outage() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_outage_check_settings ON public.check_settings;
CREATE TRIGGER trg_outage_check_settings
  AFTER INSERT OR UPDATE OF service_enabled ON public.check_settings
  FOR EACH ROW EXECUTE FUNCTION public.trg_sync_service_outage();

DROP TRIGGER IF EXISTS trg_outage_service_availability ON public.service_availability;
CREATE TRIGGER trg_outage_service_availability
  AFTER INSERT OR UPDATE OF enabled ON public.service_availability
  FOR EACH ROW EXECUTE FUNCTION public.trg_sync_service_outage();

-- The service is down right now (service_enabled = false since 04:43 UTC today).
-- Record that outage so that re-enabling it gives the time back.
INSERT INTO service_outages (started_at)
SELECT COALESCE(
         (SELECT cs.updated_at FROM check_settings cs WHERE NOT cs.service_enabled ORDER BY cs.id LIMIT 1),
         now())
WHERE service_is_down() AND NOT EXISTS (SELECT 1 FROM service_outages WHERE ended_at IS NULL);

-- Stacking: a new purchase starts after the latest expiry of the same type's live grants,
-- so validity adds up while those slots are still running. A grant that is used up no
-- longer counts, so buying again after finishing a pack starts from the purchase time.
CREATE OR REPLACE FUNCTION public.grant_slots(
  p_user_id uuid, p_package_id uuid, p_source text, p_source_ref text, p_granted_at timestamptz,
  p_expires_override timestamptz DEFAULT NULL, p_override_set boolean DEFAULT false)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_pkg    slot_packages%ROWTYPE;
  v_id     uuid;
  v_start  timestamptz := p_granted_at;
  v_latest timestamptz;
  v_exp    timestamptz;
BEGIN
  SELECT * INTO v_pkg FROM slot_packages WHERE id = p_package_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PACKAGE_NOT_FOUND'; END IF;

  -- Serialise grants per customer so two confirmations cannot stack from the same base.
  PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text));

  IF p_override_set THEN
    v_exp := p_expires_override;
  ELSIF v_pkg.expiry_days IS NULL THEN
    v_exp := NULL;
  ELSE
    SELECT max(g.expires_at) INTO v_latest
    FROM customer_slot_grants g
    WHERE g.user_id = p_user_id
      AND g.slot_type = v_pkg.slot_type
      AND g.expires_at IS NOT NULL
      AND g.expires_at > p_granted_at
      AND g.slots_total - (
        SELECT count(*) FROM slot_usages u WHERE u.grant_id = g.id AND u.status = 'reserved'
      ) > 0;
    IF v_latest IS NOT NULL AND v_latest > v_start THEN v_start := v_latest; END IF;
    v_exp := v_start + make_interval(days => v_pkg.expiry_days);
  END IF;

  INSERT INTO customer_slot_grants (user_id, package_id, slot_type, slots_total, granted_at, expires_at, source, source_ref)
  VALUES (p_user_id, v_pkg.id, v_pkg.slot_type, v_pkg.slots, p_granted_at, v_exp, p_source, p_source_ref)
  ON CONFLICT (source, source_ref) DO NOTHING
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;

-- A purchase's validity starts when it is confirmed, not when the payment was opened.
-- (Only the grant time argument changes; the rest of confirm_topup is unchanged.)
CREATE OR REPLACE FUNCTION public.confirm_topup(p_user_id uuid, p_payment_id uuid, p_credits integer, p_gateway text, p_provider_ref text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_claimed  integer;
  v_pay      payments%ROWTYPE;
  v_pkg_id   uuid;
  v_grant    uuid;
BEGIN
  -- Only a pending payment can be confirmed. Completed, failed or superseded ones cannot.
  SELECT * INTO v_pay FROM payments WHERE id = p_payment_id AND user_id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_NOT_FOUND'; END IF;
  IF v_pay.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'alreadyProcessed', v_pay.status = 'completed',
                              'error', 'Payment is not pending');
  END IF;

  INSERT INTO processed_payment_refs (gateway, provider_ref, payment_id)
  VALUES (p_gateway, p_provider_ref, p_payment_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN jsonb_build_object('ok', false, 'alreadyProcessed', true,
                              'error', 'This transaction was already processed');
  END IF;

  SELECT sp.id INTO v_pkg_id FROM slot_packages sp
  WHERE sp.legacy_pack_id = v_pay.pack_id OR sp.id::text = v_pay.pack_id
  LIMIT 1;
  IF v_pkg_id IS NULL THEN RAISE EXCEPTION 'PACKAGE_NOT_FOUND'; END IF;

  v_grant := grant_slots(p_user_id, v_pkg_id, 'purchase', p_payment_id::text, now());

  UPDATE payments
  SET status = 'completed', verified_at = now(), transaction_id = p_provider_ref
  WHERE id = p_payment_id;

  -- The other pending attempts for the same package of this customer are closed:
  -- they disappear from the history and can no longer be confirmed.
  UPDATE payments
  SET status = 'superseded', failure_reason = 'superseded by a completed payment'
  WHERE user_id = p_user_id AND pack_id IS NOT DISTINCT FROM v_pay.pack_id
    AND status = 'pending' AND id <> p_payment_id;

  RETURN jsonb_build_object('ok', true, 'grantId', v_grant);
END;
$$;
