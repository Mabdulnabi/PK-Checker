-- 20261117090000_fix_order_display_id.sql
-- New checks failed with: duplicate key value violates unique constraint "orders_display_id_key".
-- generate_order_display_id() picks the day's highest PK-YYMMDD-NNN and adds 1, but it ran with the
-- customer's rights, and row-level security only shows a customer their own orders. A customer with
-- no order yet today therefore got 001, which another customer already had.
-- SECURITY DEFINER makes it see every order; the advisory lock still serialises concurrent inserts.

CREATE OR REPLACE FUNCTION public.generate_order_display_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_prefix text := 'PK-' || to_char(NOW() AT TIME ZONE 'UTC', 'YYMMDD') || '-';
  v_next   integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('order_display_id'));

  SELECT COALESCE(MAX(substring(o.display_id FROM length(v_prefix) + 1)::integer), 0) + 1
    INTO v_next
  FROM public.orders o
  WHERE o.display_id LIKE v_prefix || '%'
    AND substring(o.display_id FROM length(v_prefix) + 1) ~ '^[0-9]+$';

  NEW.display_id := v_prefix || lpad(v_next::text, 3, '0');
  RETURN NEW;
END;
$function$;
