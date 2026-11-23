-- Admin cancels an order before it reaches the check provider (Turnitin / TurniScan).
-- Only while it is still waiting or being sent (floating / uploading / pending) and has no provider id.
-- The status change and the check are one statement, so an order that has just been sent is never
-- cancelled. The slot goes back through trg_refund_on_order_failure ('cancelled' is a failure state),
-- and the customer is notified.
CREATE OR REPLACE FUNCTION public.admin_cancel_order(p_order_id uuid, p_reason text DEFAULT NULL)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_order orders%ROWTYPE;
  v_status text;
BEGIN
  IF NOT public.is_admin() THEN RAISE EXCEPTION 'NOT_ADMIN'; END IF;

  UPDATE orders
     SET status = 'cancelled',
         error_reason = left(coalesce(nullif(p_reason, ''), 'CANCELLED_BY_ADMIN'), 300),
         completed_at = now(),
         updated_at = now()
   WHERE id = p_order_id
     AND status IN ('floating', 'uploading', 'pending')
     AND external_order_id IS NULL
  RETURNING * INTO v_order;

  IF NOT FOUND THEN
    SELECT status INTO v_status FROM orders WHERE id = p_order_id;
    RETURN jsonb_build_object('ok', false, 'error', CASE WHEN v_status IS NULL THEN 'NOT_FOUND' ELSE 'ALREADY_SENT' END, 'status', v_status);
  END IF;

  INSERT INTO notifications (user_id, type, title_ar, title_en, body_ar, body_en, related_order_id)
  VALUES (v_order.user_id, 'order_cancelled',
          'تم إلغاء طلب الفحص', 'Check request cancelled',
          'تم إلغاء طلب فحص الملف ' || coalesce(v_order.file_name, '') || ' قبل إرساله، وأُعيد الفحص إلى رصيدك.'
            || CASE WHEN nullif(p_reason, '') IS NOT NULL THEN ' السبب: ' || p_reason ELSE '' END,
          'The check request for ' || coalesce(v_order.file_name, 'your file') || ' was cancelled before it was sent, and the check was returned to your balance.'
            || CASE WHEN nullif(p_reason, '') IS NOT NULL THEN ' Reason: ' || p_reason ELSE '' END,
          v_order.id);

  RETURN jsonb_build_object('ok', true, 'display_id', v_order.display_id);
END;
$function$;
REVOKE ALL ON FUNCTION public.admin_cancel_order(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cancel_order(uuid, text) TO authenticated;
