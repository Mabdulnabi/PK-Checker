-- 20261115000000_lock_privilege_and_money_columns.sql
--
-- Review fixes (item 13):
--   1. admins: an admin could UPDATE its own permissions / is_super_admin through the REST API.
--   2. payments: admins had no UPDATE policy, so approving a payment silently updated 0 rows.
--      Admin UPDATE is added here, and the approve button is guarded in admin-dashboard.html.
--   3. payments: customers could change amount / pack / status / gateway of their own pending payment.
--   4. orders: customers could set status to completed and write report links / scores on their own order.
--   5. anon / authenticated held TRUNCATE, REFERENCES and TRIGGER on every public table.
--
-- Service-role callers (edge functions, confirm_topup, reserve_slot, manage-files) have
-- auth.uid() = NULL, so the guards below never apply to them.

-- 1) admins: only a super admin can change permissions or super-admin status.
--    A manage_admins holder can change permissions of other admins, but not of itself.
create or replace function public.guard_admin_privilege_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if (new.permissions is distinct from old.permissions
      or new.is_super_admin is distinct from old.is_super_admin)
     and auth.uid() is not null then
    if not coalesce((select a.is_super_admin from public.admins a where a.id = auth.uid()), false) then
      if new.is_super_admin is distinct from old.is_super_admin then
        raise exception 'NOT_ALLOWED: only a super admin can change super admin status';
      end if;
      if auth.uid() = old.id or not public.has_permission('manage_admins') then
        raise exception 'NOT_ALLOWED: insufficient privileges to change permissions';
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_admin_privileges on public.admins;
create trigger trg_guard_admin_privileges
  before update on public.admins
  for each row execute function public.guard_admin_privilege_changes();

-- 2) payments: admins can update payments (approve / reject from the dashboard).
drop policy if exists "Admins update payments" on public.payments;
create policy "Admins update payments" on public.payments
  for update to authenticated
  using (public.is_admin())
  with check (public.is_admin());

-- 3) payments: a non-admin may change only transaction_id (the manual "I paid" reference).
create or replace function public.guard_customer_payment_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and not public.is_admin() then
    if (to_jsonb(new) - 'transaction_id' - 'updated_at')
       is distinct from (to_jsonb(old) - 'transaction_id' - 'updated_at') then
      raise exception 'NOT_ALLOWED: only the transaction reference can be changed';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_customer_payment_update on public.payments;
create trigger trg_guard_customer_payment_update
  before update on public.payments
  for each row execute function public.guard_customer_payment_update();

-- 4) orders: a customer may move their own order only between uploading / floating / error,
--    and may not touch results, scores, links, billing or provider fields.
create or replace function public.guard_customer_order_update()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null and auth.uid() = old.user_id and not public.is_admin() then
    if (to_jsonb(new) - 'status' - 'error_reason' - 'source_file_path' - 'rating' - 'rating_comment'
                      - 'updated_at' - 'processing_started_at' - 'exclude_bibliography' - 'exclude_quotes'
                      - 'exclude_abstract' - 'exclude_small_matches_word_limit')
       is distinct from
       (to_jsonb(old) - 'status' - 'error_reason' - 'source_file_path' - 'rating' - 'rating_comment'
                      - 'updated_at' - 'processing_started_at' - 'exclude_bibliography' - 'exclude_quotes'
                      - 'exclude_abstract' - 'exclude_small_matches_word_limit') then
      raise exception 'NOT_ALLOWED: this order field is read-only for customers';
    end if;
    if new.status is distinct from old.status then
      if old.status not in ('uploading', 'floating', 'error')
         or new.status not in ('uploading', 'floating', 'error') then
        raise exception 'NOT_ALLOWED: invalid status change for customer';
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_customer_order_update on public.orders;
create trigger trg_guard_customer_order_update
  before update on public.orders
  for each row execute function public.guard_customer_order_update();

-- 5) Remove TRUNCATE / REFERENCES / TRIGGER from the client roles (RLS does not cover TRUNCATE).
do $$
declare r record;
begin
  for r in select tablename from pg_tables where schemaname = 'public' loop
    execute format('revoke truncate, references, trigger on public.%I from anon, authenticated', r.tablename);
  end loop;
end;
$$;
