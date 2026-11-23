-- Two PayPal methods, each with its own on/off switch in Payment Gateways:
--  * paypal        : automatic (PayPal checkout + API capture), as before.
--  * paypal_manual : transfer to the admin's PayPal username + Transaction ID, confirmed by an admin.
-- The automatic one goes back to its own settings and stays hidden (PayPal is declining its captures);
-- the manual one is shown.
UPDATE public.payment_methods
   SET is_auto = true,
       uid = NULL,
       uid_label_ar = 'رقم التحويل',
       uid_label_en = 'Reference number',
       instructions_ar = 'ادفع بحساب PayPal أو بأي كارت فيزا أو ماستركارد من أي دولة. بعد الدفع هنأكد تلقائيًا ويتضاف رصيدك على طول.',
       instructions_en = 'Pay with your PayPal account or any Visa or Mastercard, from any country. We confirm it automatically and add your balance right away.',
       visible = false,
       updated_at = now()
 WHERE key = 'paypal';

INSERT INTO public.payment_methods (key, name, uid, uid_label_ar, uid_label_en, instructions_ar, instructions_en,
                                    is_auto, visible, is_builtin, currency, pay_group, sort_order, qr_size)
SELECT 'paypal_manual', 'PayPal', 'mabdulnabi', 'اسم مستخدم PayPal', 'PayPal username',
       'حوّل المبلغ المطلوب (شاملًا عمولة PayPal) إلى اسم المستخدم أعلاه عبر PayPal، ثم أدخل رقم العملية (Transaction ID). ستُضاف الفحوصات إلى حسابك بعد مراجعة الإدارة.',
       'Send the amount shown (PayPal fee included) to the username above with PayPal, then enter the Transaction ID. The checks are added to your account after an admin reviews the payment.',
       false, true, false, 'USD', 'card',
       coalesce((SELECT sort_order FROM public.payment_methods WHERE key = 'paypal'), 7) + 1, 120
WHERE NOT EXISTS (SELECT 1 FROM public.payment_methods WHERE key = 'paypal_manual');
