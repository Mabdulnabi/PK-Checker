-- 20261115100000_academic_tools_store_v2.sql
-- Academic Tools store, design pass: banners, category images, product badges and rating,
-- old (official) price per plan, Shared/Private products, and the order state
-- Ordered -> Delivered -> Active (customer opened the credentials) -> Renew (expired).

-- Banners (1200x280) and the slider interval, both managed from the admin dashboard.
CREATE TABLE IF NOT EXISTS public.store_banners (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  image_url   text NOT NULL,
  link_url    text,
  sort_order  int NOT NULL DEFAULT 0,
  active      boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.store_settings (
  id                  int PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  banner_interval_ms  int NOT NULL DEFAULT 5000 CHECK (banner_interval_ms BETWEEN 1500 AND 60000)
);
INSERT INTO public.store_settings (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

ALTER TABLE public.store_categories ADD COLUMN IF NOT EXISTS image_url text;

ALTER TABLE public.store_products
  ADD COLUMN IF NOT EXISTS account_type       text NOT NULL DEFAULT 'private' CHECK (account_type IN ('shared', 'private')),
  ADD COLUMN IF NOT EXISTS rating             numeric(2,1) NOT NULL DEFAULT 5.0 CHECK (rating BETWEEN 0 AND 5),
  ADD COLUMN IF NOT EXISTS rating_count       int NOT NULL DEFAULT 0 CHECK (rating_count >= 0),
  ADD COLUMN IF NOT EXISTS show_discount      boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS show_delivery      boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS show_stock         boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS custom_badge_text  text,
  ADD COLUMN IF NOT EXISTS custom_badge_color text;

ALTER TABLE public.store_plans ADD COLUMN IF NOT EXISTS old_price_egp numeric(10,2) CHECK (old_price_egp IS NULL OR old_price_egp >= 0);

ALTER TABLE public.store_orders
  ADD COLUMN IF NOT EXISTS old_price_egp numeric(10,2),
  ADD COLUMN IF NOT EXISTS viewed_at     timestamptz;

ALTER TABLE public.store_banners  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.store_banners, public.store_settings FROM anon, authenticated;
GRANT SELECT ON public.store_banners, public.store_settings TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.store_banners TO authenticated;
GRANT UPDATE ON public.store_settings TO authenticated;

DROP POLICY IF EXISTS store_banners_read ON public.store_banners;
CREATE POLICY store_banners_read ON public.store_banners FOR SELECT TO anon, authenticated
  USING (active OR public.has_permission('manage_store'));
DROP POLICY IF EXISTS store_banners_write ON public.store_banners;
CREATE POLICY store_banners_write ON public.store_banners FOR ALL TO authenticated
  USING (public.has_permission('manage_store')) WITH CHECK (public.has_permission('manage_store'));
DROP POLICY IF EXISTS store_settings_read ON public.store_settings;
CREATE POLICY store_settings_read ON public.store_settings FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS store_settings_write ON public.store_settings;
CREATE POLICY store_settings_write ON public.store_settings FOR UPDATE TO authenticated
  USING (public.has_permission('manage_store')) WITH CHECK (public.has_permission('manage_store'));

-- Public image bucket for banners, category images and product logos. Admins with manage_store write.
INSERT INTO storage.buckets (id, name, public) VALUES ('store-assets', 'store-assets', true)
ON CONFLICT (id) DO UPDATE SET public = true;
DROP POLICY IF EXISTS store_assets_read ON storage.objects;
CREATE POLICY store_assets_read ON storage.objects FOR SELECT TO anon, authenticated
  USING (bucket_id = 'store-assets');
DROP POLICY IF EXISTS store_assets_insert ON storage.objects;
CREATE POLICY store_assets_insert ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'store-assets' AND public.has_permission('manage_store'));
DROP POLICY IF EXISTS store_assets_update ON storage.objects;
CREATE POLICY store_assets_update ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id = 'store-assets' AND public.has_permission('manage_store'));
DROP POLICY IF EXISTS store_assets_delete ON storage.objects;
CREATE POLICY store_assets_delete ON storage.objects FOR DELETE TO authenticated
  USING (bucket_id = 'store-assets' AND public.has_permission('manage_store'));

-- Buy: also keep the plan's official (old) price on the order, for the savings card.
CREATE OR REPLACE FUNCTION public.store_buy(p_plan_id uuid)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  uid uuid := auth.uid();
  pl record;
  pr record;
  bal numeric;
  stock_id uuid;
  oid uuid := gen_random_uuid();
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'login required'; END IF;
  SELECT * INTO pl FROM public.store_plans WHERE id = p_plan_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'plan not available'; END IF;
  SELECT * INTO pr FROM public.store_products WHERE id = pl.product_id AND active;
  IF NOT FOUND THEN RAISE EXCEPTION 'product not available'; END IF;

  INSERT INTO public.store_wallet (user_id, balance_egp) VALUES (uid, 0) ON CONFLICT (user_id) DO NOTHING;
  SELECT balance_egp INTO bal FROM public.store_wallet WHERE user_id = uid FOR UPDATE;
  IF bal < pl.price_egp THEN RAISE EXCEPTION 'insufficient_balance'; END IF;

  IF pr.delivery_type = 'instant' THEN
    SELECT id INTO stock_id FROM public.store_stock_items
    WHERE plan_id = pl.id AND status = 'available'
    ORDER BY created_at LIMIT 1
    FOR UPDATE SKIP LOCKED;
    IF stock_id IS NULL THEN RAISE EXCEPTION 'out_of_stock'; END IF;
  END IF;

  UPDATE public.store_wallet SET balance_egp = balance_egp - pl.price_egp, updated_at = now() WHERE user_id = uid;
  INSERT INTO public.store_wallet_tx (user_id, amount_egp, kind, order_id, note)
  VALUES (uid, -pl.price_egp, 'purchase', oid, pr.name_en || ' - ' || pl.name_en);

  INSERT INTO public.store_orders (id, user_id, product_id, plan_id, product_name, plan_name, price_egp, old_price_egp,
                                   delivery_type, status, stock_item_id, deliver_at, end_date, duration_days)
  VALUES (oid, uid, pr.id, pl.id, pr.name_en, pl.name_en, pl.price_egp, pl.old_price_egp, pr.delivery_type,
          CASE WHEN pr.delivery_type = 'instant' THEN 'delivered' ELSE 'paid' END,
          stock_id,
          CASE WHEN pr.delivery_type = 'instant' THEN now() ELSE NULL END,
          CASE WHEN pr.delivery_type = 'instant' THEN now() + (pl.duration_days || ' days')::interval ELSE NULL END,
          pl.duration_days);

  IF stock_id IS NOT NULL THEN
    UPDATE public.store_stock_items SET status = 'sold', order_id = oid, sold_at = now() WHERE id = stock_id;
  END IF;

  RETURN oid;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_buy(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_buy(uuid) TO authenticated;

-- Details: opening them for the first time marks the subscription Active.
CREATE OR REPLACE FUNCTION public.store_my_order_details(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE o record; enc bytea;
BEGIN
  SELECT * INTO o FROM public.store_orders WHERE id = p_order_id AND user_id = auth.uid();
  IF NOT FOUND THEN RAISE EXCEPTION 'order not found'; END IF;
  IF o.deliver_at IS NULL OR o.deliver_at > now() THEN RETURN NULL; END IF;
  IF o.delivery_type = 'instant' THEN
    SELECT credential_enc INTO enc FROM public.store_stock_items WHERE id = o.stock_item_id;
  ELSE
    enc := o.delivery_enc;
  END IF;
  IF enc IS NULL THEN RETURN NULL; END IF;
  UPDATE public.store_orders SET viewed_at = now() WHERE id = p_order_id AND viewed_at IS NULL;
  RETURN public.store_decrypt(enc);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_my_order_details(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_my_order_details(uuid) TO authenticated;
