-- 20261117120000_paypal_payment_method.sql
-- PayPal as a built-in payment method (Card tab, next to EasyKash). Checked and credited
-- automatically by the paypal-create-order / paypal-capture-order edge functions.
-- Added hidden: the admin shows it from the payment methods tab once PAYPAL_SECRET is set and tested.
INSERT INTO public.payment_methods (key, name, is_builtin, visible, is_auto, sort_order, currency, edge_fn,
                                    instructions_ar, instructions_en)
SELECT 'paypal', 'PayPal', true, false, true,
       coalesce((SELECT max(sort_order) FROM public.payment_methods), 0) + 1,
       'USD', 'paypal-capture-order',
       'ادفع بحساب PayPal أو بأي كارت فيزا أو ماستركارد من أي دولة. بعد الدفع هنأكد تلقائيًا ويتضاف رصيدك على طول.',
       'Pay with your PayPal account or any Visa or Mastercard, from any country. We confirm it automatically and add your balance right away.'
WHERE NOT EXISTS (SELECT 1 FROM public.payment_methods WHERE key = 'paypal');
