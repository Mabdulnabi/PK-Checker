import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;
const TURNISCAN_BASE = "https://turniscan.com/v1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Order of operations, so a slot is never spent on a check that doesn't run:
//   1. the order must belong to the caller and not be submitted yet
//   2. the provider must be available for this check type (otherwise: MAINTENANCE, nothing spent)
//   3. reserve one slot of the matching type, keyed by the order id (retries never reserve twice)
//   4. send the file to TurniScan; if TurniScan refuses, release the slot
//   5. store the provider file id on the order
// Check types map to slot types: sim_only -> plag_only, sim_ai -> plag_ai.

type ServiceKey = "plag_ai" | "plag_only";

async function providerAvailability(
  admin: ReturnType<typeof createClient>,
  service: ServiceKey,
): Promise<{ available: boolean; reason: string; message_ar: string | null; message_en: string | null }> {
  const { data: rowsData } = await admin
    .from("service_availability")
    .select("service, enabled, min_provider_credits, message_ar, message_en")
    .in("service", ["master", "capacity", service]);
  const byKey: Record<string, { enabled: boolean; min_provider_credits: number; message_ar: string; message_en: string }> = {};
  for (const r of rowsData ?? []) byKey[r.service] = r;
  const row = byKey[service];
  const master = byKey["master"];
  const capacity = byKey["capacity"];

  let providerActive = false;
  let providerSlots = 0;
  try {
    const res = await fetch(`${TURNISCAN_BASE}/account/balance`, {
      headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
      signal: AbortSignal.timeout(8000),
    });
    const d = await res.json();
    providerActive = res.ok && d?.success === true && d?.status === "Active" && !d?.is_expired;
    providerSlots = Number(d?.available_credits ?? 0);
  } catch (e) {
    console.error("submit-check: provider unreachable", e);
  }

  let reason = "ok";
  let msg: { message_ar: string | null; message_en: string | null } = { message_ar: null, message_en: null };
  if (master && !master.enabled) {
    reason = "maintenance";
    msg = { message_ar: master.message_ar, message_en: master.message_en };
  } else if (!row || !row.enabled) {
    reason = "disabled";
    msg = { message_ar: row?.message_ar ?? null, message_en: row?.message_en ?? null };
  } else if (!providerActive) {
    reason = "maintenance";
    msg = { message_ar: master?.message_ar ?? row.message_ar, message_en: master?.message_en ?? row.message_en };
  } else if (providerSlots < Number(row.min_provider_credits)) {
    reason = "no_provider_slots";
    msg = { message_ar: capacity?.message_ar ?? row.message_ar, message_en: capacity?.message_en ?? row.message_en };
  }

  return {
    available: reason === "ok",
    reason,
    message_ar: reason === "ok" ? null : msg.message_ar,
    message_en: reason === "ok" ? null : msg.message_en,
  };
}

const cors_json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// The provider's own failure message is kept for the admin only (orders.provider_error).
// Written in a separate update so a missing column can never stop the order from failing.
// deno-lint-ignore no-explicit-any
async function saveProviderError(client: any, orderId: string, message: string) {
  if (!message) return;
  const { error } = await client.from("orders").update({ provider_error: message.slice(0, 500) }).eq("id", orderId);
  if (error) console.error("provider_error not saved:", error.message);
}


// ---- API credit log (provider balance around each submission and each result) ----
// Balance = TurniScan account balance (available_credits). Never blocks a check: any failure is logged and skipped.
async function providerBalance(): Promise<number | null> {
  try {
    const res = await fetch(`${TURNISCAN_BASE}/account/balance`, {
      headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
      signal: AbortSignal.timeout(8000),
    });
    const d = await res.json();
    const n = Number(d?.available_credits);
    return res.ok && Number.isFinite(n) ? n : null;
  } catch (e) {
    console.error("api-credit: balance unavailable", e);
    return null;
  }
}

// deno-lint-ignore no-explicit-any
async function logApiCredit(client: any, orderId: string, event: string, before: number | null, after: number | null, note: string) {
  let slots: number | null = null;
  try {
    const { count } = await client.from("slot_usages").select("id", { count: "exact", head: true })
      .eq("order_id", orderId).eq("status", "reserved");
    slots = count ?? null;
  } catch { slots = null; }
  const { error } = await client.from("api_credit_log").insert({
    order_id: orderId,
    event,
    api_before: before,
    api_after: after,
    api_delta: before != null && after != null ? after - before : null,
    slots_reserved: slots,
    note: note.slice(0, 200),
  });
  if (error) console.error("api_credit_log insert failed:", error.message);
}

// ---- Sending to TurniScan (shared by the first send and the queue) ----
type SendOpts = { exQuotes: boolean; exBiblio: boolean; exCit: boolean; exSmallLim: string | null; aiHighlights?: boolean };
type SubmitResult =
  | { ok: true; fileId: string }
  | { ok: false; unavailable: boolean; ambiguous: boolean; detail: string; providerMessage: string };

function buildProviderForm(file: File, orderId: string, service: ServiceKey, o: SendOpts): FormData {
  const f = new FormData();
  f.append("file", file, file.name);
  f.append("custom_id", orderId);
  f.append("service_type", service === "plag_only" ? "Turnitin Plagiarism" : "Both");
  if (o.exQuotes) f.append("exclude_quotes", "1");
  if (o.exBiblio) f.append("exclude_biblio", "1");
  if (o.exCit) f.append("exclude_citations", "1");
  if (o.exSmallLim) {
    f.append("exclude_small_matches", "1");
    f.append("small_match_threshold", o.exSmallLim);
  }
  // AI Highlights report asked for (same field name as TurniScan's own upload form; ignored if unknown).
  if (o.aiHighlights && service !== "plag_only") f.append("ai_highlights", "1");
  f.append("webhook_url", `${SUPABASE_URL}/functions/v1/turnitin-webhook`);
  return f;
}

// TurniScan sometimes answers with an HTML error page instead of JSON. That means the provider
// is unavailable, not that the file was refused, so it is reported separately (never sent twice).
async function sendToProvider(form: FormData): Promise<SubmitResult> {
  try {
    const tsRes = await fetch(`${TURNISCAN_BASE}/scan/submit`, {
      method: "POST",
      headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
      body: form,
      signal: AbortSignal.timeout(90000),
    });
    const raw = await tsRes.text();
    let data: Record<string, unknown> | null = null;
    try { data = JSON.parse(raw) as Record<string, unknown>; } catch { data = null; }
    if (data === null) {
      return { ok: false, unavailable: true, ambiguous: false, detail: `HTTP ${tsRes.status} non-JSON body: ${raw.slice(0, 300)}`, providerMessage: `HTTP ${tsRes.status}: ${raw.slice(0, 300)}` };
    }
    const fid = data.file_id;
    if (tsRes.ok && data.success === true && typeof fid === "string") return { ok: true, fileId: fid };
    return {
      ok: false,
      unavailable: tsRes.status >= 500,
      ambiguous: false,
      detail: `HTTP ${tsRes.status} ${JSON.stringify(data).slice(0, 300)}`,
      providerMessage: String(data.message ?? data.error ?? JSON.stringify(data)),
    };
  } catch (e) {
    // Timeout or network error: the provider may still have received the file.
    return { ok: false, unavailable: true, ambiguous: true, detail: `request failed: ${String(e)}`, providerMessage: String(e) };
  }
}

// A refusal that only means "busy, try again" (e.g. "temporary database concurrency ... Your scan credit
// was NOT deducted ... Please retry", "database is locked", HTTP 5xx). Such files wait in the queue.
function isTemporaryRefusal(r: SubmitResult): boolean {
  if (r.ok || r.ambiguous) return false;
  return r.unavailable || /concurren|database is locked|temporar|try again|please retry|not deducted|preserved|unavailable|overload|busy/i.test(r.providerMessage);
}

// Keeps a copy of the file so the queue can send it again later (safe storage name).
// deno-lint-ignore no-explicit-any
async function saveSourceCopy(client: any, orderId: string, file: File): Promise<string | null> {
  const ext = ((file.name.match(/\.([A-Za-z0-9]{1,8})$/) || [])[1] || "bin").toLowerCase();
  const path = `${orderId}/source.${ext}`;
  const { error } = await client.storage.from("order-source-files").upload(path, file, { upsert: true, contentType: file.type || undefined });
  if (error) { console.error("submit-check: source copy failed", orderId, error.message); return null; }
  await client.from("orders").update({ source_file_path: path }).eq("id", orderId);
  return path;
}

const QUEUE_MAX_HOURS = 12;   // a queued file still not accepted after this fails (slot returned)

// The queue: sends waiting files again, oldest first. Run every 30 seconds by the database scheduler.
// One file at a time; while TurniScan still answers "busy", the rest keep waiting. The order stays
// 'queued' while it is being tried (claimed with queue_attempt_at), so the customer sees "Queued"
// throughout, until TurniScan accepts the file.
// deno-lint-ignore no-explicit-any
async function processQueue(admin: any) {
  const out: Record<string, unknown>[] = [];
  const { data: rows } = await admin.from("orders")
    .select("id, user_id, file_name, check_type, source_file_path, exclude_quotes, exclude_bibliography, exclude_small_matches_word_limit, submitted_at, ai_highlights")
    .eq("status", "queued").order("submitted_at", { ascending: true }).limit(5);
  for (const o of rows ?? []) {
    const ageH = (Date.now() - new Date(o.submitted_at).getTime()) / 3600000;
    if (ageH > QUEUE_MAX_HOURS || !o.source_file_path) {
      const msg = "The check service is temporarily unavailable. Please try again in a few minutes. Your check was not used.";
      await admin.from("orders").update({ status: "error", error_reason: msg, completed_at: new Date().toISOString() })
        .eq("id", o.id).eq("status", "queued");   // slot goes back (trg_refund_on_order_failure)
      out.push({ order: o.id, result: o.source_file_path ? "expired" : "no file copy" });
      continue;
    }
    // Claim it (status unchanged), so two queue runs never send the same file. A claim older than
    // 5 minutes is from a run that died and may be taken again.
    const staleClaim = new Date(Date.now() - 5 * 60000).toISOString();
    const { data: claimed } = await admin.from("orders").update({ queue_attempt_at: new Date().toISOString() })
      .eq("id", o.id).eq("status", "queued")
      .or(`queue_attempt_at.is.null,queue_attempt_at.lt.${staleClaim}`)
      .select("id");
    if (!claimed || !claimed.length) continue;
    const release = () => admin.from("orders").update({ queue_attempt_at: null }).eq("id", o.id);

    const { data: blob, error: dlErr } = await admin.storage.from("order-source-files").download(o.source_file_path);
    if (dlErr || !blob) {
      await release();
      out.push({ order: o.id, result: "file read failed" });
      continue;
    }
    const file = new File([blob], o.file_name || "document", { type: blob.type || "application/octet-stream" });
    const service: ServiceKey = o.check_type === "sim_only" ? "plag_only" : "plag_ai";
    const form = buildProviderForm(file, o.id, service, {
      exQuotes: !!o.exclude_quotes, exBiblio: !!o.exclude_bibliography, exCit: false,
      exSmallLim: o.exclude_small_matches_word_limit ? String(o.exclude_small_matches_word_limit) : null,
      aiHighlights: !!o.ai_highlights,
    });
    // Cancelled meanwhile (by the customer or an admin): not sent.
    const { data: now } = await admin.from("orders").select("status").eq("id", o.id).maybeSingle();
    if (!now || now.status !== "queued") { out.push({ order: o.id, result: "cancelled before send" }); continue; }
    const before = await providerBalance();
    const r = await sendToProvider(form);
    const after = await providerBalance();
    await logApiCredit(admin, o.id, "submit", before, after, r.ok ? "accepted (from queue)" : (isTemporaryRefusal(r) ? "still busy (queue)" : "provider refused (queue)"));

    if (r.ok) {
      // Accepted: "Checking" starts now (sent_at is set when the status becomes 'run').
      await admin.from("orders").update({ external_order_id: r.fileId, status: "run", error_reason: null, provider_error: null, completed_at: null, queue_attempt_at: null }).eq("id", o.id);
      out.push({ order: o.id, result: "sent" });
      continue;
    }
    if (r.ambiguous) {
      await admin.from("orders").update({ status: "checking", error_reason: null, completed_at: new Date().toISOString(), queue_attempt_at: null }).eq("id", o.id);
      await saveProviderError(admin, o.id, r.providerMessage);
      out.push({ order: o.id, result: "outcome unknown" });
      continue;
    }
    if (isTemporaryRefusal(r)) {
      // Still busy: stays in the queue, and the others wait too.
      await release();
      await saveProviderError(admin, o.id, r.providerMessage);
      out.push({ order: o.id, result: "still busy" });
      break;
    }
    const errMsg = "The file could not be submitted for checking. Please try again later.";
    await admin.from("orders").update({ status: "error", error_reason: errMsg, completed_at: new Date().toISOString() }).eq("id", o.id);
    await saveProviderError(admin, o.id, r.providerMessage);
    out.push({ order: o.id, result: "refused" });
  }
  return out;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    // Internal calls (internal secret): the database scheduler runs the queue (no user), and the
    // developer API (pk-api) sends a customer's file on their behalf (x-api-user = the key's owner,
    // already checked by pk-api). Everything after this is the same as a file sent from the site.
    const internal = req.headers.get("x-internal-secret");
    let apiUserId: string | null = null;
    if (internal) {
      const adminQ = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
      const { data: expected } = await adminQ.rpc("get_internal_cron_secret");
      if (!expected || internal !== expected) return cors_json({ success: false, error: "Forbidden" }, 403);
      apiUserId = req.headers.get("x-api-user");
      if (!apiUserId) return cors_json({ success: true, queue: await processQueue(adminQ) });
    }

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    let user: { id: string };
    if (apiUserId) {
      user = { id: apiUserId };
    } else {
      const authHeader = req.headers.get("Authorization");
      if (!authHeader) return cors_json({ success: false, error: "Unauthorized" }, 401);
      const { data: { user: authUser }, error: authErr } = await admin.auth.getUser(authHeader.replace("Bearer ", ""));
      if (authErr || !authUser) return cors_json({ success: false, error: "Unauthorized" }, 401);
      user = authUser;
    }

    const fd = await req.formData();
    const orderId = fd.get("order_id") as string | null;
    const file = fd.get("file") as File | null;
    const exQuotes = fd.get("excludeQuotes") === "true";
    const exBiblio = fd.get("excludeBibliography") === "true";
    const exCit = fd.get("excludeCitations") === "true";
    const exSmallLim = fd.get("excludeSmallMatchesWordLimit") as string | null;
    const grantId = (fd.get("grant_id") as string | null) || null; // the package the customer picked

    if (!orderId || !file) return cors_json({ success: false, error: "Missing order_id or file" }, 400);

    // An admin may resend a customer's failed order (admin page "Resend"). The order and its slot
    // then belong to the customer, never to the admin.
    const { data: adminRow } = apiUserId ? { data: null } : await admin.from("admins").select("id").eq("id", user.id).maybeSingle();
    const isAdmin = !!adminRow;

    let orderQuery = admin.from("orders").select("id, user_id, status, check_type, external_order_id, ai_highlights").eq("id", orderId);
    if (!isAdmin) orderQuery = orderQuery.eq("user_id", user.id);
    const { data: order, error: orderErr } = await orderQuery.maybeSingle();
    if (orderErr || !order) return cors_json({ success: false, error: "Order not found" }, 404);
    // Cancelled by an admin before it was sent: never sent.
    if (order.status === "cancelled") return cors_json({ success: false, code: "CANCELLED", error: "This order was cancelled." }, 409);
    const ownerId: string = order.user_id;
    const adminResend = isAdmin && ["error", "failed_invalid"].includes(order.status);
    if (isAdmin && !adminResend && order.user_id !== user.id) {
      return cors_json({ success: false, error: "Only a failed order can be resent." }, 409);
    }

    // A retried request for an order that was already sent does nothing new
    // (an admin resend of a failed order is a new send).
    if (order.external_order_id && !adminResend) {
      return cors_json({ success: true, externalOrderId: order.external_order_id, alreadySubmitted: true });
    }

    // A file that just failed at the provider waits 60 seconds before it can be sent again.
    const { data: recentFail } = adminResend ? { data: null } : await admin
      .from("orders").select("id")
      .eq("user_id", ownerId).eq("file_name", file.name).eq("file_size", file.size).eq("status", "error")
      .gte("completed_at", new Date(Date.now() - 60000).toISOString())
      .limit(1).maybeSingle();
    if (recentFail) {
      return cors_json({ success: false, code: "FILE_COOLDOWN", retry_after_seconds: 60,
        error: "This file just failed. Please wait a minute before submitting it again." }, 429);
    }

    const service: ServiceKey = order.check_type === "sim_only" ? "plag_only" : "plag_ai";

    const availability = await providerAvailability(admin, service);
    if (!availability.available) {
      await admin.from("orders").update({ status: "error", error_reason: `MAINTENANCE:${availability.reason}` }).eq("id", orderId);
      return cors_json({ success: false, code: "MAINTENANCE", reason: availability.reason,
        message_ar: availability.message_ar, message_en: availability.message_en }, 503);
    }

    // The slot reservation is the gate: only the request that actually inserts the usage may send.
    // A concurrent request for the same order gets either a unique-key conflict (code 23505) or
    // replayed=true, and must not send the file again (that would charge the provider and a slot twice).
    const slotKey = `order:${orderId}`;
    // Admin resend: the slot given back when the order failed is taken again (one slot per order).
    let again: string | null = null;
    if (adminResend) {
      // Claim the failed order first, so a second click cannot send the file twice.
      const { data: claimed } = await admin.from("orders").update({ status: "uploading" })
        .eq("id", orderId).in("status", ["error", "failed_invalid"]).select("id");
      if (!claimed || !claimed.length) {
        return cors_json({ success: false, code: "ALREADY_SUBMITTING", error: "This order is already being submitted." }, 409);
      }
      const { data, error: againErr } = await admin.rpc("rereserve_order_slot", { p_order_id: orderId });
      if (againErr) throw againErr;
      again = data as string;
      if (again === "no_slot") {
        await admin.from("orders").update({ status: "error" }).eq("id", orderId);
        return cors_json({ success: false, code: "NO_SLOTS", error: "The customer has no slot left for this check." }, 402);
      }
    }
    const { data: reserved, error: reserveErr } = (again === "reserved" || again === "already")
      ? { data: { replayed: false }, error: null }
      : await admin.rpc("reserve_slot", {
        p_user_id: ownerId,
        p_slot_type: service,
        p_idempotency_key: slotKey,
        p_order_id: orderId,
        p_grant_id: adminResend ? null : grantId,
      });
    if (reserveErr) {
      if (String(reserveErr.message).includes("NO_SLOT_AVAILABLE")) {
        await admin.from("orders").update({ status: "error", error_reason: "NO_SLOTS" }).eq("id", orderId);
        return cors_json({ success: false, code: "NO_SLOTS", slot_type: service }, 402);
      }
      if ((reserveErr as { code?: string }).code === "23505") {
        return cors_json({ success: false, code: "ALREADY_SUBMITTING", error: "This order is already being submitted." }, 409);
      }
      throw reserveErr;
    }
    if ((reserved as { replayed?: boolean } | null)?.replayed) {
      // Another request already reserved this order: never send it again.
      return cors_json({ success: false, code: "ALREADY_SUBMITTING", error: "This order is already being submitted." }, 409);
    }

    // Last check before the file leaves: an admin may have cancelled the order meanwhile.
    const { data: still } = await admin.from("orders").select("status").eq("id", orderId).maybeSingle();
    if (!still || still.status === "cancelled") {
      await admin.rpc("release_slot", { p_idempotency_key: slotKey });
      return cors_json({ success: false, code: "CANCELLED", error: "This order was cancelled." }, 409);
    }

    const tsForm = buildProviderForm(file, orderId, service, { exQuotes, exBiblio, exCit, exSmallLim, aiHighlights: !!order.ai_highlights });

    // One send only: a second send could create a second check at the provider.
    const apiBefore = await providerBalance();
    const result = await sendToProvider(tsForm);
    const apiAfter = await providerBalance();
    const apiNote = result.ok ? "accepted"
      : result.ambiguous ? "outcome unknown"
      : result.unavailable ? "provider unavailable"
      : "provider refused";
    await logApiCredit(admin, orderId, "submit", apiBefore, apiAfter, apiNote);

    if (!result.ok && result.ambiguous) {
      // We do not know whether the provider got the file (timeout or dropped connection).
      // The slot stays reserved and the order waits in "checking": the provider's webhook
      // confirms it (and completes the order), or the sweeper releases the slot after 2 hours.
      await admin.from("orders").update({ status: "checking", error_reason: null, completed_at: new Date().toISOString() }).eq("id", orderId);
      await saveProviderError(admin, orderId, result.providerMessage);
      console.error("submit-check: provider outcome unknown, order left in checking", orderId, result.detail);
      return cors_json({ success: true, pending: true, status: "checking" }, 202);
    }

    if (isTemporaryRefusal(result)) {
      // TurniScan is busy ("temporary database concurrency ... Please retry"): the file waits in the
      // queue and is sent again automatically (every 20 seconds). The slot stays held for it; if the
      // customer cancels, or it is never accepted, the slot goes back.
      let src = (await admin.from("orders").select("source_file_path").eq("id", orderId).maybeSingle()).data?.source_file_path;
      if (!src) src = await saveSourceCopy(admin, orderId, file);
      if (src) {
        await admin.from("orders").update({ status: "queued", error_reason: null, completed_at: null }).eq("id", orderId);
        await saveProviderError(admin, orderId, result.providerMessage);
        console.error("submit-check: provider busy, order queued", orderId, result.detail);
        return cors_json({ success: true, queued: true, status: "queued" }, 202);
      }
      // Without a copy of the file it cannot be sent later: fails as before.
    }

    if (!result.ok) {
      // Provider answered and did not accept the file, so the slot goes back.
      await admin.rpc("release_slot", { p_idempotency_key: slotKey });
      // Provider details stay in the logs only; the customer sees a neutral message.
      console.error(result.unavailable ? "submit-check: provider unavailable" : "submit-check: provider refused", result.detail);
      if (result.unavailable) {
        const unavailableMsg = "The check service is temporarily unavailable. Please try again in a few minutes. Your check was not used.";
        await admin.from("orders").update({ status: "error", error_reason: unavailableMsg, completed_at: new Date().toISOString() }).eq("id", orderId);
        await saveProviderError(admin, orderId, result.providerMessage);
        return cors_json({ success: false, code: "PROVIDER_UNAVAILABLE", error: unavailableMsg }, 503);
      }
      const errMsg = "The file could not be submitted for checking. Please try again later.";
      await admin.from("orders").update({ status: "error", error_reason: errMsg, completed_at: new Date().toISOString() }).eq("id", orderId);
      await saveProviderError(admin, orderId, result.providerMessage);
      return cors_json({ success: false, error: errMsg }, 422);
    }

    const fileId = result.fileId;
    // The provider accepted the file, so the order must record it. Retry once if the write fails:
    // without the id a second submit of this order would be refused, but polling would not work.
    const sent = { external_order_id: fileId, status: "run", error_reason: null, provider_error: null, completed_at: null };
    let { error: saveErr } = await admin.from("orders").update(sent).eq("id", orderId);
    if (saveErr) {
      console.error("submit-check: saving external_order_id failed, retrying", saveErr.message);
      ({ error: saveErr } = await admin.from("orders").update(sent).eq("id", orderId));
      if (saveErr) console.error("submit-check: external_order_id NOT saved for order", orderId, fileId);
    }

    return cors_json({ success: true, externalOrderId: fileId, slot_type: service });
  } catch (err) {
    console.error("submit-check error:", err);
    return cors_json({ success: false, error: "Internal server error" }, 500);
  }
});
