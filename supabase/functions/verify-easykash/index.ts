// verify-easykash/index.ts
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

async function confirmTopup(params: {
  adminClient: any;
  userId: string;
  paymentId: string;
  credits: number;
  gateway: string;
  providerRef: string;
}): Promise<{ ok: boolean; alreadyProcessed?: boolean; newBalance?: number; error?: string }> {
  const { adminClient, userId, paymentId, credits, gateway, providerRef } = params;

  const { error: refError } = await adminClient
    .from('processed_payment_refs')
    .insert({ gateway, provider_ref: providerRef, payment_id: paymentId });

  if (refError) {
    if (refError.code === '23505') {
      return { ok: false, alreadyProcessed: true, error: 'This transaction was already processed' };
    }
    return { ok: false, error: `Failed to record provider reference: ${refError.message}` };
  }

  const { data: latestTxn, error: balanceError } = await adminClient
    .from('wallet_transactions')
    .select('balance_after')
    .eq('user_id', userId)
    .order('created_at', { ascending: false })
    .limit(1);

  if (balanceError) return { ok: false, error: `Failed to read current balance: ${balanceError.message}` };

  const balanceBefore = latestTxn && latestTxn.length > 0 ? Number(latestTxn[0].balance_after) : 0;
  const balanceAfter = balanceBefore + credits;

  const { error: insertError } = await adminClient
    .from('wallet_transactions')
    .insert({ user_id: userId, type: 'credit', amount: credits, balance_before: balanceBefore, balance_after: balanceAfter, description: `شحن رصيد — ${gateway}` });

  if (insertError) return { ok: false, error: `Failed to credit wallet: ${insertError.message}` };

  const { error: updateError } = await adminClient
    .from('payments')
    .update({ status: 'completed', verified_at: new Date().toISOString(), transaction_id: providerRef })
    .eq('id', paymentId);

  if (updateError) console.error('confirmTopup: wallet credited but payments row update failed:', updateError.message);

  return { ok: true, newBalance: balanceAfter };
}

interface EasykashInquiryResult {
  status?: string;
  Amount?: string | number;
  easykashRef?: string;
}

async function inquireEasykash(customerReference: string): Promise<EasykashInquiryResult | null> {
  const apiKey = Deno.env.get('EASYKASH_API_KEY') ?? '';
  try {
    const res = await fetch('https://back.easykash.net/api/cash-api/inquire', {
      method: 'POST',
      headers: { authorization: apiKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ customerReference }),
    });
    if (!res.ok) { console.warn('[EasyKash] inquiry HTTP error:', res.status, await res.text()); return null; }
    return await res.json();
  } catch (e) { console.warn('[EasyKash] inquiry fetch error:', e); return null; }
}

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
    const adminClient = createClient(
      Deno.env.get('PROKEYS_SUPABASE_URL') ?? '',
      Deno.env.get('PROKEYS_SERVICE_ROLE_KEY') ?? ''
    );

    const { data: userData, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !userData?.user) return jsonResponse({ success: false, error: 'Invalid or expired session' }, 401);
    const userId = userData.user.id;

    const { payment_id } = await req.json();
    if (!payment_id) return jsonResponse({ success: false, error: 'payment_id is required' }, 400);

    const { data: payment, error: paymentError } = await supabaseClient
      .from('payments')
      .select('id, user_id, amount, currency, credits, status, gateway')
      .eq('id', payment_id)
      .eq('user_id', userId)
      .single();

    if (paymentError || !payment) return jsonResponse({ success: false, error: 'Payment not found' }, 404);
    if (payment.status === 'completed') return jsonResponse({ success: false, error: 'Payment already completed' }, 409);

    const result = await inquireEasykash(payment_id);
    if (!result) return jsonResponse({ success: true, verified: false, reason: 'inquiry_failed' });
    if (result.status !== 'PAID' && result.status !== 'DELIVERED') {
      return jsonResponse({ success: true, verified: false, reason: result.status || 'not_found' });
    }

    // Cash channels (Fawry/Aman) round UP to voucher denominations, so buyers
    // often pay slightly MORE than expected. Only reject underpayment.
    const expectedEgp = Number(payment.amount);
    const paidEgp = Number(result.Amount ?? 0);
    const underpayTolerance = 1.0;
    if (Number.isNaN(paidEgp) || paidEgp < expectedEgp - underpayTolerance) {
      await adminClient.from('payments').update({ failure_reason: `wrong_amount:paid=${paidEgp}:expected=${expectedEgp}` }).eq('id', payment_id);
      return jsonResponse({ success: true, verified: false, reason: 'wrong_amount', paid: paidEgp, expected: expectedEgp });
    }

    const providerRef = result.easykashRef || payment_id;
    const confirmResult = await confirmTopup({ adminClient, userId, paymentId: payment_id, credits: payment.credits ?? 0, gateway: payment.gateway, providerRef });

    if (!confirmResult.ok) return jsonResponse({ success: false, error: confirmResult.error, alreadyProcessed: confirmResult.alreadyProcessed });

    return jsonResponse({ success: true, verified: true, newBalance: confirmResult.newBalance });
  } catch (err) {
    return jsonResponse({ success: false, error: err instanceof Error ? err.message : 'Unknown error' }, 500);
  }
});
