-- Past orders take the new code form too: PK-261122-003 -> PK13-261122-3 (same day, same number).
-- The old code is kept in old_display_id, so nothing is lost and old references can still be found.
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS old_display_id text;

UPDATE public.orders o
   SET old_display_id = o.display_id,
       display_id = 'PK' || p.pk_number || '-' || substring(o.display_id FROM '^PK-([0-9]{6})-') || '-'
                    || substring(o.display_id FROM '-([0-9]+)$')::int
  FROM public.users_profile p
 WHERE p.user_id = o.user_id
   AND p.pk_number IS NOT NULL
   AND o.display_id ~ '^PK-[0-9]{6}-[0-9]+$';
