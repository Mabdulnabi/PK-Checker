-- The word count of the submitted file (counted in the customer's browser), kept on the order.
-- Used for the notice shown when a check with AI detection was sent with more than 30,000 words
-- (Turnitin's AI limit): only the similarity report comes back for such a file.
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS word_count integer;
