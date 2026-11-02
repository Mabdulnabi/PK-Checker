-- ============================================================
-- Redeem codes now grant a slot package, not credits.
-- The admin chooses the package when generating the codes; redeeming
-- grants exactly that package. Validity counts from the redeem time,
-- using the package's own rule (days, or no expiry).
-- ============================================================

ALTER TABLE public.redeem_codes
  ADD COLUMN IF NOT EXISTS package_id uuid REFERENCES public.slot_packages(id) ON DELETE SET NULL;

-- Old credit-based generator is replaced by the package-based one.
DROP FUNCTION IF EXISTS public.admin_create_redeem_codes(integer, integer);

CREATE OR REPLACE FUNCTION public.admin_create_redeem_codes(p_package_id uuid, p_count integer)
RETURNS TABLE(redeem_code text, redeem_package_id uuid)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin public.admins%ROWTYPE;
  v_pkg   public.slot_packages%ROWTYPE;
  v_hex   text;
  v_code  text;
BEGIN
  SELECT * INTO v_admin FROM public.admins WHERE id = auth.uid();
  IF NOT FOUND OR NOT (v_admin.is_super_admin OR COALESCE((v_admin.permissions->>'manage_credits')::boolean, false)) THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  SELECT * INTO v_pkg FROM public.slot_packages WHERE id = p_package_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PACKAGE_NOT_FOUND'; END IF;
  IF NOT v_pkg.is_active THEN RAISE EXCEPTION 'PACKAGE_INACTIVE'; END IF;

  IF p_count IS NULL OR p_count < 1 OR p_count > 500 THEN
    RAISE EXCEPTION 'INVALID_COUNT';
  END IF;

  FOR i IN 1..p_count LOOP
    LOOP
      v_hex  := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));
      v_code := substr(v_hex, 1, 4) || '-' || substr(v_hex, 5, 4) || '-' || substr(v_hex, 9, 4) || '-' || substr(v_hex, 13, 4);
      EXIT WHEN NOT EXISTS (SELECT 1 FROM public.redeem_codes rc WHERE rc.code = v_code);
    END LOOP;

    INSERT INTO public.redeem_codes (code, credits, created_by, package_id)
    VALUES (v_code, v_pkg.slots, auth.uid(), v_pkg.id);

    redeem_code := v_code;
    redeem_package_id := v_pkg.id;
    RETURN NEXT;
  END LOOP;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_create_redeem_codes(uuid, integer) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.admin_create_redeem_codes(uuid, integer) TO authenticated;

-- Redeem: lock the code row, grant the package, mark the code used, in one transaction.
CREATE OR REPLACE FUNCTION public.redeem_code(p_code text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_norm    text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_code    redeem_codes%ROWTYPE;
  v_pkg     slot_packages%ROWTYPE;
  v_fails   integer;
  v_grant   uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'NOT_AUTHENTICATED';
  END IF;

  SELECT count(*) INTO v_fails FROM redeem_attempts
  WHERE user_id = v_uid AND attempted_at > now() - interval '15 minutes';
  IF v_fails >= 5 THEN
    RETURN jsonb_build_object('error', 'TOO_MANY_ATTEMPTS');
  END IF;

  IF length(v_norm) <> 16 THEN
    INSERT INTO redeem_attempts (user_id) VALUES (v_uid);
    RETURN jsonb_build_object('error', 'INVALID_CODE');
  END IF;

  SELECT * INTO v_code FROM redeem_codes WHERE replace(code, '-', '') = v_norm FOR UPDATE;
  IF NOT FOUND THEN
    INSERT INTO redeem_attempts (user_id) VALUES (v_uid);
    RETURN jsonb_build_object('error', 'INVALID_CODE');
  END IF;

  IF v_code.redeemed_at IS NOT NULL THEN
    INSERT INTO redeem_attempts (user_id) VALUES (v_uid);
    RETURN jsonb_build_object('error', 'CODE_ALREADY_USED');
  END IF;

  IF v_code.package_id IS NULL THEN
    RETURN jsonb_build_object('error', 'CODE_NOT_CONFIGURED');
  END IF;

  SELECT * INTO v_pkg FROM slot_packages WHERE id = v_code.package_id;
  IF NOT FOUND OR NOT v_pkg.is_active THEN
    RETURN jsonb_build_object('error', 'PACKAGE_INACTIVE');
  END IF;

  UPDATE redeem_codes SET redeemed_by = v_uid, redeemed_at = now() WHERE id = v_code.id;

  v_grant := grant_slots(v_uid, v_pkg.id, 'redeem', v_code.id::text, now());

  RETURN jsonb_build_object(
    'grant_id', v_grant,
    'slot_type', v_pkg.slot_type,
    'slots', v_pkg.slots,
    'expires_at', CASE WHEN v_pkg.expiry_days IS NULL THEN NULL ELSE now() + make_interval(days => v_pkg.expiry_days) END,
    'name_ar', v_pkg.name_ar,
    'name_en', v_pkg.name_en
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.redeem_code(text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.redeem_code(text) TO authenticated;
