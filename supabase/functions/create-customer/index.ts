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
    // Only email and password are required; the name and phone numbers are optional.
    if (!email || !password) {
      return new Response(JSON.stringify({ error: 'الإيميل والباسورد مطلوبين' }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }
    // Same rule as the project's Auth password policy: 8+ characters with a lowercase letter,
    // an uppercase letter, a digit and a symbol.
    if (password.length < 8 || !/[a-z]/.test(password) || !/[A-Z]/.test(password) || !/[0-9]/.test(password) || !/[^A-Za-z0-9]/.test(password)) {
      return new Response(JSON.stringify({ error: 'الباسورد لازم يكون 8 حروف على الأقل وفيه حرف إنجليزي صغير وحرف كبير ورقم ورمز (مثل ! @ #)' }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    const adminClient = createClient(supabaseUrl, serviceKey);

    const { data: newUser, error: createErr } = await adminClient.auth.admin.createUser({
      email, password, email_confirm: true,
    });
    if (createErr || !newUser?.user) {
      const msg = createErr?.message || 'Failed to create auth user';
      const friendly = /already (been )?registered|already exists/i.test(msg) ? 'الإيميل ده متسجل قبل كده'
        : /password/i.test(msg) ? 'الباسورد ضعيف: لازم 8 حروف على الأقل وفيه حرف صغير وحرف كبير ورقم ورمز'
        : msg;
      return new Response(JSON.stringify({ error: friendly }), { status: 400, headers: { ...CORS, 'Content-Type': 'application/json' } });
    }

    // The handle_new_user() trigger on auth.users already creates a base
    // users_profile row automatically — update it with the admin-supplied
    // details instead of inserting a duplicate.
    const profile: Record<string, unknown> = { whatsapp: whatsapp || null, phone: phone || null, email };
    if (full_name && String(full_name).trim()) profile.full_name = String(full_name).trim();
    const { error: updateErr } = await adminClient.from('users_profile').update(profile).eq('user_id', newUser.user.id);
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
