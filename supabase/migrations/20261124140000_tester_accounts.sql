-- Testing accounts: on these customer accounts, new features also show on older orders, so the admin
-- can try them out (e.g. the AI word-limit notice, normally for the last 7 days only).
-- A customer reads only their own row; nobody but an admin writes. PK001 is the testing account.
CREATE TABLE IF NOT EXISTS public.tester_accounts (
  user_id    uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  note       text,
  created_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.tester_accounts ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tester_accounts_read ON public.tester_accounts;
CREATE POLICY tester_accounts_read ON public.tester_accounts
  FOR SELECT TO authenticated USING (user_id = auth.uid() OR public.is_admin());
DROP POLICY IF EXISTS tester_accounts_admin_write ON public.tester_accounts;
CREATE POLICY tester_accounts_admin_write ON public.tester_accounts
  FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());

INSERT INTO public.tester_accounts (user_id, note)
SELECT user_id, 'PK001 testing account' FROM public.users_profile WHERE pk_number = 1
ON CONFLICT (user_id) DO NOTHING;
