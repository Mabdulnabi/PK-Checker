-- Adjustments are by package now (admin_grant_package / admin_deduct_slots); the count-only RPC is not used.
DROP FUNCTION IF EXISTS public.admin_grant_checks(uuid, integer, text);
