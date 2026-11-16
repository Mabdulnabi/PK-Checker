-- 20261116050000_public_slot_packages.sql
-- The landing page lists the check packages (name, slots, price, validity) to visitors who are
-- not signed in. list_slot_packages only returns active Plag + AI packages and no private data.
GRANT EXECUTE ON FUNCTION public.list_slot_packages() TO anon;
