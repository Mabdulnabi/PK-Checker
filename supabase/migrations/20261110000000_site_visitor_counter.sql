-- Visitor counter: one row with the running total. Only the two functions touch it.
create table if not exists public.site_visitor_counter (
  id int primary key default 1 check (id = 1),
  total bigint not null default 0
);
insert into public.site_visitor_counter (id, total) values (1, 198) on conflict (id) do nothing;
alter table public.site_visitor_counter enable row level security;

create or replace function public.visitor_count_get() returns bigint
language sql stable security definer set search_path = public
as $$ select total from public.site_visitor_counter where id = 1 $$;

create or replace function public.visitor_count_hit() returns bigint
language plpgsql security definer set search_path = public
as $$ declare v bigint; begin
  update public.site_visitor_counter set total = total + 1 where id = 1 returning total into v;
  return v;
end $$;

revoke all on function public.visitor_count_get() from public;
revoke all on function public.visitor_count_hit() from public;
grant execute on function public.visitor_count_get() to anon, authenticated;
grant execute on function public.visitor_count_hit() to anon, authenticated;
