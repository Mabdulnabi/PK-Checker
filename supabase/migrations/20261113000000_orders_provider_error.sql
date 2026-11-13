-- The provider's own failure message, shown to admins only (customers get a neutral message).
alter table public.orders add column if not exists provider_error text;
