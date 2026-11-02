-- Wallet: the top-up packages come from slot_packages (active Plagiarism + AI only,
-- Plagiarism Only stays hidden for now).
CREATE OR REPLACE FUNCTION public.list_slot_packages()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'legacy_pack_id', sp.legacy_pack_id,
           'slots', sp.slots,
           'price_egp', sp.price_egp,
           'expiry_days', sp.expiry_days,
           'name_ar', sp.name_ar,
           'name_en', sp.name_en
         ) ORDER BY sp.sort_order), '[]'::jsonb)
  FROM slot_packages sp
  WHERE sp.is_active
    AND sp.slot_type = 'plag_ai'
    AND sp.legacy_pack_id IS NOT NULL;
$$;

REVOKE EXECUTE ON FUNCTION public.list_slot_packages() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.list_slot_packages() TO authenticated;
