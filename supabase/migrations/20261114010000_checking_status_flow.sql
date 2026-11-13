-- Orders whose submit outcome is unknown (timeout / dropped connection) wait in status 'checking'
-- with their slot still reserved. The provider's webhook confirms them. If nothing confirms the
-- order within 2 hours, the slot is released and the order is marked as an error.
create or replace function public.sweep_checking_orders()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare r record;
begin
  for r in
    select id from public.orders
    where status = 'checking' and completed_at < now() - interval '2 hours'
  loop
    perform public.release_slot('order:' || r.id::text);
    update public.orders
       set status = 'error',
           error_reason = 'We could not confirm the file reached the check service. Your check was not used.'
     where id = r.id;
  end loop;
end $$;

revoke all on function public.sweep_checking_orders() from public, anon, authenticated;

select cron.unschedule('sweep-checking-orders') where exists (select 1 from cron.job where jobname = 'sweep-checking-orders');
select cron.schedule('sweep-checking-orders', '*/5 * * * *', 'select public.sweep_checking_orders();');
