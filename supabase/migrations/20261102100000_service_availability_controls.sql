-- Service availability controls for the admin dashboard.
--  * 'master'   : API on/off. Off = every check is in maintenance.
--  * 'plag_ai' / 'plag_only' : per check type switches.
--  * min_provider_credits = 2 : a check type is accepted only while the provider
--    has at least 2 slots available.
--  * 'capacity' : message shown when the provider has fewer slots than the minimum.
-- The table has row-level security with no customer policy, so customers reach it only
-- through the check-availability edge function. Admins get a read policy and an RPC to write.

ALTER TABLE service_availability DROP CONSTRAINT IF EXISTS service_availability_service_check;
ALTER TABLE service_availability ADD CONSTRAINT service_availability_service_check
  CHECK (service IN ('master', 'capacity', 'plag_ai', 'plag_only'));

INSERT INTO service_availability (service, enabled, min_provider_credits, message_ar, message_en)
SELECT 'master', true, 0,
  'الخدمة غير متاحة حالياً بسبب أعمال صيانة. نعتذر عن أي إزعاج، ونرجو المحاولة لاحقاً.',
  'The service is temporarily unavailable due to maintenance. We apologize for the inconvenience. Please try again later.'
WHERE NOT EXISTS (SELECT 1 FROM service_availability WHERE service = 'master');

INSERT INTO service_availability (service, enabled, min_provider_credits, message_ar, message_en)
SELECT 'capacity', true, 0,
  'نظراً للضغط الكبير على الخدمة، لا نستقبل فحوصات جديدة في الوقت الحالي. نرجو المحاولة لاحقاً.',
  'Due to high demand, we are not accepting new checks at the moment. Please try again later.'
WHERE NOT EXISTS (SELECT 1 FROM service_availability WHERE service = 'capacity');

UPDATE service_availability SET min_provider_credits = 2,
  message_ar = 'فحص الانتحال مع الذكاء الاصطناعي غير متاح حالياً. نعمل على إعادة تشغيله قريباً، ونرجو المحاولة لاحقاً.',
  message_en = 'Plagiarism + AI checks are temporarily unavailable. We are working to restore them shortly. Please try again later.',
  updated_at = now()
WHERE service = 'plag_ai';

UPDATE service_availability SET min_provider_credits = 2,
  message_ar = 'فحص الانتحال فقط غير متاح حالياً. يمكنك استخدام فحص الانتحال مع الذكاء الاصطناعي.',
  message_en = 'Plagiarism-only checks are temporarily unavailable. You can use the Plagiarism + AI check instead.',
  updated_at = now()
WHERE service = 'plag_only';

CREATE POLICY service_availability_admin_read ON service_availability
  FOR SELECT TO authenticated USING (is_admin());

CREATE OR REPLACE FUNCTION public.admin_set_service_availability(
  p_master boolean, p_plag_ai boolean, p_plag_only boolean, p_min integer)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT is_admin() THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_min IS NULL OR p_min < 0 THEN RAISE EXCEPTION 'INVALID_THRESHOLD'; END IF;
  UPDATE service_availability SET enabled = p_master, updated_at = now() WHERE service = 'master';
  UPDATE service_availability SET enabled = p_plag_ai, min_provider_credits = p_min, updated_at = now() WHERE service = 'plag_ai';
  UPDATE service_availability SET enabled = p_plag_only, min_provider_credits = p_min, updated_at = now() WHERE service = 'plag_only';
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_set_service_availability(boolean, boolean, boolean, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_service_availability(boolean, boolean, boolean, integer) TO authenticated;
