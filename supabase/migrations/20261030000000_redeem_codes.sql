-- Redeem codes: single-use credit vouchers.
-- Admins generate them from the Payments tab; customers redeem them from the
-- Check tab. Each code works exactly once: the redeem step marks the row and
-- writes the wallet credit in the same transaction.

create table if not exists public.redeem_codes (
  id           uuid primary key default gen_random_uuid(),
  code         text not null unique,
  credits      integer not null check (credits > 0),
  created_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  redeemed_by  uuid references auth.users(id) on delete set null,
  redeemed_at  timestamptz
);

alter table public.redeem_codes enable row level security;

-- Admins may read the list. Nobody writes directly; all writes go through the
-- SECURITY DEFINER functions below.
drop policy if exists "admins read redeem codes" on public.redeem_codes;
create policy "admins read redeem codes" on public.redeem_codes
  for select to authenticated
  using (exists (select 1 from public.admins a where a.id = auth.uid()));

revoke all on public.redeem_codes from anon, authenticated;
grant select on public.redeem_codes to authenticated;

-- Generates p_count single-use codes worth p_credits each.
-- Codes are 16 random hex characters (64 bits), shown as XXXX-XXXX-XXXX-XXXX.
create or replace function public.admin_create_redeem_codes(p_credits integer, p_count integer)
returns table(redeem_code text, redeem_credits integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.admins%rowtype;
  v_hex   text;
  v_code  text;
begin
  select * into v_admin from public.admins where id = auth.uid();
  if not found or not (v_admin.is_super_admin or coalesce((v_admin.permissions->>'manage_credits')::boolean, false)) then
    raise exception 'FORBIDDEN';
  end if;
  if p_credits is null or p_credits <= 0 then
    raise exception 'INVALID_CREDITS';
  end if;
  if p_count is null or p_count < 1 or p_count > 500 then
    raise exception 'INVALID_COUNT';
  end if;

  for i in 1..p_count loop
    loop
      v_hex  := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));
      v_code := substr(v_hex, 1, 4) || '-' || substr(v_hex, 5, 4) || '-' || substr(v_hex, 9, 4) || '-' || substr(v_hex, 13, 4);
      exit when not exists (select 1 from public.redeem_codes rc where rc.code = v_code);
    end loop;

    insert into public.redeem_codes (code, credits, created_by)
    values (v_code, p_credits, auth.uid());

    redeem_code := v_code;
    redeem_credits := p_credits;
    return next;
  end loop;
end;
$$;

-- Redeems a code for the calling user. Returns { credits, balance_after }.
-- Raises INVALID_CODE or CODE_ALREADY_USED.
create or replace function public.redeem_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid            uuid := auth.uid();
  v_norm           text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_credits        integer;
  v_balance_before numeric;
  v_balance_after  numeric;
begin
  if v_uid is null then
    raise exception 'NOT_AUTHENTICATED';
  end if;
  if length(v_norm) <> 16 then
    raise exception 'INVALID_CODE';
  end if;

  -- Atomic single-use claim: only one caller can flip redeemed_at from NULL.
  update public.redeem_codes
     set redeemed_by = v_uid, redeemed_at = now()
   where replace(code, '-', '') = v_norm
     and redeemed_at is null
  returning credits into v_credits;

  if v_credits is null then
    if exists (select 1 from public.redeem_codes where replace(code, '-', '') = v_norm) then
      raise exception 'CODE_ALREADY_USED';
    end if;
    raise exception 'INVALID_CODE';
  end if;

  select balance_after into v_balance_before
    from public.wallet_transactions
   where user_id = v_uid
   order by created_at desc
   limit 1;
  v_balance_before := coalesce(v_balance_before, 0);
  v_balance_after  := v_balance_before + v_credits;

  insert into public.wallet_transactions (user_id, type, amount, balance_before, balance_after, description)
  values (v_uid, 'credit', v_credits, v_balance_before, v_balance_after, 'كود خصم');

  return jsonb_build_object('credits', v_credits, 'balance_after', v_balance_after);
end;
$$;

revoke execute on function public.admin_create_redeem_codes(integer, integer) from public, anon;
revoke execute on function public.redeem_code(text) from public, anon;
grant execute on function public.admin_create_redeem_codes(integer, integer) to authenticated;
grant execute on function public.redeem_code(text) to authenticated;
