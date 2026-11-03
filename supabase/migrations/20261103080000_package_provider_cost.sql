-- Each package has its own provider cost per check (USD). Existing packages got the tier cost.
ALTER TABLE slot_packages ADD COLUMN IF NOT EXISTS provider_cost_usd numeric(6,3);
UPDATE slot_packages SET provider_cost_usd = CASE WHEN slots >= 10 THEN 0.80 WHEN slots >= 5 THEN 0.82 ELSE 0.85 END WHERE provider_cost_usd IS NULL;
