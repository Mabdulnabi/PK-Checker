-- Editable site texts (for example the Check page terms). Readable by everyone,
-- written only by admins from the admin dashboard, so no code change is needed to edit them.
CREATE TABLE IF NOT EXISTS public.site_texts (
  key         text PRIMARY KEY,
  value_ar    text NOT NULL DEFAULT '',
  value_en    text NOT NULL DEFAULT '',
  updated_at  timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.site_texts ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "site texts readable" ON public.site_texts;
CREATE POLICY "site texts readable" ON public.site_texts
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS "admins manage site texts" ON public.site_texts;
CREATE POLICY "admins manage site texts" ON public.site_texts
  FOR ALL TO authenticated USING (public.is_admin()) WITH CHECK (public.is_admin());

GRANT SELECT ON public.site_texts TO anon, authenticated;
GRANT INSERT, UPDATE ON public.site_texts TO authenticated;

INSERT INTO public.site_texts (key, value_ar, value_en) VALUES (
  'check_terms',
  E'حدود خطة Turnitin: الانتحال حتى 50,000 كلمة. كشف الذكاء الاصطناعي حتى 30,000 كلمة (قاعدة Turnitin الرسمية).\nمتطلبات كشف الذكاء الاصطناعي: حجم الملف أقل من 100 ميجا، اللغات: إنجليزي وإسباني وياباني، الحد الأدنى 300 كلمة (فقرة)، الحد الأقصى 30,000 كلمة.\nالخصوصية: الملفات لا يتم حفظها في أي مستودع.',
  E'Turnitin plan limits: plagiarism up to 50,000 words. AI detection up to 30,000 words (Turnitin\'s official AI engine rule).\nAI detection requirements: file size under 100 MB, languages: English, Spanish, Japanese, minimum 300 words (per paragraph), maximum 30,000 words.\nPrivacy: files are not saved in any repository.'
) ON CONFLICT (key) DO NOTHING;
