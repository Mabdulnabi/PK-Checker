-- PayPal manual mode (temporary): the customer sends the money to the admin's PayPal username and
-- enters the PayPal Transaction ID; the admin confirms or rejects it from the Payments tab.
-- payment_methods.is_auto = false on the 'paypal' row is the switch (set from the Payment Gateways tab).

-- Admin decision on a pending manually-reviewed payment. Approving goes through confirm_topup(),
-- so slots / store balance are added exactly as for automatic payments (and only once).
CREATE OR REPLACE FUNCTION public.admin_review_payment(p_payment_id uuid, p_approve boolean, p_note text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_pay payments%ROWTYPE;
  v_res jsonb;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'NOT_ADMIN'; END IF;
  SELECT * INTO v_pay FROM payments WHERE id = p_payment_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_NOT_FOUND'; END IF;
  IF v_pay.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Payment is not pending', 'status', v_pay.status);
  END IF;

  IF p_approve THEN
    IF coalesce(v_pay.transaction_id, '') = '' THEN
      RETURN jsonb_build_object('ok', false, 'error', 'NO_TRANSACTION_ID');
    END IF;
    v_res := public.confirm_topup(v_pay.user_id, v_pay.id, coalesce(v_pay.credits, 0), v_pay.gateway, v_pay.transaction_id);
    RETURN v_res;
  END IF;

  UPDATE payments SET status = 'rejected', failure_reason = left(coalesce(nullif(p_note, ''), 'rejected by admin'), 200), updated_at = now()
   WHERE id = p_payment_id;
  RETURN jsonb_build_object('ok', true, 'rejected', true);
END;
$function$;
REVOKE ALL ON FUNCTION public.admin_review_payment(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_review_payment(uuid, boolean, text) TO authenticated;

-- Switch PayPal to manual review now, with the admin's PayPal username (editable later).
UPDATE public.payment_methods
   SET is_auto = false,
       uid = coalesce(nullif(uid, ''), 'mabdulnabi'),
       uid_label_ar = 'اسم مستخدم PayPal',
       uid_label_en = 'PayPal username',
       instructions_ar = 'حوّل المبلغ المطلوب (شاملًا عمولة PayPal) إلى اسم المستخدم أعلاه عبر PayPal، ثم أدخل رقم العملية (Transaction ID). ستُضاف الفحوصات إلى حسابك بعد مراجعة الإدارة.',
       instructions_en = 'Send the amount shown (PayPal fee included) to the username above with PayPal, then enter the Transaction ID. The checks are added to your account after an admin reviews the payment.',
       visible = true,
       updated_at = now()
 WHERE key = 'paypal';
