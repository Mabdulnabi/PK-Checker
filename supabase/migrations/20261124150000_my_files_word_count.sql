-- My Files: each file's word count, for the "Word Limit (>30k)" badge in the AI column
-- (a check with AI detection sent with more than 30,000 words gets the similarity report only).
DO $mig$
DECLARE d text;
BEGIN
  d := pg_get_functiondef('public.my_checked_files'::regproc);
  IF position('o.word_count' in d) = 0 THEN
    d := replace(d, '           o.error_reason,', '           o.error_reason,
           o.word_count,');
    IF position('o.word_count' in d) = 0 THEN RAISE EXCEPTION 'my_checked_files: expected text not found'; END IF;
    EXECUTE d;
  END IF;
END
$mig$;
