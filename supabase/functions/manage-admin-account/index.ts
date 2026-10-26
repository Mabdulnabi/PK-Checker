import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// Handles admin-account actions that need service_role: currently just
// resetting ANOTHER admin's password (an admin can already change their
// OWN password directly via supabase.auth.updateUser(), but that API only
// ever works for the currently-authenticated user — changing someone
// else's password requires admin.updateUserById with service_role).
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  try {
    const authHeader = req.headers.get('Authorization') ?? '';
    const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    // Only admins with manage_admins (or super admins) can reset another
    // admin's password — matches the same gate used for creating admins.
    const { data: callerAdmin } = await callerClient
      .from('admins')
      .select('is_super_admin, permissions')
      .eq('id', userData.user.id)
      .maybeSingle();
    const callerHasPermission = callerAdmin && (callerAdmin.is_super_admin || callerAdmin.permissions?.manage_admins === true);
    if (!callerHasPermission) {
      return new Response(JSON.stringify({ error: 'Only admins with manage_admins permission can do this' }), { status: 403, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    const { action, admin_id, password } = await req.json();
    if (action !== 'reset_password') {
      return new Response(JSON.stringify({ error: 'Unknown action' }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }
    if (!admin_id || !password || password.length < 8) {
      return new Response(JSON.stringify({ error: 'admin_id and a password of at least 8 characters are required' }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    const adminClient = createClient(supabaseUrl, serviceKey);

    // Refuse to let a non-super-admin reset a super admin's password.
    const { data: targetAdmin } = await adminClient.from('admins').select('is_super_admin').eq('id', admin_id).maybeSingle();
    if (!targetAdmin) {
      return new Response(JSON.stringify({ error: 'Admin not found' }), { status: 404, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }
    if (targetAdmin.is_super_admin && !callerAdmin.is_super_admin) {
      return new Response(JSON.stringify({ error: 'Only a super admin can reset another super admin\u2019s password' }), { status: 403, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    const { error: updateErr } = await adminClient.auth.admin.updateUserById(admin_id, { password });
    if (updateErr) {
      return new Response(JSON.stringify({ error: updateErr.message }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    return new Response(JSON.stringify({ success: true }), { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }
});
