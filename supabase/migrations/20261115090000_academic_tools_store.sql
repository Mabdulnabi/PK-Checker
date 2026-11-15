-- 20261115090000_academic_tools_store.sql
-- Academic Tools store: catalog, instant-delivery stock, subscriptions with delivery and end dates,
-- and a separate Store wallet (not the check slots).
--
-- Secrets: credentials are encrypted with pgcrypto. The key lives in Vault under the name
-- 'store_data_key'. Create it once in the SQL editor (never paste the key in chat):
--   select vault.create_secret('<random 48+ char string>', 'store_data_key');
--
-- Writes to money, stock and orders happen only in SECURITY DEFINER functions below.
-- The browser can read the public catalog and its own orders/wallet, nothing else.

CREATE TABLE IF NOT EXISTS public.store_categories (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug       text UNIQUE NOT NULL,
  name_ar    text NOT NULL,
  name_en    text NOT NULL,
  sort_order int  NOT NULL DEFAULT 0,
  active     boolean NOT NULL DEFAULT true
);

CREATE TABLE IF NOT EXISTS public.store_products (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id     uuid REFERENCES public.store_categories(id) ON DELETE SET NULL,
  name_ar         text NOT NULL,
  name_en         text NOT NULL,
  description_ar  text,
  description_en  text,
  image_url       text,
  delivery_type   text NOT NULL CHECK (delivery_type IN ('instant', 'subscription')),
  active          boolean NOT NULL DEFAULT true,
  sort_order      int NOT NULL DEFAULT 0,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.store_plans (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id      uuid NOT NULL REFERENCES public.store_products(id) ON DELETE CASCADE,
  name_ar         text NOT NULL,
  name_en         text NOT NULL,
  price_egp       numeric(10,2) NOT NULL CHECK (price_egp >= 0),
  duration_days   int NOT NULL CHECK (duration_days > 0),
  guarantee_days  int NOT NULL DEFAULT 0 CHECK (guarantee_days >= 0),
  active          boolean NOT NULL DEFAULT true,
  sort_order      int NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS store_plans_product_idx ON public.store_plans (product_id);

-- Instant-delivery stock. credential_enc = pgp_sym_encrypt(json {email,password,note}).
CREATE TABLE IF NOT EXISTS public.store_stock_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id         uuid NOT NULL REFERENCES public.store_plans(id) ON DELETE CASCADE,
  credential_enc  bytea NOT NULL,
  status          text NOT NULL DEFAULT 'available' CHECK (status IN ('available', 'sold')),
  order_id        uuid,
  created_at      timestamptz NOT NULL DEFAULT now(),
  sold_at         timestamptz
);
CREATE INDEX IF NOT EXISTS store_stock_plan_status_idx ON public.store_stock_items (plan_id, status);

CREATE TABLE IF NOT EXISTS public.store_wallet (
  user_id     uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  balance_egp numeric(12,2) NOT NULL DEFAULT 0 CHECK (balance_egp >= 0),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.store_wallet_tx (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  amount_egp  numeric(12,2) NOT NULL,           -- + credit, - debit
  kind        text NOT NULL CHECK (kind IN ('topup', 'purchase', 'refund', 'admin_adjust')),
  order_id    uuid,
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS store_wallet_tx_user_idx ON public.store_wallet_tx (user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.store_orders (
  id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  product_id     uuid REFERENCES public.store_products(id) ON DELETE SET NULL,
  plan_id        uuid REFERENCES public.store_plans(id) ON DELETE SET NULL,
  product_name   text NOT NULL,                  -- snapshot, so the order survives catalog edits
  plan_name      text NOT NULL,
  price_egp      numeric(10,2) NOT NULL,
  delivery_type  text NOT NULL CHECK (delivery_type IN ('instant', 'subscription')),
  status         text NOT NULL DEFAULT 'paid'
                 CHECK (status IN ('paid', 'delivered', 'refunded')),
  stock_item_id  uuid REFERENCES public.store_stock_items(id) ON DELETE SET NULL,
  delivery_enc   bytea,                          -- subscriptions: credentials/details entered by admin
  deliver_at     timestamptz,                    -- when the customer may see the details
  duration_days  int NOT NULL,
  end_date       timestamptz,                    -- deliver_at + duration (set when delivered)
  created_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS store_orders_user_idx ON public.store_orders (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS store_orders_queue_idx ON public.store_orders (delivery_type, status);

ALTER TABLE public.store_categories   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_products     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_plans        ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_stock_items  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_wallet       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_wallet_tx    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.store_orders       ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.store_categories, public.store_products, public.store_plans,
              public.store_stock_items, public.store_wallet, public.store_wallet_tx, public.store_orders
  FROM anon, authenticated;

-- Catalog: anyone can read active items; admins read and manage everything.
GRANT SELECT ON public.store_categories, public.store_products, public.store_plans TO anon, authenticated;
GRANT INSERT, UPDATE, DELETE ON public.store_categories, public.store_products, public.store_plans TO authenticated;
CREATE POLICY store_categories_read ON public.store_categories FOR SELECT TO anon, authenticated
  USING (active OR public.has_permission('manage_store'));
CREATE POLICY store_products_read ON public.store_products FOR SELECT TO anon, authenticated
  USING (active OR public.has_permission('manage_store'));
CREATE POLICY store_plans_read ON public.store_plans FOR SELECT TO anon, authenticated
  USING (active OR public.has_permission('manage_store'));
CREATE POLICY store_categories_write ON public.store_categories FOR ALL TO authenticated
  USING (public.has_permission('manage_store')) WITH CHECK (public.has_permission('manage_store'));
CREATE POLICY store_products_write ON public.store_products FOR ALL TO authenticated
  USING (public.has_permission('manage_store')) WITH CHECK (public.has_permission('manage_store'));
CREATE POLICY store_plans_write ON public.store_plans FOR ALL TO authenticated
  USING (public.has_permission('manage_store')) WITH CHECK (public.has_permission('manage_store'));

-- Stock, wallet ledger and orders: read own rows only (stock has no direct access at all).
GRANT SELECT ON public.store_wallet, public.store_wallet_tx, public.store_orders TO authenticated;
CREATE POLICY store_wallet_own ON public.store_wallet FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.has_permission('manage_store'));
CREATE POLICY store_wallet_tx_own ON public.store_wallet_tx FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.has_permission('manage_store'));
CREATE POLICY store_orders_own ON public.store_orders FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR public.has_permission('manage_store'));

-- ── Helpers ───────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.store_key()
RETURNS text
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public', 'vault'
AS $$
  SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'store_data_key' LIMIT 1;
$$;
REVOKE EXECUTE ON FUNCTION public.store_key() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.store_encrypt(p_json jsonb)
RETURNS bytea
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE k text := public.store_key();
BEGIN
  IF k IS NULL THEN RAISE EXCEPTION 'store_data_key missing in Vault'; END IF;
  RETURN extensions.pgp_sym_encrypt(p_json::text, k);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_encrypt(jsonb) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.store_decrypt(p_enc bytea)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE k text := public.store_key();
BEGIN
  IF k IS NULL THEN RAISE EXCEPTION 'store_data_key missing in Vault'; END IF;
  RETURN extensions.pgp_sym_decrypt(p_enc, k)::jsonb;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_decrypt(bytea) FROM PUBLIC, anon, authenticated;

-- ── Admin: stock ─────────────────────────────────────────────────────────────
-- p_items: [{"email":"...","password":"...","note":"..."}, ...]
CREATE OR REPLACE FUNCTION public.store_admin_add_stock(p_plan_id uuid, p_items jsonb)
RETURNS int
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $$
DECLARE it jsonb; n int := 0;
BEGIN
  IF NOT public.has_permission('manage_store') THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF jsonb_typeof(p_items) <> 'array' THEN RAISE EXCEPTION 'items must be an array'; END IF;
  FOR it IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO public.store_stock_items (plan_id, credential_enc)
    VALUES (p_plan_id, public.store_encrypt(jsonb_build_object(
      'email', coalesce(it->>'email', ''),
      'password', coalesce(it->>'password', ''),
      'note', coalesce(it->>'note', ''))));
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$$;

-- Deletes unsold stock only. Sold items stay so the customer keeps access to what they bought.
CREATE OR REPLACE FUNCTION public.store_admin_delete_stock(p_item_id uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  IF NOT public.has_permission('manage_store') THEN RAISE EXCEPTION 'not allowed'; END IF;
  DELETE FROM public.store_stock_items WHERE id = p_item_id AND status = 'available';
  RETURN FOUND;
END;
$$;

-- Plan stock counts for the admin page and the customer's "available" badge.
CREATE OR REPLACE FUNCTION public.store_plan_stock()
RETURNS TABLE(plan_id uuid, available int, sold int)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT s.plan_id,
         count(*) FILTER (WHERE s.status = 'available')::int,
         count(*) FILTER (WHERE s.status = 'sold')::int
  FROM public.store_stock_items s
  GROUP BY s.plan_id;
$$;
GRANT EXECUTE ON FUNCTION public.store_plan_stock() TO anon, authenticated;

-- ── Admin: wallet ────────────────────────────────────────────────────────────
-- Manual credit/debit until the payment gateways are connected to the Store wallet.
CREATE OR REPLACE FUNCTION public.store_admin_wallet_adjust(p_user_id uuid, p_amount numeric, p_note text)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE newbal numeric;
BEGIN
  IF NOT public.has_permission('manage_store') THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_amount = 0 THEN RAISE EXCEPTION 'amount must not be zero'; END IF;
  INSERT INTO public.store_wallet (user_id, balance_egp) VALUES (p_user_id, 0)
  ON CONFLICT (user_id) DO NOTHING;
  UPDATE public.store_wallet SET balance_egp = balance_egp + p_amount, updated_at = now()
  WHERE user_id = p_user_id AND balance_egp + p_amount >= 0
  RETURNING balance_egp INTO newbal;
  IF newbal IS NULL THEN RAISE EXCEPTION 'balance would go negative'; END IF;
  INSERT INTO public.store_wallet_tx (user_id, amount_egp, kind, note)
  VALUES (p_user_id, p_amount, 'admin_adjust', p_note);
  RETURN newbal;
END;
$$;

-- ── Customer: buy with wallet ───────────────────────────────────────────────
-- Instant products: one stock item is reserved and delivered at once.
-- Subscriptions: the order is paid and waits for the admin to deliver the details.
CREATE OR REPLACE FUNCTION public.store_buy(p_plan_id uuid)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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

  -- Wallet row locked for this purchase, so two buys can't spend the same balance.
  INSERT INTO public.store_wallet (user_id, balance_egp) VALUES (uid, 0) ON CONFLICT (user_id) DO NOTHING;
  SELECT balance_egp INTO bal FROM public.store_wallet WHERE user_id = uid FOR UPDATE;
  IF bal < pl.price_egp THEN RAISE EXCEPTION 'insufficient_balance'; END IF;

  IF pr.delivery_type = 'instant' THEN
    SELECT id INTO stock_id FROM public.store_stock_items
    WHERE plan_id = pl.id AND status = 'available'
    ORDER BY created_at
    LIMIT 1
    FOR UPDATE SKIP LOCKED;
    IF stock_id IS NULL THEN RAISE EXCEPTION 'out_of_stock'; END IF;
  END IF;

  UPDATE public.store_wallet SET balance_egp = balance_egp - pl.price_egp, updated_at = now() WHERE user_id = uid;
  INSERT INTO public.store_wallet_tx (user_id, amount_egp, kind, order_id, note)
  VALUES (uid, -pl.price_egp, 'purchase', oid, pr.name_en || ' - ' || pl.name_en);

  -- Order row first, then the stock item points at it (the FK needs the order to exist).
  INSERT INTO public.store_orders (id, user_id, product_id, plan_id, product_name, plan_name, price_egp,
                                   delivery_type, status, stock_item_id, deliver_at, end_date, duration_days)
  VALUES (oid, uid, pr.id, pl.id, pr.name_en, pl.name_en, pl.price_egp, pr.delivery_type,
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

-- Stock item gets its order id as a back-reference, so it can be traced to a sale.
ALTER TABLE public.store_stock_items
  ADD CONSTRAINT store_stock_items_order_fk FOREIGN KEY (order_id) REFERENCES public.store_orders(id) ON DELETE SET NULL
  NOT VALID;

-- ── Admin: subscription delivery ────────────────────────────────────────────
-- Sets the details to send to the customer at p_deliver_at (now or later). The end date is set
-- from the delivery time, so the customer's countdown starts when they get access.
CREATE OR REPLACE FUNCTION public.store_admin_deliver_subscription(p_order_id uuid, p_details jsonb, p_deliver_at timestamptz)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE o record;
BEGIN
  IF NOT public.has_permission('manage_store') THEN RAISE EXCEPTION 'not allowed'; END IF;
  SELECT * INTO o FROM public.store_orders WHERE id = p_order_id AND delivery_type = 'subscription';
  IF NOT FOUND THEN RAISE EXCEPTION 'order not found'; END IF;
  UPDATE public.store_orders
  SET delivery_enc = public.store_encrypt(p_details),
      deliver_at   = coalesce(p_deliver_at, now()),
      end_date     = coalesce(p_deliver_at, now()) + (o.duration_days || ' days')::interval,
      status       = 'delivered'
  WHERE id = p_order_id;
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_admin_deliver_subscription(uuid, jsonb, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_admin_deliver_subscription(uuid, jsonb, timestamptz) TO authenticated;

-- ── Customer: my orders and details ─────────────────────────────────────────
-- Details are returned only to the buyer, and only once they are due (deliver_at <= now()).
CREATE OR REPLACE FUNCTION public.store_my_order_details(p_order_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
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
  RETURN public.store_decrypt(enc);
END;
$$;
REVOKE EXECUTE ON FUNCTION public.store_my_order_details(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.store_my_order_details(uuid) TO authenticated;
