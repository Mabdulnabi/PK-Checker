// verify-sms/index.ts
// Checks InstaPay / Vodafone Cash reference numbers against the Google Sheet
// the phone shortcut writes to. The Sheet row is only marked as used AFTER the
// credit is written, so a failed credit never burns a valid reference.

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

const SHEET_ID = '1OlThxZmk0g3F2-g3sV6f20QrIuGoInF8GgoaLakGnrQ';
const SHEET_NAME = 'Sheet1';

async function getGoogleAccessToken(): Promise<string> {
  const credsJson = Deno.env.get('GOOGLE_SERVICE_ACCOUNT_JSON') ?? '{}';
  const creds = JSON.parse(credsJson);

  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const claimSet = {
    iss: creds.client_email,
    scope: 'https://www.googleapis.com/auth/spreadsheets',
    aud: 'https://oauth2.googleapis.com/token',
    exp: now + 3600,
    iat: now,
  };

  const b64url = (obj: unknown) =>
    btoa(JSON.stringify(obj)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  const unsigned = `${b64url(header)}.${b64url(claimSet)}`;

  const pemBody = (creds.private_key as string)
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s/g, '');
  const binaryKey = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    'pkcs8', binaryKey, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']
  );
  const sigBuffer = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned));
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sigBuffer))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  const jwt = `${unsigned}.${sigB64}`;

  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion: jwt }),
  });
  const data = await res.json();
  if (!data.access_token) throw new Error('Failed to obtain Google access token: ' + JSON.stringify(data));
  return data.access_token;
}

async function getAllRows(): Promise<string[][]> {
  try {
    const token = await getGoogleAccessToken();
    const res = await fetch(
      `https://sheets.googleapis.com/v4/spreadsheets/${SHEET_ID}/values/${SHEET_NAME}!A:E`,
      { headers: { Authorization: `Bearer ${token}` } }
    );
    const data = await res.json();
    return data.values || [];
  } catch (e) {
    console.warn('[SMS] Sheet read error:', e);
    return [];
  }
}

async function markUsed(rowIndex: number): Promise<void> {
  try {
    const token = await getGoogleAccessToken();
    await fetch(
      `https://sheets.googleapis.com/v4/spreadsheets/${SHEET_ID}/values/${SHEET_NAME}!E${rowIndex}?valueInputOption=RAW`,
      {
        method: 'PUT',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ values: [['TRUE']] }),
      }
    );
  } catch (e) {
    console.warn('[SMS] mark used error:', e);
  }
}

export interface SmsVerifyResult {
  ok: boolean;
  reason?: 'not_found' | 'already_used' | 'wrong_amount' | 'sheet_unavailable';
  amount?: number;
  source?: string;
  timestamp?: string;
  row?: number;
  paid?: number;
}

// Normalizes a reference number: strips whitespace, a leading apostrophe
// (Sheets' text-cell prefix), RTL/LTR marks, and leading zeros.
function normalizeRef(r: string): string {
  let s = String(r).trim();
  if (s.startsWith("'")) s = s.slice(1);
  s = s.replace(/^[‏‎‪‫]+/, '').trim();
  s = s.replace(/^0+/, '');
  return s || '0';
}

export function matchSmsPayment(
  rows: string[][],
  refNumber: string,
  expectedAmountEgp: number,
  tolerance = 1.0
): SmsVerifyResult {
  const inputRef = String(refNumber).trim();
  const normInput = normalizeRef(inputRef);

  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    if (i === 0 && row.length && ['ref_number', 'ref', 'رقم'].includes(String(row[0]).toLowerCase())) continue;
    if (row.length < 2) continue;

    let sheetRef = String(row[0]).trim();
    if (sheetRef.startsWith("'")) sheetRef = sheetRef.slice(1);
    sheetRef = sheetRef.replace(/^[‏‎‪‫]+/, '').trim();
    const normSheet = normalizeRef(sheetRef);

    if (sheetRef !== inputRef && normSheet !== normInput) continue;

    const used = row.length > 4 ? String(row[4]).trim().toUpperCase() : '';
    if (used === 'TRUE') return { ok: false, reason: 'already_used' };

    let sheetAmount = 0;
    try {
      sheetAmount = parseFloat(String(row[1]).replace(/,/g, '').trim());
      if (Number.isNaN(sheetAmount)) sheetAmount = 0;
    } catch {
      sheetAmount = 0;
    }

    if (Math.abs(sheetAmount - expectedAmountEgp) <= tolerance) {
      const source = row.length > 2 ? String(row[2]).trim() : 'unknown';
      const timestamp = row.length > 3 ? String(row[3]).trim() : '';
      return { ok: true, amount: sheetAmount, source, timestamp, row: i + 1 };
    }
    return { ok: false, reason: 'wrong_amount', paid: sheetAmount };
  }

  return { ok: false, reason: 'not_found' };
}

export async function handleVerifySms(req: Request, makeSupabaseClient: typeof createClient): Promise<Response> {
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

    const { payment_id, ref_number } = await req.json();
    if (!payment_id || !ref_number) return jsonResponse({ success: false, error: 'payment_id and ref_number are required' }, 400);

    const { data: payment, error: paymentError } = await supabaseClient
      .from('payments')
      .select('id, user_id, amount, currency, credits, status, gateway')
      .eq('id', payment_id)
      .eq('user_id', userId)
      .single();

    if (paymentError || !payment) return jsonResponse({ success: false, error: 'Payment not found' }, 404);
    if (payment.status === 'completed') return jsonResponse({ success: false, error: 'Payment already completed' }, 409);

    // payments.amount is EGP for instapay / vodafone_cash.
    const expectedEgp = Number(payment.amount);

    const rows = await getAllRows();
    if (rows.length === 0) {
      return jsonResponse({ success: true, verified: false, reason: 'sheet_unavailable' });
    }

    const result = matchSmsPayment(rows, ref_number, expectedEgp);

    if (!result.ok) {
      if (result.reason === 'wrong_amount') {
        await adminClient.from('payments').update({ failure_reason: 'wrong_amount' }).eq('id', payment_id);
      }
      return jsonResponse({ success: true, verified: false, reason: result.reason, paid: result.paid });
    }

    const confirmResult = await confirmTopup({
      adminClient,
      userId,
      paymentId: payment_id,
      credits: payment.credits ?? 0,
      gateway: payment.gateway, // 'instapay' or 'vodafone_cash'
      providerRef: `sheet-row-${result.row}-${ref_number}`,
    });

    if (!confirmResult.ok) {
      return jsonResponse({ success: false, error: confirmResult.error, alreadyProcessed: confirmResult.alreadyProcessed });
    }

    // Only now is the Sheet row burned.
    await markUsed(result.row!);

    return jsonResponse({ success: true, verified: true, newBalance: confirmResult.newBalance });
  } catch (err) {
    return jsonResponse({ success: false, error: err instanceof Error ? err.message : 'Unknown error' }, 500);
  }
}

Deno.serve((req) => handleVerifySms(req, createClient));
