-- 20261120100000_review_replies.sql
-- Admins can reply to a customer's service review. The reply shows under the review on the
-- landing page, and the customer gets a notification with it.

ALTER TABLE public.public_reviews ADD COLUMN IF NOT EXISTS admin_reply text;
ALTER TABLE public.public_reviews ADD COLUMN IF NOT EXISTS admin_reply_at timestamptz;

-- Save (or clear, with an empty text) the reply to one review.
CREATE OR REPLACE FUNCTION public.admin_reply_review(p_review_id uuid, p_reply text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE r record; v text := nullif(trim(coalesce(p_reply, '')), '');
BEGIN
  IF NOT (public.is_admin() AND public.has_permission('manage_ui_design')) THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF v IS NOT NULL AND length(v) > 1000 THEN RAISE EXCEPTION 'reply too long'; END IF;
  SELECT * INTO r FROM public.public_reviews WHERE id = p_review_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'review not found'; END IF;

  UPDATE public.public_reviews
  SET admin_reply = v, admin_reply_at = CASE WHEN v IS NULL THEN NULL ELSE now() END
  WHERE id = p_review_id;

  -- Tell the customer about a new or changed reply.
  IF v IS NOT NULL AND r.user_id IS NOT NULL AND v IS DISTINCT FROM r.admin_reply THEN
    INSERT INTO public.notifications (user_id, type, title_ar, title_en, body_ar, body_en)
    VALUES (r.user_id, 'review_reply', 'رد على تقييمك ⭐', 'A reply to your review ⭐', v, v);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reply_review(uuid, text) FROM public, anon;
GRANT EXECUTE ON FUNCTION public.admin_reply_review(uuid, text) TO authenticated;
