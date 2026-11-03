-- Outage clock, refined:
-- * Customers who were live when the outage began get the outage length added to their expiry.
-- * Purchases made during the outage start counting when the service comes back:
--   granted_at moves to the return time and the expiry keeps the same validity length.

CREATE OR REPLACE FUNCTION public.sync_service_outage()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_now   timestamptz := now();
  v_down  boolean := service_is_down();
  v_open  service_outages%ROWTYPE;
  v_len   interval;
  v_n1    integer;
  v_n2    integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('service_outage'));

  SELECT * INTO v_open FROM service_outages
  WHERE ended_at IS NULL ORDER BY started_at DESC LIMIT 1 FOR UPDATE;

  IF v_down AND NOT FOUND THEN
    INSERT INTO service_outages (started_at) VALUES (v_now);

  ELSIF NOT v_down AND FOUND THEN
    UPDATE service_outages SET ended_at = v_now WHERE id = v_open.id;
    v_len := v_now - v_open.started_at;

    -- Live when the outage began, still holding slots: the clock stopped, so add the outage length.
    UPDATE customer_slot_grants g
    SET expires_at = g.expires_at + v_len
    WHERE g.expires_at IS NOT NULL
      AND g.granted_at < v_open.started_at
      AND g.expires_at > v_open.started_at
      AND g.slots_total - (
        SELECT count(*) FROM slot_usages u WHERE u.grant_id = g.id AND u.status = 'reserved'
      ) > 0;
    GET DIAGNOSTICS v_n1 = ROW_COUNT;

    -- Bought during the outage, still holding slots: the clock starts at the return time.
    UPDATE customer_slot_grants g
    SET expires_at = v_now + (g.expires_at - g.granted_at),
        granted_at = v_now
    WHERE g.expires_at IS NOT NULL
      AND g.granted_at >= v_open.started_at
      AND g.granted_at < v_now
      AND g.slots_total - (
        SELECT count(*) FROM slot_usages u WHERE u.grant_id = g.id AND u.status = 'reserved'
      ) > 0;
    GET DIAGNOSTICS v_n2 = ROW_COUNT;

    UPDATE service_outages SET grants_extended = v_n1 + v_n2 WHERE id = v_open.id;
  END IF;
END;
$$;
