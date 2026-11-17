-- 20261117110000_reviews_on_landing.sql
-- Admins choose which customer reviews appear on the landing page.
-- Until now every review was publicly readable (approved defaults to true); now visitors only see
-- the reviews an admin picked, and a customer can still read their own (the dashboard checks it
-- so the review card is not shown again).

ALTER TABLE public.public_reviews ADD COLUMN IF NOT EXISTS show_on_landing boolean NOT NULL DEFAULT false;

DROP POLICY IF EXISTS "Public read approved reviews" ON public.public_reviews;
DROP POLICY IF EXISTS "Public read landing reviews" ON public.public_reviews;
CREATE POLICY "Public read landing reviews" ON public.public_reviews
  FOR SELECT USING (show_on_landing AND approved);

DROP POLICY IF EXISTS "Users read own review" ON public.public_reviews;
CREATE POLICY "Users read own review" ON public.public_reviews
  FOR SELECT TO authenticated USING (auth.uid() = user_id);

GRANT SELECT ON public.public_reviews TO anon;
