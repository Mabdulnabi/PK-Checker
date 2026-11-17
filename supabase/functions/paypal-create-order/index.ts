// paypal-create-order/index.ts
// Creates a PayPal order for one of the caller's pending payments (gateway "paypal").
// The price is worked out here, never taken from the browser:
//   - check package: its price_egp, in USD at 50 EGP = 1 USD (same rounding as the site)
//   - store order (pack_id "store-order:<id>"): the order total
//   - store wallet top-up (pack_id "store-topup"): the amount the customer chose (1 to 1000 USD)
// PayPal's fee (4% + 0.50 USD) is added on top so the full price reaches us:
//   charged = (price + 0.50) / 0.96, rounded up to the cent.
// payments.amount keeps the price without the fee (what is credited and reported);
// payments.order_id keeps the PayPal order id for the capture step.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const PAYPAL_API = 'https://api-m.paypal.com';
const PAYPAL_CLIENT_ID = Deno.env.get('PAYPAL_CLIENT_ID')
  ?? 'BAA48o-YrMao9vqRoOOdS9QYumXeaFpn8PIINSdA9JmdU68VlwmvsekLiE5aVwOtx9v3nouwKmZAb4GXoA';
const EGP_PER_USD = 50;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS } });

// Same rounding as packChargeAmount() on the site: up to the next 0.10 USD.
const usdFromEgp = (egp: number) => Math.ceil((egp / EGP_PER_USD) * 10) / 10;
// Price with PayPal's fee added, rounded up to the cent.
export const withPaypalFee = (usd: number) => Math.ceil(((usd + 0.5) / 0.96) * 100) / 100;

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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  try {
    const body = await req.json().catch(() => ({}));
    // Health check: can we sign in to PayPal with PAYPAL_CLIENT_ID + PAYPAL_SECRET? Answers ok/not ok only.
    if (body?.ping === true) {
      try { await paypalToken(); return json({ ok: true }); }
      catch (e) { return json({ ok: false, error: e instanceof Error ? e.message : 'PayPal sign-in failed' }); }
    }
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ success: false, error: 'Missing Authorization header' }, 401);
    const url = Deno.env.get('SUPABASE_URL') ?? '';
    const userClient = createClient(url, Deno.env.get('SUPABASE_ANON_KEY') ?? '', { global: { headers: { Authorization: authHeader } } });
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
    const { data: userData, error: userErr } = await userClient.auth.getUser();
    if (userErr || !userData?.user) return json({ success: false, error: 'Invalid or expired session' }, 401);
    const userId = userData.user.id;

    const { payment_id } = body;
    if (!payment_id) return json({ success: false, error: 'payment_id is required' }, 400);

    const { data: pay } = await admin.from('payments')
      .select('id, user_id, amount, currency, status, gateway, pack_id, order_id')
      .eq('id', payment_id).eq('user_id', userId).maybeSingle();
    if (!pay) return json({ success: false, error: 'Payment not found' }, 404);
    if (pay.gateway !== 'paypal') return json({ success: false, error: 'Not a PayPal payment' }, 400);
    if (pay.status !== 'pending') return json({ success: false, error: 'Payment is not pending' }, 409);

    // The price, without PayPal's fee, from the thing being bought.
    const packId = String(pay.pack_id || '');
    let usd: number;
    let description: string;
    if (packId === 'store-topup') {
      usd = Number(pay.amount);
      if (!(usd >= 1 && usd <= 1000) || String(pay.currency).toUpperCase() !== 'USD') return json({ success: false, error: 'Invalid top-up amount' }, 400);
      description = 'Store wallet top-up';
    } else if (packId.startsWith('store-order:')) {
      const orderId = packId.slice(12);
      const { data: order } = await admin.from('store_orders').select('id, price_egp, status, product_name, plan_name')
        .eq('id', orderId).eq('user_id', userId).maybeSingle();
      if (!order || order.status !== 'pending_payment') return json({ success: false, error: 'Order is not waiting for payment' }, 409);
      usd = usdFromEgp(Number(order.price_egp));
      description = `${order.product_name} - ${order.plan_name}`.slice(0, 120);
    } else {
      // pack_id comes from the browser: only plain ids are looked up (never put into a filter string).
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(packId)) return json({ success: false, error: 'Package not available' }, 400);
      const cols = 'id, price_egp, name_en, slots, is_active';
      let { data: pkg } = await admin.from('slot_packages').select(cols).eq('legacy_pack_id', packId).limit(1).maybeSingle();
      if (!pkg && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(packId)) {
        ({ data: pkg } = await admin.from('slot_packages').select(cols).eq('id', packId).limit(1).maybeSingle());
      }
      if (!pkg || !pkg.is_active) return json({ success: false, error: 'Package not available' }, 400);
      usd = usdFromEgp(Number(pkg.price_egp));
      description = `${pkg.name_en || 'Check package'} (${pkg.slots} checks)`.slice(0, 120);
    }
    if (!(usd > 0)) return json({ success: false, error: 'Invalid price' }, 400);
    const charged = withPaypalFee(usd);

    const token = await paypalToken();
    const res = await fetch(`${PAYPAL_API}/v2/checkout/orders`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', 'PayPal-Request-Id': `create-${payment_id}` },
      body: JSON.stringify({
        intent: 'CAPTURE',
        purchase_units: [{
          reference_id: payment_id,
          custom_id: payment_id,
          invoice_id: payment_id,
          description,
          amount: { currency_code: 'USD', value: charged.toFixed(2) },
        }],
        application_context: { brand_name: 'PK Checker', shipping_preference: 'NO_SHIPPING', user_action: 'PAY_NOW' },
      }),
    });
    const order = await res.json().catch(() => ({}));
    if (!res.ok || !order.id) {
      console.error('paypal-create-order: PayPal error', res.status, JSON.stringify(order).slice(0, 400));
      return json({ success: false, error: 'Could not start the PayPal payment' }, 502);
    }

    // The price without the fee is what gets credited; the PayPal order id is checked at capture.
    const { error: upErr } = await admin.from('payments')
      .update({ amount: usd, currency: 'USD', order_id: order.id }).eq('id', payment_id);
    if (upErr) return json({ success: false, error: 'Could not save the PayPal order' }, 500);

    return json({ success: true, orderID: order.id, amount: charged.toFixed(2) });
  } catch (e) {
    console.error('paypal-create-order failed', e);
    return json({ success: false, error: e instanceof Error ? e.message : 'Unknown error' }, 500);
  }
});
