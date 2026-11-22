-- Optional picture shown inside a product's custom (manual) badge.
ALTER TABLE public.store_products ADD COLUMN IF NOT EXISTS custom_badge_icon text;
