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

    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: 'Not authenticated' }), { status: 401, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    const { data: callerAdmin } = await callerClient
      .from('admins')
      .select('is_super_admin, permissions')
      .eq('id', userData.user.id)
      .maybeSingle();
    const callerHasPermission = callerAdmin && (callerAdmin.is_super_admin || callerAdmin.permissions?.manage_users === true);
    if (!callerHasPermission) {
      return new Response(JSON.stringify({ error: 'Only admins with manage_users permission can add customers' }), { status: 403, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    const { email, password, full_name, whatsapp, phone, initial_credits } = await req.json();
    if (!email || !password || !full_name) {
      return new Response(JSON.stringify({ error: 'email, password, and full_name are required' }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }
    if (password.length < 8) {
      return new Response(JSON.stringify({ error: 'Password must be at least 8 characters' }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    const adminClient = createClient(supabaseUrl, serviceKey);

    const { data: newUser, error: createErr } = await adminClient.auth.admin.createUser({
      email, password, email_confirm: true,
    });
    if (createErr || !newUser?.user) {
      return new Response(JSON.stringify({ error: createErr?.message || 'Failed to create auth user' }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    // The handle_new_user() trigger on auth.users already creates a base
    // users_profile row automatically — update it with the admin-supplied
    // details instead of inserting a duplicate.
    const { error: updateErr } = await adminClient.from('users_profile').update({
      full_name, whatsapp: whatsapp || null, phone: phone || null, email,
    }).eq('user_id', newUser.user.id);
    if (updateErr) {
      await adminClient.auth.admin.deleteUser(newUser.user.id);
      return new Response(JSON.stringify({ error: updateErr.message }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    // Optional starting credit balance, recorded the same way any other
    // credit grant is (an explicit wallet_transactions row, never just a
    // number stored somewhere — keeps the ledger authoritative).
    const credits = Number(initial_credits) || 0;
    if (credits > 0) {
      await adminClient.from('wallet_transactions').insert({
        user_id: newUser.user.id, type: 'credit', amount: credits,
        balance_before: 0, balance_after: credits,
        description: 'رصيد افتتاحي — تمت إضافته من لوحة التحكم',
      });
    }

    return new Response(JSON.stringify({ success: true, id: newUser.user.id }), { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } });
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 500, headers: { ...CORS, 'Content-Type': 'application/json' } });
  }
});
