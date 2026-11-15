-- 20261115080000_api_credit_log_backfill.sql
-- Backfills api_credit_log for orders that were sent to the provider before the log existed.
-- TurniScan only exposes the current balance, so api_before / api_after / api_delta stay NULL
-- for these rows. The note marks them as backfilled. Safe to re-run: existing rows are skipped.

-- Submit: one row per order that was sent to the provider (time = when it was created).
INSERT INTO public.api_credit_log (order_id, event, api_before, api_after, api_delta, slots_reserved, note, created_at)
SELECT o.id, 'submit', NULL, NULL, NULL,
       (SELECT count(*)::int FROM public.slot_usages su WHERE su.order_id = o.id AND su.status = 'reserved'),
       'backfill: no provider balance history', o.created_at
FROM public.orders o
WHERE o.external_order_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.api_credit_log l WHERE l.order_id = o.id AND l.event = 'submit');

-- Result: one row per completed order (time = completed_at).
INSERT INTO public.api_credit_log (order_id, event, api_before, api_after, api_delta, slots_reserved, note, created_at)
SELECT o.id, 'completed', NULL, NULL, NULL,
       (SELECT count(*)::int FROM public.slot_usages su WHERE su.order_id = o.id AND su.status = 'reserved'),
       'backfill: no provider balance history', COALESCE(o.completed_at, o.updated_at, o.created_at)
FROM public.orders o
WHERE o.status = 'completed'
  AND o.external_order_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.api_credit_log l WHERE l.order_id = o.id AND l.event = 'completed');

-- Result: one row per provider-side failure (time = completed_at).
INSERT INTO public.api_credit_log (order_id, event, api_before, api_after, api_delta, slots_reserved, note, created_at)
SELECT o.id, 'failed', NULL, NULL, NULL,
       (SELECT count(*)::int FROM public.slot_usages su WHERE su.order_id = o.id AND su.status = 'reserved'),
       'backfill: no provider balance history', COALESCE(o.completed_at, o.updated_at, o.created_at)
FROM public.orders o
WHERE o.status = 'error'
  AND o.external_order_id IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.api_credit_log l WHERE l.order_id = o.id AND l.event = 'failed');
