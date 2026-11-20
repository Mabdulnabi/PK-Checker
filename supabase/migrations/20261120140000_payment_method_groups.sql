-- 20261120140000_payment_method_groups.sql
-- Payment methods are grouped like the customer's payment tabs: e-wallets, card, crypto.
-- Built-in methods keep the tab they already show in; methods the admin adds pick theirs.
ALTER TABLE public.payment_methods ADD COLUMN IF NOT EXISTS pay_group text NOT NULL DEFAULT 'wallets';
ALTER TABLE public.payment_methods DROP CONSTRAINT IF EXISTS payment_methods_pay_group_check;
ALTER TABLE public.payment_methods ADD CONSTRAINT payment_methods_pay_group_check CHECK (pay_group IN ('wallets', 'card', 'crypto'));
UPDATE public.payment_methods SET pay_group = 'card'   WHERE key IN ('easykash', 'paypal');
UPDATE public.payment_methods SET pay_group = 'crypto' WHERE key IN ('binance', 'bybit', 'bep20');
UPDATE public.payment_methods SET pay_group = 'wallets' WHERE key IN ('instapay', 'vodafone');
-- Methods the admin adds are checked by hand (no automatic verification exists for them).
UPDATE public.payment_methods SET is_auto = false WHERE NOT is_builtin;
