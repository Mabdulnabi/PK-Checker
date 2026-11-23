// paypal-capture-order/index.ts
// Captures the PayPal order the customer approved and, if PayPal confirms the money was taken,
// completes the payment through confirm_topup() (slots, store wallet or store order), like the
// other gateways. Checked before crediting: the order belongs to this payment (custom_id and
// payments.order_id), it is in USD, and the captured amount is at least the price + PayPal's fee.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const PAYPAL_API = 'https://api-m.paypal.com';
const PAYPAL_CLIENT_ID = Deno.env.get('PAYPAL_CLIENT_ID')
  ?? 'BAA48o-YrMao9vqRoOOdS9QYumXeaFpn8PIINSdA9JmdU68VlwmvsekLiE5aVwOtx9v3nouwKmZAb4GXoA';

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } });
// Must match paypal-create-order.
const withPaypalFee = (usd: number) => Math.ceil(((usd + 0.5) / 0.96) * 100) / 100;

async function paypalToken(): Promise<string> {
  const secret = Deno.env.get('PAYPAL_SECRET');
  if (!secret) throw new Error('PAYPAL_SECRET is not set');
  const res = await fetch(`${PAYPAL_API}/v1/oauth2/token`, {
    method: 'POST',
    headers: { Authorization: 'Basic ' + btoa(`${PAYPAL_CLIENT_ID}:${secret}`), 'Content-Type': 'application/x-www-form-urlencoded' },
    body: 'grant_type=client_credentials',
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok || !data.access_token) throw new Error(`PayPal auth failed (${res.status})`);
  return data.access_token;
}

// Reconcile: asks PayPal for the real state of every pending PayPal payment (last 30 days).
// Internal secret only (the database scheduler). mode 'report' changes nothing; mode 'apply' credits
// only orders PayPal reports as COMPLETED with a COMPLETED capture of the right USD amount.
async function reconcile(admin: ReturnType<typeof createClient>, apply: boolean) {
  const since = new Date(Date.now() - 30 * 86400000).toISOString();
  const { data: rows } = await admin.from('payments')
    .select('id, user_id, amount, credits, order_id, failure_reason, created_at')
    .eq('gateway', 'paypal').eq('status', 'pending').not('order_id', 'is', null).gte('created_at', since)
    .order('created_at', { ascending: false }).limit(50);
  const token = await paypalToken();
  const out: unknown[] = [];
  for (const p of rows ?? []) {
    const res = await fetch(`${PAYPAL_API}/v2/checkout/orders/${encodeURIComponent(p.order_id)}`, { headers: { Authorization: `Bearer ${token}` } });
    const o = await res.json().catch(() => ({}));
    const unit = o?.purchase_units?.[0];
    const cap = unit?.payments?.captures?.[0];
    const row: Record<string, unknown> = {
      payment: p.id, created: p.created_at, order: p.order_id, http: res.status,
      order_status: o?.status ?? o?.name, capture_status: cap?.status ?? null,
      capture_reason: cap?.status_details?.reason ?? null, captured: cap?.amount?.value ?? null,
      currency: cap?.amount?.currency_code ?? null, expected: withPaypalFee(Number(p.amount)),
      payer_country: o?.payer?.address?.country_code ?? null, our_reason: p.failure_reason,
    };
    const ok = o?.status === 'COMPLETED' && cap?.status === 'COMPLETED' && cap?.amount?.currency_code === 'USD'
      && Number(cap?.amount?.value) >= withPaypalFee(Number(p.amount)) - 0.005 && (!unit?.custom_id || unit.custom_id === p.id);
    row.creditable = ok;
    if (apply && ok) {
      const { data: done, error } = await admin.rpc('confirm_topup', {
        p_user_id: p.user_id, p_payment_id: p.id, p_credits: p.credits ?? 0, p_gateway: 'paypal', p_provider_ref: cap.id,
      });
      row.applied = error ? `error: ${error.message}` : (done?.ok ? 'credited' : (done?.error || 'not credited'));
    } else if (apply && !ok && cap?.status) {
      await admin.from('payments').update({ failure_reason: `paypal:${cap.status}${cap?.status_details?.reason ? ':' + cap.status_details.reason : ''}`.slice(0, 200) }).eq('id', p.id);
    }
    out.push(row);
  }
  return out;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const secretHeader = req.headers.get('x-internal-secret');
    if (secretHeader) {
      const url0 = Deno.env.get('SUPABASE_URL') ?? '';
      const admin0 = createClient(url0, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
      const { data: expected } = await admin0.rpc('get_internal_cron_secret');
      if (!expected || secretHeader !== expected) return json({ success: false, error: 'Forbidden' }, 403);
      const body = await req.json().catch(() => ({}));
      if (body.action !== 'reconcile') return json({ success: false, error: 'Unknown action' }, 400);
      return json({ success: true, results: await reconcile(admin0, body.mode === 'apply') });
    }
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ success: false, error: 'Missing Authorization header' }, 401);
    const url = Deno.env.get('SUPABASE_URL') ?? '';
    const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', { global: { headers: { Authorization: authHeader } } });
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
    const { data: userData, error: userErr } = await userClient.auth.getUser();
    if (userErr || !userData?.user) return json({ success: false, error: 'Invalid or expired session' }, 401);
    const userId = userData.user.id;

    const { payment_id, order_id } = await req.json().catch(() => ({}));
    if (!payment_id || !order_id) return json({ success: false, error: 'payment_id and order_id are required' }, 400);

    const { data: pay } = await admin.from('payments')
      .select('id, user_id, amount, currency, credits, status, gateway, order_id')
      .eq('id', payment_id).eq('user_id', userId).maybeSingle();
    if (!pay) return json({ success: false, error: 'Payment not found' }, 404);
    if (pay.gateway !== 'paypal' || pay.order_id !== order_id) return json({ success: false, error: 'This PayPal order does not belong to the payment' }, 400);
    if (pay.status === 'completed') return json({ success: true, verified: true, alreadyProcessed: true });
    if (pay.status !== 'pending') return json({ success: false, error: 'Payment is not pending' }, 409);

    const token = await paypalToken();
    // Capture. The request id makes a retried capture return the same result instead of charging twice.
    let res = await fetch(`${PAYPAL_API}/v2/checkout/orders/${encodeURIComponent(order_id)}/capture`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'PayPal-Request-Id': `capture-${payment_id}`, Prefer: 'return=representation' },
    });
    let order = await res.json().catch(() => ({}));
    if (!res.ok && order?.details?.[0]?.issue === 'ORDER_ALREADY_CAPTURED') {
      res = await fetch(`${PAYPAL_API}/v2/checkout/orders/${encodeURIComponent(order_id)}`, { headers: { Authorization: `Bearer ${token}` } });
      order = await res.json().catch(() => ({}));
    }
    if (!res.ok) {
      const issue = order?.details?.[0]?.issue || order?.name || `HTTP ${res.status}`;
      console.error('paypal-capture-order: PayPal error', issue, JSON.stringify(order).slice(0, 400));
      // The buyer's card or PayPal balance was refused: they can pick another funding source and retry.
      if (issue === 'INSTRUMENT_DECLINED') {
        await admin.from('payments').update({ failure_reason: 'paypal:INSTRUMENT_DECLINED' }).eq('id', payment_id);
        return json({ success: true, verified: false, reason: 'declined', retry: true });
      }
      await admin.from('payments').update({ failure_reason: `paypal:${issue}`.slice(0, 200) }).eq('id', payment_id);
      return json({ success: true, verified: false, reason: issue });
    }

    const unit = order?.purchase_units?.[0];
    const capture = unit?.payments?.captures?.[0];
    if (order.status !== 'COMPLETED' || !capture || capture.status !== 'COMPLETED') {
      // PENDING captures (e.g. under review at PayPal) are not credited yet.
      await admin.from('payments').update({ failure_reason: `paypal:${capture?.status || order.status}`.slice(0, 200) }).eq('id', payment_id);
      return json({ success: true, verified: false, reason: (capture?.status || order.status || 'not_completed').toLowerCase() });
    }
    const paid = Number(capture.amount?.value);
    const expected = withPaypalFee(Number(pay.amount));
    if ((unit.custom_id && unit.custom_id !== payment_id) || capture.amount?.currency_code !== 'USD' || !(paid >= expected - 0.005)) {
      await admin.from('payments').update({ failure_reason: `paypal:mismatch:paid=${paid}:${capture.amount?.currency_code}:expected=${expected}` }).eq('id', payment_id);
      return json({ success: true, verified: false, reason: 'wrong_amount', paid, expected });
    }

    const { data: done, error } = await admin.rpc('confirm_topup', {
      p_user_id: userId, p_payment_id: payment_id, p_credits: pay.credits ?? 0, p_gateway: 'paypal', p_provider_ref: capture.id,
    });
    if (error) return json({ success: false, error: `Failed to confirm the payment: ${error.message}` }, 500);
    if (!done?.ok) return json({ success: !!done?.alreadyProcessed, verified: !!done?.alreadyProcessed, error: done?.error, alreadyProcessed: done?.alreadyProcessed });
    return json({ success: true, verified: true, storeError: done.storeError ?? null });
  } catch (e) {
    console.error('paypal-capture-order failed', e);
    return json({ success: false, error: e instanceof Error ? e.message : 'Unknown error' }, 500);
  }
});
