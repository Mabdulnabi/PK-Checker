-- 20261115040000_daily_order_number.sql
-- Order code is PK-YYMMDD-NNN, where NNN is the order number of that day (UTC) and restarts at 001 each day.
-- Before this, NNN came from one global sequence, so it kept counting across days.
-- The advisory lock keeps two orders created at the same moment from taking the same number.

CREATE OR REPLACE FUNCTION public.generate_order_display_id()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_prefix text := 'PK-' || to_char(NOW() AT TIME ZONE 'UTC', 'YYMMDD') || '-';
  v_next   integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('order_display_id'));

  SELECT COALESCE(MAX(substring(o.display_id FROM length(v_prefix) + 1)::integer), 0) + 1
    INTO v_next
  FROM orders o
  WHERE o.display_id LIKE v_prefix || '%'
    AND substring(o.display_id FROM length(v_prefix) + 1) ~ '^[0-9]+$';

  NEW.display_id := v_prefix || lpad(v_next::text, 3, '0');
  RETURN NEW;
END;
$function$;
