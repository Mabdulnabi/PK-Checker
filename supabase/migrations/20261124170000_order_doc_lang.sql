-- The language of the submitted file (detected in the customer's browser from the file's text:
-- en, es, ja, ar, fr, de, pt, it, tr, id, fa, zh, ru, ... or null when it could not be read).
-- Turnitin's AI detection supports English, Spanish, Japanese and Arabic: a check with AI on a file in
-- another language shows "Not Supported" in the AI column instead of "Result unavailable".
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS doc_lang text;

DO $mig$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.my_checked_files'::regproc);
  IF position('o.doc_lang' in d) = 0 THEN
    d := replace(d, '           o.word_count,', '           o.word_count,
           o.doc_lang,');
    IF position('o.doc_lang' in d) = 0 THEN RAISE EXCEPTION 'my_checked_files: expected text not found'; END IF;
    EXECUTE d;
  END IF;
END
$mig$;
