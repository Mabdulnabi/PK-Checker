# Supabase backend

Project ref: `ixpgqhwausnfjphitsty`. The database and edge functions are shared by every branch and by production, so a change here is live as soon as it is applied or deployed.

## Layout

- `migrations/` SQL in apply order. Each file is written to be run once.
- `functions/` edge function sources. The deployed copy must match the file here.

## Applying a migration

Run the file in the Supabase SQL editor, or with `supabase db push`. Do not edit an applied migration. Add a new file instead.

| File | What it does |
|---|---|
| `20261030000000_redeem_codes.sql` | Redeem code table and the admin generator |
| `20261031000000_security_and_topup_hardening.sql` | Locks down RPC grants, adds admin checks to broadcast and backup functions, adds `confirm_topup()` and the redeem rate limit, and makes vault secret readers service-role only |

## Deploying an edge function

Deploy the file in `functions/<name>/index.ts` with `verify_jwt` set as listed below.

| Function | verify_jwt | Auth in code |
|---|---|---|
| `get-api-credits` | false | Admin only (checks `admins`) |
| `turnitin-webhook` | false | None. TurniScan does not sign webhooks, so every update is re-read from `/v1/scan/status` |
| `verify-easykash`, `verify-sms`, `verify-binance`, `verify-bybit`, `verify-bep20` | false | User JWT checked in code, then credit via `confirm_topup()` |

## Secrets read by functions

- `TURNISCAN_API_KEY`: Turnitin API.
- `EASYKASH_API_KEY`: EasyKash inquiry.
- `GOOGLE_SERVICE_ACCOUNT_JSON`: Sheet reads for `verify-sms`.
- `BINANCE_API_KEY` / `BINANCE_API_SECRET`, `BYBIT_API_KEY` / `BYBIT_API_SECRET`, `BEP20_ADDRESS` / `BEP20_API_KEY`: read from the Vault first, then from env.
- `PROKEYS_SUPABASE_URL`, `PROKEYS_ANON_KEY`, `PROKEYS_SERVICE_ROLE_KEY`: used by the verifiers.

## Rules to keep

- Client code calls only RPCs that are granted to `authenticated`. Functions that need a service role (`confirm_topup`, `get_payment_api_secret`, `get_resend_api_key`) are for edge functions only.
- Cron jobs run as `postgres`, so they are not affected by grants. Do not add an `is_admin()` check to a cron-only function.
- Any `SECURITY DEFINER` function must check the caller inside its body.
