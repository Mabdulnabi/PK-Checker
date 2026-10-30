// verify-binance/index.ts
// Verifies a Binance Pay payment by TXID (orderId/transactionId).

import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Credits are added by the confirm_topup() database function (single transaction).
export async function confirmTopup(params: {
  adminClient: any;
  userId: string;
  paymentId: string;
  credits: number;
  gateway: string;
  providerRef: string;
}): Promise<{ ok: boolean; alreadyProcessed?: boolean; newBalance?: number; error?: string }> {
  const { adminClient, userId, paymentId, credits, gateway, providerRef } = params;

  const { data, error } = await adminClient.rpc('confirm_topup', {
    p_user_id: userId,
    p_payment_id: paymentId,
    p_credits: credits,
    p_gateway: gateway,
    p_provider_ref: providerRef,
  });
  if (error) return { ok: false, error: `Failed to confirm top-up: ${error.message}` };
  return data;
}

const BINANCE_API_BASE = 'https://api.binance.com';

async function hmacSha256Hex(secret: string, payload: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, enc.encode(payload));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

export interface BinanceTx {
  orderId?: string;
  transactionId?: string;
  transactionTime?: number;
  createTime?: number;
  amount?: string;
  currency?: string;
  note?: string;
  remark?: string;
}

export async function fetchBinanceTransactions(apiKey: string, apiSecret: string): Promise<BinanceTx[]> {
  const timestamp = Date.now();
  const paramsStr = `timestamp=${timestamp}&limit=100`;
  const sig = await hmacSha256Hex(apiSecret, paramsStr);
  const url = `${BINANCE_API_BASE}/sapi/v1/pay/transactions?${paramsStr}&signature=${sig}`;

  try {
    const res = await fetch(url, {
      headers: { 'X-MBX-APIKEY': apiKey, 'Content-Type': 'application/json' },
      signal: AbortSignal.timeout(10000),
    });
    const data = await res.json();
    if (data && typeof data === 'object' && data.code === '000000') {
      return data.data || [];
    }
    console.warn('[Binance] API response not OK:', JSON.stringify(data));
    return [];
  } catch (e) {
    console.warn('[Binance] fetch error:', e);
    return [];
  }
}

export interface BinanceMatchResult {
  ok: boolean;
  reason?: 'tx_not_found' | 'wrong_amount';
  matchedTx?: BinanceTx;
  amountPaid?: number;
}

export function findBinanceTxById(
  transactions: BinanceTx[],
  txId: string,
  expectedAmountUsd: number
): BinanceMatchResult {
  const trimmedTxId = txId.trim();
  for (const tx of transactions) {
    const candidateId = tx.orderId || tx.transactionId || '';
    if (candidateId !== trimmedTxId) continue;

    const amountPaid = Number(tx.amount || 0);
    if (amountPaid >= expectedAmountUsd - 0.05) {
      return { ok: true, matchedTx: tx, amountPaid };
    }
    return { ok: false, reason: 'wrong_amount', matchedTx: tx, amountPaid };
  }
  return { ok: false, reason: 'tx_not_found' };
}

export async function handleVerifyBinance(
  req: Request,
  makeSupabaseClient: typeof createClient
): Promise<Response> {
  const jsonResponse = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...CORS_HEADERS } });

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return jsonResponse({ success: false, error: 'Missing Authorization header' }, 401);

    const supabaseClient = makeSupabaseClient(
      Deno.env.get('PROKEYS_SUPABASE_URL') ?? '',
      Deno.env.get('PROKEYS_ANON_KEY') ?? '',
      { global: { headers: { Authorization: authHeader } } }
    );
    const adminClient = makeSupabaseClient(
      Deno.env.get('PROKEYS_SUPABASE_URL') ?? '',
      Deno.env.get('PROKEYS_SERVICE_ROLE_KEY') ?? ''
    );

    const { data: userData, error: userError } = await supabaseClient.auth.getUser();
    if (userError || !userData?.user) return jsonResponse({ success: false, error: 'Invalid or expired session' }, 401);
    const userId = userData.user.id;

    const { payment_id, tx_id } = await req.json();
    if (!payment_id || !tx_id) return jsonResponse({ success: false, error: 'payment_id and tx_id are required' }, 400);

    const { data: payment, error: paymentError } = await supabaseClient
      .from('payments')
      .select('id, user_id, amount, credits, status')
      .eq('id', payment_id)
      .eq('user_id', userId)
      .single();

    if (paymentError || !payment) return jsonResponse({ success: false, error: 'Payment not found' }, 404);
    if (payment.status === 'completed') return jsonResponse({ success: false, error: 'Payment already completed' }, 409);

    const { data: vaultKey } = await adminClient.rpc('get_payment_api_secret', { p_name: 'BINANCE_API_KEY' });
    const { data: vaultSecret } = await adminClient.rpc('get_payment_api_secret', { p_name: 'BINANCE_API_SECRET' });
    const apiKey = vaultKey || Deno.env.get('BINANCE_API_KEY') || '';
    const apiSecret = vaultSecret || Deno.env.get('BINANCE_API_SECRET') || '';
    if (!apiKey || !apiSecret) return jsonResponse({ success: false, error: 'Server misconfiguration' }, 500);

    const transactions = await fetchBinanceTransactions(apiKey, apiSecret);
    const match = findBinanceTxById(transactions, String(tx_id), Number(payment.amount));

    if (!match.ok) {
      if (match.reason === 'wrong_amount') {
        await adminClient.from('payments').update({ failure_reason: 'wrong_amount' }).eq('id', payment_id);
      }
      return jsonResponse({ success: true, verified: false, reason: match.reason, paid: match.amountPaid });
    }

    const providerRef = match.matchedTx?.orderId || match.matchedTx?.transactionId || '';
    const confirmResult = await confirmTopup({
      adminClient,
      userId,
      paymentId: payment_id,
      credits: payment.credits ?? 0,
      gateway: 'binance',
      providerRef,
    });

    if (!confirmResult.ok) {
      return jsonResponse({ success: false, error: confirmResult.error, alreadyProcessed: confirmResult.alreadyProcessed });
    }

    return jsonResponse({ success: true, verified: true, newBalance: confirmResult.newBalance });
  } catch (err) {
    return jsonResponse({ success: false, error: err instanceof Error ? err.message : 'Unknown error' }, 500);
  }
}

Deno.serve((req) => handleVerifyBinance(req, createClient));
