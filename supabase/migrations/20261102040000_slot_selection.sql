-- Customers pick which package a check uses, and the Submit Files dropdown lists every package.
-- 1. slot_summary also returns all_grants: every package the customer has, with its status.
-- 2. reserve_slot accepts an optional grant id. When given, the check uses that package.

CREATE OR REPLACE FUNCTION public.slot_summary()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  WITH all_g AS (
    SELECT g.id, g.slot_type, g.expires_at, g.granted_at,
           GREATEST(0, g.slots_total - COALESCE((
             SELECT count(*) FROM slot_usages u
             WHERE u.grant_id = g.id AND u.status = 'reserved'
           ), 0)) AS remaining,
           p.name_ar, p.name_en
    FROM customer_slot_grants g
    LEFT JOIN slot_packages p ON p.id = g.package_id
    WHERE g.user_id = auth.uid()
  ),
  live AS (
    SELECT * FROM all_g WHERE (expires_at IS NULL OR expires_at > now())
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
    ), '[]'::jsonb),
    'all_grants', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'grant_id', a.id,
               'slot_type', a.slot_type,
               'remaining', a.remaining,
               'expires_at', a.expires_at,
               'available', (a.remaining > 0 AND (a.expires_at IS NULL OR a.expires_at > now())),
               'name_ar', a.name_ar,
               'name_en', a.name_en) ORDER BY a.expires_at ASC NULLS LAST, a.granted_at)
      FROM all_g a
    ), '[]'::jsonb)
  );
$$;

REVOKE EXECUTE ON FUNCTION public.slot_summary() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.slot_summary() TO authenticated;

DROP FUNCTION IF EXISTS public.reserve_slot(uuid, text, text, uuid);

CREATE OR REPLACE FUNCTION public.reserve_slot(
  p_user_id uuid, p_slot_type text, p_idempotency_key text,
  p_order_id uuid DEFAULT NULL, p_grant_id uuid DEFAULT NULL
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

  SELECT * INTO v_usage FROM slot_usages WHERE idempotency_key = p_idempotency_key;
  IF FOUND THEN
    IF v_usage.user_id <> p_user_id THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
    RETURN jsonb_build_object('usage_id', v_usage.id, 'grant_id', v_usage.grant_id,
                              'status', v_usage.status, 'replayed', true);
  END IF;

  -- The customer picked a package: only that one can be used.
  IF p_grant_id IS NOT NULL THEN
    SELECT * INTO v_grant FROM customer_slot_grants
    WHERE id = p_grant_id AND user_id = p_user_id AND slot_type = p_slot_type
      AND (expires_at IS NULL OR expires_at > now())
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'NO_SLOT_AVAILABLE'; END IF;

    SELECT count(*) INTO v_reserved FROM slot_usages u
    WHERE u.grant_id = v_grant.id AND u.status = 'reserved';
    IF v_grant.slots_total - v_reserved <= 0 THEN RAISE EXCEPTION 'NO_SLOT_AVAILABLE'; END IF;

    INSERT INTO slot_usages (user_id, grant_id, slot_type, order_id, idempotency_key)
    VALUES (p_user_id, v_grant.id, p_slot_type, p_order_id, p_idempotency_key)
    RETURNING * INTO v_usage;
    RETURN jsonb_build_object('usage_id', v_usage.id, 'grant_id', v_grant.id,
                              'status', 'reserved', 'replayed', false);
  END IF;

  -- No package picked: earliest-expiring package of that type.
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

REVOKE EXECUTE ON FUNCTION public.reserve_slot(uuid, text, text, uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.reserve_slot(uuid, text, text, uuid, uuid) TO service_role;
