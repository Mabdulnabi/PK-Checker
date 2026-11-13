-- These functions are called only by database triggers (SECURITY DEFINER, so they run as the owner)
-- and by the service role. Anonymous or logged-in clients must not call them: push_admins and
-- push_user would send notifications to anyone, and meta_send would send fake conversion events.
revoke all on function public.push_admins(text, text, text, text) from public, anon, authenticated;
revoke all on function public.push_user(uuid, text, text, text, text, text, text) from public, anon, authenticated;
revoke all on function public.meta_send(text, text, uuid, numeric, text) from public, anon, authenticated;
revoke all on function public.push_init_secrets() from public, anon, authenticated;
revoke all on function public.service_is_down() from public, anon, authenticated;
