-- Slot validity switch (admin, Checks tab).
-- ON  (default): every package keeps its validity in days, as before.
-- OFF: packages bought from now on never expire (lifetime). Grants bought earlier keep their own expiry.

ALTER TABLE public.check_settings ADD COLUMN IF NOT EXISTS slot_expiry_enabled boolean NOT NULL DEFAULT true;

CREATE OR REPLACE FUNCTION public.admin_set_slot_validity(p_enabled boolean)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  UPDATE check_settings
  SET slot_expiry_enabled = p_enabled, updated_at = now()
  WHERE id = (SELECT min(id) FROM check_settings);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_slot_validity(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_slot_validity(boolean) TO authenticated;

-- grant_slots: same as 20261103090000, plus the lifetime switch.
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
  v_timed  boolean;
BEGIN
  SELECT * INTO v_pkg FROM slot_packages WHERE id = p_package_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PACKAGE_NOT_FOUND'; END IF;

  PERFORM pg_advisory_xact_lock(hashtext(p_user_id::text));

  v_timed := COALESCE((SELECT cs.slot_expiry_enabled FROM check_settings cs ORDER BY cs.id LIMIT 1), true);

  IF p_override_set THEN
    v_exp := p_expires_override;
  ELSIF v_pkg.expiry_days IS NULL OR NOT v_timed THEN
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
