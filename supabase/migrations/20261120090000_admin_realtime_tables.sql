-- 20261120090000_admin_realtime_tables.sql
-- Live updates in the admin page for three more tables:
--   store_orders        -> "new store order" alerts
--   api_credit_log      -> the API credit log on the Dashboard updates by itself
--   admin_notifications -> the admin bell (the page already listened, but the table was not published)
-- Row access is unchanged: realtime only sends rows the signed-in admin may already read (RLS).
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['store_orders', 'api_credit_log', 'admin_notifications'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_publication_tables
                   WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END $$;
