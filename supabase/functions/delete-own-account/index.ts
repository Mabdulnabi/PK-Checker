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

    // Identify the CALLER from their own JWT (anon-key client) — this is
    // the only account this function will ever delete. There is no way to
    // pass a different target id; self-service only.
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }
    const targetUserId = userData.user.id;

    // Refuse to delete admin accounts this way (mirrors the DB-side guard
    // in self_delete_account()).
    const adminClient = createClient(supabaseUrl, serviceKey);
    const { data: adminRow } = await adminClient.from('admins').select('id').eq('id', targetUserId).maybeSingle();
    if (adminRow) {
      return new Response(JSON.stringify({ error: 'Admin accounts cannot self-delete this way' }), { status: 403, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    // By this point the caller's own app data (orders, wallet, chat,
    // tickets, notifications, users_profile row) has already been wiped by
    // self_delete_account() on the client before this endpoint is called.
    // This step removes the actual Supabase Auth login record, which
    // requires service_role and can't be done from the client itself.
    const { error: deleteErr } = await adminClient.auth.admin.deleteUser(targetUserId);
    if (deleteErr) {
      return new Response(JSON.stringify({ error: deleteErr.message }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    return new Response(JSON.stringify({ success: true }), { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }
});
