-- Queue for files TurniScan refuses only because it is busy ("temporary database concurrency ...
-- Your scan credit was NOT deducted ... Please retry"). submit-check puts such orders in status
-- 'queued' (slot kept for them) and the scheduler below runs the queue every 20 seconds until
-- TurniScan accepts the file. The customer or the admin can cancel a queued order; its slot goes
-- back (trg_refund_on_order_failure treats 'cancelled' as a failure state).

-- Trusted order functions (cancel) may change what the customer guard otherwise forbids.
CREATE OR REPLACE FUNCTION public.guard_customer_order_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  if coalesce(current_setting('app.trusted_order_change', true), '') = 'on' then
    return new;
  end if;
  if auth.uid() is not null and auth.uid() = old.user_id and not public.is_admin() then
    if (to_jsonb(new) - 'status' - 'error_reason' - 'source_file_path' - 'rating' - 'rating_comment'
                      - 'updated_at' - 'processing_started_at' - 'exclude_bibliography' - 'exclude_quotes'
                      - 'exclude_abstract' - 'exclude_small_matches_word_limit')
       is distinct from
       (to_jsonb(old) - 'status' - 'error_reason' - 'source_file_path' - 'rating' - 'rating_comment'
                      - 'updated_at' - 'processing_started_at' - 'exclude_bibliography' - 'exclude_quotes'
                      - 'exclude_abstract' - 'exclude_small_matches_word_limit') then
      raise exception 'NOT_ALLOWED: this order field is read-only for customers';
    end if;
    if new.status is distinct from old.status then
      if old.status not in ('uploading', 'floating', 'error')
         or new.status not in ('uploading', 'floating', 'error') then
        raise exception 'NOT_ALLOWED: invalid status change for customer';
      end if;
    end if;
  end if;
  return new;
end;
$function$;

-- The customer cancels their own order while it waits in the queue (not yet accepted by TurniScan).
CREATE OR REPLACE FUNCTION public.customer_cancel_queued_order(p_order_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id uuid;
  v_status text;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'NOT_SIGNED_IN'; END IF;
  PERFORM set_config('app.trusted_order_change', 'on', true);
  UPDATE orders
     SET status = 'cancelled', error_reason = 'CANCELLED_BY_CUSTOMER', completed_at = now(), updated_at = now()
   WHERE id = p_order_id AND user_id = auth.uid() AND status = 'queued' AND external_order_id IS NULL
  RETURNING id INTO v_id;
  PERFORM set_config('app.trusted_order_change', 'off', true);
  IF v_id IS NULL THEN
    SELECT status INTO v_status FROM orders WHERE id = p_order_id AND user_id = auth.uid();
    RETURN jsonb_build_object('ok', false, 'error', CASE WHEN v_status IS NULL THEN 'NOT_FOUND' ELSE 'NOT_QUEUED' END, 'status', v_status);
  END IF;
  RETURN jsonb_build_object('ok', true);
END;
$function$;
REVOKE ALL ON FUNCTION public.customer_cancel_queued_order(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_cancel_queued_order(uuid) TO authenticated;

-- The admin can also cancel a queued order.
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
     AND status IN ('floating', 'uploading', 'pending', 'queued')
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

-- Run the queue every 20 seconds (submit-check, internal secret).
SELECT cron.unschedule(jobid) FROM cron.job WHERE jobname = 'process-check-queue';
SELECT cron.schedule('process-check-queue', '20 seconds', $$
  SELECT net.http_post(
    url := 'https://ixpgqhwausnfjphitsty.supabase.co/functions/v1/submit-check',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-internal-secret', public.get_internal_cron_secret()),
    body := '{"action":"process_queue"}'::jsonb,
    timeout_milliseconds := 120000
  )
  WHERE EXISTS (SELECT 1 FROM public.orders WHERE status = 'queued');
$$);
