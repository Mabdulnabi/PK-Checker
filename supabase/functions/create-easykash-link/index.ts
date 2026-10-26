// create-easykash-link/index.ts
// Creates a per-order EasyKash Direct Pay link via the directpayv1/pay API,
// using our own payment row id as customerReference so the later
// Payment Inquiry call in verify-easykash can find it deterministically.

import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return jsonResponse({ success: false, error: 'Missing Authorization header' }, 401);

    const supabaseClient = createClient(
      Deno.env.get('PROKEYS_SUPABASE_URL') ?? '',
      Deno.env.get('PROKEYS_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: userData, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !userData?.user) return jsonResponse({ success: false, error: 'Invalid or expired session' }, 401);
    const userId = userData.user.id;

    const { payment_id } = await req.json();
    if (!payment_id) return jsonResponse({ success: false, error: 'payment_id is required' }, 400);

    const { data: payment, error: paymentError } = await supabaseClient
      .from('payments')
      .select('id, user_id, amount, currency, status, gateway')
      .eq('id', payment_id)
      .eq('user_id', userId)
      .single();
    if (paymentError || !payment) return jsonResponse({ success: false, error: 'Payment not found' }, 404);
    if (payment.gateway !== 'easykash') return jsonResponse({ success: false, error: 'Wrong gateway for this payment' }, 400);
    if (payment.status === 'completed') return jsonResponse({ success: false, error: 'Payment already completed' }, 409);

    const { data: profile } = await supabaseClient
      .from('users_profile')
      .select('email, phone, full_name')
      .eq('id', userId)
      .maybeSingle();

    const apiKey = Deno.env.get('EASYKASH_API_KEY') ?? '';

    // Marker so the returning tab knows to just close itself instead of
    // reloading the full dashboard (the ORIGINAL tab is the one polling
    // for confirmation, this redirected tab has no job to do).
    const baseAppUrl = Deno.env.get('PROKEYS_APP_URL') || 'https://prokeys.vercel.app/dashboard.html';
    const redirectUrl = baseAppUrl + (baseAppUrl.includes('?') ? '&' : '?') + 'easykash_return=1';

    const payload = {
      amount: Number(payment.amount),
      currency: 'EGP',
      paymentOptions: [2, 4, 6],
      cashExpiry: 3,
      name: profile?.full_name || 'Pro Keys Customer',
      email: profile?.email || userData.user.email || 'customer@prokeys.com',
      mobile: profile?.phone || '01000000000',
      redirectUrl,
      customerReference: payment.id,
    };

    const ekRes = await fetch('https://back.easykash.net/api/directpayv1/pay', {
      method: 'POST',
      headers: { authorization: apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });

    if (!ekRes.ok) {
      const errText = await ekRes.text();
      console.error('[EasyKash] create link HTTP error:', ekRes.status, errText);
      return jsonResponse({ success: false, error: 'EasyKash API error' }, 502);
    }

    const data = await ekRes.json();
    const payUrl = data.redirectUrl || data.paymentUrl || data.url;
    if (!payUrl) {
      console.error('[EasyKash] no URL in response:', data);
      return jsonResponse({ success: false, error: 'EasyKash did not return a payment URL' }, 502);
    }

    return jsonResponse({ success: true, payUrl });
  } catch (err) {
    return jsonResponse({ success: false, error: err instanceof Error ? err.message : 'Unknown error' }, 500);
  }
});
