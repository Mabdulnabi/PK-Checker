-- Payment methods:
--  * EasyKash moves to the E-Wallets tab (paid in EGP, inside Egypt).
--  * New method "Bank transfer" (international, to a US account, in USD) in the Card tab next to PayPal.
--    Its account number, routing number and account type are kept in payment_methods.details and are
--    edited from Payment Gateways. Checked by hand like the other manual methods (the customer enters
--    the bank's transfer reference). Hidden until the admin enters the account details and turns it on.
ALTER TABLE public.payment_methods ADD COLUMN IF NOT EXISTS details jsonb NOT NULL DEFAULT '{}'::jsonb;

UPDATE public.payment_methods SET pay_group = 'wallets', updated_at = now() WHERE key = 'easykash';

INSERT INTO public.payment_methods (key, name, uid, uid_label_ar, uid_label_en, instructions_ar, instructions_en,
                                    is_auto, visible, is_builtin, currency, pay_group, sort_order, qr_size, details)
SELECT 'bank_transfer', 'Bank transfer', NULL, 'رقم مرجع التحويل', 'Transfer reference',
       'حوّل المبلغ المطلوب بالدولار (USD) تحويلًا بنكيًا إلى الحساب الأمريكي أعلاه، واكتب كود الدفع (PKC-…) في خانة المرجع أو الملاحظة، ثم أدخل رقم مرجع التحويل الذي يعطيك إياه البنك. تُضاف الفحوصات إلى حسابك بعد مراجعة الإدارة للتحويل.',
       'Send the amount shown in US dollars (USD) by bank transfer to the US account above, put the payment code (PKC-…) in the reference or memo, then enter the transfer reference your bank gives you. The checks are added to your account after an admin reviews the transfer.',
       false, false, false, 'USD', 'card',
       coalesce((SELECT max(sort_order) FROM public.payment_methods WHERE pay_group = 'card'), 8) + 1, 120,
       jsonb_build_object('account_number', '', 'routing_number', '', 'account_type', 'Checking')
WHERE NOT EXISTS (SELECT 1 FROM public.payment_methods WHERE key = 'bank_transfer');
