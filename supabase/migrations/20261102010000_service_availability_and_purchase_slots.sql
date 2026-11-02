-- ============================================================
-- 1. Service availability: admin switches + provider slot threshold per check type.
-- 2. Purchases grant slots (confirm_topup no longer credits the wallet).
-- ============================================================

CREATE TABLE IF NOT EXISTS public.service_availability (
  service               text PRIMARY KEY CHECK (service IN ('plag_ai', 'plag_only')),
  enabled               boolean NOT NULL DEFAULT true,   -- admin switch; false = maintenance
  min_provider_credits  integer NOT NULL DEFAULT 1 CHECK (min_provider_credits >= 0),
  message_ar            text NOT NULL DEFAULT 'النظام تحت الصيانة حالياً، حاول بعد قليل.',
  message_en            text NOT NULL DEFAULT 'The system is under maintenance right now. Please try again shortly.',
  updated_at            timestamptz NOT NULL DEFAULT now()
);

INSERT INTO public.service_availability (service) VALUES ('plag_ai'), ('plag_only')
ON CONFLICT (service) DO NOTHING;

ALTER TABLE public.service_availability ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "availability readable" ON public.service_availability;
CREATE POLICY "availability readable" ON public.service_availability
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "admins manage availability" ON public.service_availability;
CREATE POLICY "admins manage availability" ON public.service_availability
  FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());

GRANT SELECT ON public.service_availability TO anon, authenticated;
GRANT INSERT, UPDATE ON public.service_availability TO authenticated;

-- Purchase confirmation: the payment's pack becomes slots, validity counts from the purchase time.
-- The provider reference is claimed in the same transaction, so a failed grant leaves nothing behind.
CREATE OR REPLACE FUNCTION public.confirm_topup(
  p_user_id uuid, p_payment_id uuid, p_credits integer, p_gateway text, p_provider_ref text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_claimed  integer;
  v_pay      payments%ROWTYPE;
  v_pkg_id   uuid;
  v_grant    uuid;
BEGIN
  INSERT INTO processed_payment_refs (gateway, provider_ref, payment_id)
  VALUES (p_gateway, p_provider_ref, p_payment_id)
  ON CONFLICT DO NOTHING;
  GET DIAGNOSTICS v_claimed = ROW_COUNT;
  IF v_claimed = 0 THEN
    RETURN jsonb_build_object('ok', false, 'alreadyProcessed', true,
                              'error', 'This transaction was already processed');
  END IF;

  SELECT * INTO v_pay FROM payments WHERE id = p_payment_id AND user_id = p_user_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'PAYMENT_NOT_FOUND'; END IF;

  SELECT sp.id INTO v_pkg_id FROM slot_packages sp WHERE sp.legacy_pack_id = v_pay.pack_id;
  IF v_pkg_id IS NULL THEN RAISE EXCEPTION 'PACKAGE_NOT_FOUND'; END IF;

  v_grant := grant_slots(p_user_id, v_pkg_id, 'purchase', p_payment_id::text, v_pay.created_at);

  UPDATE payments
  SET status = 'completed', verified_at = now(), transaction_id = p_provider_ref
  WHERE id = p_payment_id;

  RETURN jsonb_build_object('ok', true, 'grantId', v_grant);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.confirm_topup(uuid, uuid, integer, text, text) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.confirm_topup(uuid, uuid, integer, text, text) TO service_role;
