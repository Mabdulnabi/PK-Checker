-- Payments: a reference the customer puts in the Binance / Bybit transfer note (Pkchecker PAY-XXXXXXX).
ALTER TABLE payments ADD COLUMN IF NOT EXISTS reference text;
CREATE UNIQUE INDEX IF NOT EXISTS payments_reference_key ON payments (reference) WHERE reference IS NOT NULL;
