-- Order codes now carry the customer's PK number: PK<pk>-YYMMDD-<n>, e.g. PK13-261122-3.
-- <n> is the order's number in the day across the whole site, without leading zeros. It continues
-- from the codes already issued today in the old PK-YYMMDD-NNN form. Codes already issued are not changed.
CREATE OR REPLACE FUNCTION public.generate_order_display_id()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
DECLARE
  v_day  text := to_char(NOW() AT TIME ZONE 'UTC', 'YYMMDD');
  v_pk   bigint;
  v_next integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('order_display_id'));

  SELECT p.pk_number INTO v_pk FROM public.users_profile p WHERE p.user_id = NEW.user_id LIMIT 1;

  SELECT COALESCE(MAX(substring(o.display_id FROM '-' || v_day || '-([0-9]+)$')::integer), 0) + 1
    INTO v_next
  FROM public.orders o
  WHERE o.display_id ~ ('^PK[0-9]*-' || v_day || '-[0-9]+$');

  NEW.display_id := 'PK' || COALESCE(v_pk::text, '') || '-' || v_day || '-' || v_next::text;
  RETURN NEW;
END;
$function$;
