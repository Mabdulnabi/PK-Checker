import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const authHeader = req.headers.get('Authorization') ?? '';
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    // Verify the CALLER is an authenticated admin with manage_admins permission,
    // using their own JWT (anon-key client) before doing anything privileged.
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    const { data: callerAdmin, error: callerErr } = await callerClient
      .from('admins')
      .select('is_super_admin, permissions')
      .eq('id', userData.user.id)
      .maybeSingle();
    const callerHasPermission = callerAdmin && (callerAdmin.is_super_admin || callerAdmin.permissions?.manage_admins === true);
    if (callerErr || !callerHasPermission) {
      return new Response(JSON.stringify({ error: 'Only admins with manage_admins permission can create new admins' }), { status: 403, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    const { email, password, name, permissions } = await req.json();
    if (!email || !password || !name) {
      return new Response(JSON.stringify({ error: 'email, password, and name are required' }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }
    if (password.length < 8) {
      return new Response(JSON.stringify({ error: 'Password must be at least 8 characters' }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    // Privileged client — service role key never leaves this server-side function.
    const adminClient = createClient(supabaseUrl, serviceKey);

    const { data: newUser, error: createErr } = await adminClient.auth.admin.createUser({
      email, password, email_confirm: true,
    });
    if (createErr || !newUser?.user) {
      return new Response(JSON.stringify({ error: createErr?.message || 'Failed to create auth user' }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    const { error: insertErr } = await adminClient.from('admins').insert({
      id: newUser.user.id,
      name,
      email,
      is_super_admin: false,
      permissions: permissions || {},
    });
    if (insertErr) {
      // Roll back the auth user so we don't leave an orphaned account with no admin row.
      await adminClient.auth.admin.deleteUser(newUser.user.id);
      return new Response(JSON.stringify({ error: insertErr.message }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    return new Response(JSON.stringify({ success: true, id: newUser.user.id }), { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }
});
