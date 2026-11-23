-- History: a check whose slot was taken and then given back (the order failed or was cancelled
-- before it was checked) shows as 'refunded' instead of 'failed'.
-- Refunded = the order has a released slot usage and no reserved one.
-- Only the status of file-submission rows changes; the rest of my_history() stays as it is.
DO $mig$
DECLARE
  d text;
BEGIN
  d := pg_get_functiondef('public.my_history'::regproc);
  IF position('''refunded''' in d) > 0 THEN
    RETURN;   -- already applied
  END IF;
  d := replace(d,
    $old$CASE WHEN o.status = 'completed' THEN 'completed'$old$,
    $new$CASE WHEN o.status = 'completed' THEN 'completed'
              WHEN EXISTS (SELECT 1 FROM slot_usages u WHERE u.order_id = o.id AND u.status = 'released')
               AND NOT EXISTS (SELECT 1 FROM slot_usages u WHERE u.order_id = o.id AND u.status = 'reserved')
              THEN 'refunded'$new$);
  IF position('''refunded''' in d) = 0 THEN
    RAISE EXCEPTION 'my_history: status expression not found';
  END IF;
  EXECUTE d;
END
$mig$;
