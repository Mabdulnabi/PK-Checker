-- My Files on a testing account (tester_accounts, PK001) also lists files whose reports were removed
-- after 48 hours, so new features can be tried on older orders. Customers are unchanged.
DO $mig$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.my_checked_files'::regproc);
  IF position('tester_accounts' in d) = 0 THEN
    d := replace(d, '      AND o.purged_at IS NULL', '      AND (o.purged_at IS NULL OR EXISTS (SELECT 1 FROM tester_accounts t WHERE t.user_id = auth.uid()))');
    IF position('tester_accounts' in d) = 0 THEN RAISE EXCEPTION 'my_checked_files: expected text not found'; END IF;
    EXECUTE d;
  END IF;
END
$mig$;
