// verify-bep20/index.ts
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

const USDT_BEP20_CONTRACT = '0x55d398326f99059fF775485246999027B3197955';
const ETHERSCAN_API = 'https://api.etherscan.io/v2/api';
const TRANSFER_TOPIC = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';

export interface Bep20VerifyResult {
  ok: boolean;
  reason?: 'tx_not_found' | 'tx_failed' | 'wrong_contract' | 'no_transfer_log' | 'wrong_amount' | 'network_error';
  amount?: number;
  paid?: number;
}

export async function verifyBep20Tx(
  txHash: string,
  expectedAddress: string,
  expectedAmountUsdt: number,
  apiKey: string
): Promise<Bep20VerifyResult> {
  let hash = txHash.trim();
  if (!hash.startsWith('0x')) hash = '0x' + hash;

  const params = new URLSearchParams({
    chainid: '56',
    module: 'proxy',
    action: 'eth_getTransactionReceipt',
    txhash: hash,
    apikey: apiKey,
  });

  let data: any;
  try {
    const res = await fetch(`${ETHERSCAN_API}?${params.toString()}`, { signal: AbortSignal.timeout(10000) });
    data = await res.json();
  } catch (_e) {
    return { ok: false, reason: 'network_error' };
  }

  const result = data?.result;
  if (!result || result === 'null') {
    return { ok: false, reason: 'tx_not_found' };
  }

  if (result.status !== '0x1') {
    return { ok: false, reason: 'tx_failed' };
  }

  const toAddr = (result.to || '').toLowerCase();
  if (toAddr !== USDT_BEP20_CONTRACT.toLowerCase()) {
    return { ok: false, reason: 'wrong_contract' };
  }

  const logs = result.logs || [];
  for (const log of logs) {
    const topics = log.topics || [];
    if (!topics.length || topics[0].toLowerCase() !== TRANSFER_TOPIC.toLowerCase()) continue;
    if (topics.length < 3) continue;

    const recipient = '0x' + topics[2].slice(-40);
    if (recipient.toLowerCase() !== expectedAddress.toLowerCase()) continue;

    const dataHex = log.data || '0x';
    let amountUsdt: number;
    try {
      const raw = BigInt(dataHex);
      amountUsdt = Number(raw) / 10 ** 18;
    } catch {
      continue;
    }

    if (amountUsdt >= expectedAmountUsdt - 0.05) {
      return { ok: true, amount: amountUsdt };
    } else {
      return { ok: false, reason: 'wrong_amount', paid: amountUsdt };
    }
  }

  return { ok: false, reason: 'no_transfer_log' };
}

export async function handleVerifyBep20(
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

    const { payment_id, tx_hash } = await req.json();
    if (!payment_id || !tx_hash) return jsonResponse({ success: false, error: 'payment_id and tx_hash are required' }, 400);

    const { data: payment, error: paymentError } = await supabaseClient
      .from('payments')
      .select('id, user_id, amount, credits, status')
      .eq('id', payment_id)
      .eq('user_id', userId)
      .single();

    if (paymentError || !payment) return jsonResponse({ success: false, error: 'Payment not found' }, 404);
    if (payment.status === 'completed') return jsonResponse({ success: false, error: 'Payment already completed' }, 409);

    const { data: vaultAddress } = await adminClient.rpc('get_payment_api_secret', { p_name: 'BEP20_ADDRESS' });
    const { data: vaultKey } = await adminClient.rpc('get_payment_api_secret', { p_name: 'BEP20_API_KEY' });
    const bep20Address = vaultAddress || Deno.env.get('BEP20_ADDRESS') || '';
    const etherscanKey = vaultKey || Deno.env.get('BEP20_API_KEY') || '';
    if (!bep20Address || !etherscanKey) return jsonResponse({ success: false, error: 'Server misconfiguration' }, 500);

    const result = await verifyBep20Tx(tx_hash, bep20Address, Number(payment.amount), etherscanKey);

    if (!result.ok) {
      await adminClient.from('payments').update({ failure_reason: result.reason }).eq('id', payment_id);
      return jsonResponse({ success: true, verified: false, reason: result.reason, paid: result.paid });
    }

    const confirmResult = await confirmTopup({
      adminClient,
      userId,
      paymentId: payment_id,
      credits: payment.credits ?? 0,
      gateway: 'bep20',
      providerRef: tx_hash,
    });

    if (!confirmResult.ok) {
      return jsonResponse({ success: false, error: confirmResult.error, alreadyProcessed: confirmResult.alreadyProcessed });
    }

    return jsonResponse({ success: true, verified: true, newBalance: confirmResult.newBalance });
  } catch (err) {
    return jsonResponse({ success: false, error: err instanceof Error ? err.message : 'Unknown error' }, 500);
  }
}

Deno.serve((req) => handleVerifyBep20(req, createClient));
