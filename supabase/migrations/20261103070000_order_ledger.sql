-- Order ledger: one row per check, written when the check starts. It keeps the number of
-- checks, the amount paid for them and the profit, so reports don't depend on the order
-- rows, which are removed from view after 48 hours.
CREATE TABLE IF NOT EXISTS public.order_ledger (
  order_id     uuid PRIMARY KEY,
  user_id      uuid NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  check_type   text,
  slots        integer NOT NULL DEFAULT 1,
  revenue_egp  numeric NOT NULL DEFAULT 0,
  cost_egp     numeric NOT NULL DEFAULT 0,
  profit_egp   numeric GENERATED ALWAYS AS (revenue_egp - cost_egp) STORED,
  status       text NOT NULL DEFAULT 'processing',
  completed_at timestamptz
);

ALTER TABLE public.order_ledger ENABLE ROW LEVEL SECURITY;
CREATE POLICY order_ledger_admin_read ON public.order_ledger FOR SELECT TO authenticated USING (is_admin());

-- A reserved slot for an order: the check starts. Revenue = the package price per slot.
CREATE OR REPLACE FUNCTION public.ledger_on_slot_reserved()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ct   text;
  v_rev  numeric;
BEGIN
  IF NEW.order_id IS NULL OR NEW.status <> 'reserved' THEN RETURN NEW; END IF;
  SELECT check_type INTO v_ct FROM orders WHERE id = NEW.order_id;
  SELECT (sp.price_egp / NULLIF(sp.slots, 0)) INTO v_rev
  FROM customer_slot_grants g JOIN slot_packages sp ON sp.id = g.package_id
  WHERE g.id = NEW.grant_id;
  INSERT INTO order_ledger (order_id, user_id, created_at, check_type, slots, revenue_egp, cost_egp, status)
  VALUES (NEW.order_id, NEW.user_id, now(), v_ct, 1, COALESCE(v_rev, 0),
          CASE WHEN v_ct = 'sim_only' THEN 0 ELSE 32.5 END, 'processing')
  ON CONFLICT (order_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS ledger_slot_reserved ON public.slot_usages;
CREATE TRIGGER ledger_slot_reserved AFTER INSERT ON public.slot_usages
  FOR EACH ROW EXECUTE FUNCTION public.ledger_on_slot_reserved();

-- The order's status and completion time follow into the ledger.
CREATE OR REPLACE FUNCTION public.ledger_on_order_status()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE order_ledger
  SET status = NEW.status,
      completed_at = CASE WHEN NEW.status = 'completed' THEN COALESCE(NEW.completed_at, now()) ELSE completed_at END
  WHERE order_id = NEW.id AND (status IS DISTINCT FROM NEW.status);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS ledger_order_status ON public.orders;
CREATE TRIGGER ledger_order_status AFTER UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION public.ledger_on_order_status();

-- Backfill: slot-based checks already started, then the older checks (before slots),
-- priced as the admin always did: 50 EGP sim only, 100 EGP sim + AI, cost 0 / 32.5.
INSERT INTO order_ledger (order_id, user_id, created_at, check_type, slots, revenue_egp, cost_egp, status, completed_at)
SELECT u.order_id, u.user_id, u.created_at, o.check_type, 1, COALESCE(sp.price_egp / NULLIF(sp.slots, 0), 0),
       CASE WHEN o.check_type = 'sim_only' THEN 0 ELSE 32.5 END, o.status, o.completed_at
FROM slot_usages u
JOIN orders o ON o.id = u.order_id
LEFT JOIN customer_slot_grants g ON g.id = u.grant_id
LEFT JOIN slot_packages sp ON sp.id = g.package_id
WHERE u.status = 'reserved' AND u.order_id IS NOT NULL
ON CONFLICT (order_id) DO NOTHING;

INSERT INTO order_ledger (order_id, user_id, created_at, check_type, slots, revenue_egp, cost_egp, status, completed_at)
SELECT o.id, o.user_id, o.submitted_at, o.check_type, 1,
       CASE WHEN o.check_type = 'sim_only' THEN 50 ELSE 100 END,
       CASE WHEN o.check_type = 'sim_only' THEN 0 ELSE 32.5 END,
       o.status, o.completed_at
FROM orders o
WHERE o.submitted_at IS NOT NULL
  AND o.status IN ('completed', 'error', 'rejected', 'failed_invalid', 'cancelled')
  AND NOT EXISTS (SELECT 1 FROM order_ledger l WHERE l.order_id = o.id)
  AND NOT EXISTS (SELECT 1 FROM slot_usages su WHERE su.order_id = o.id)
ON CONFLICT (order_id) DO NOTHING;
