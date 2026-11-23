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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return cors_json({ success: false, error: "Unauthorized" }, 401);

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: { user }, error: authErr } = await admin.auth.getUser(authHeader.replace("Bearer ", ""));
    if (authErr || !user) return cors_json({ success: false, error: "Unauthorized" }, 401);

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
    const { data: adminRow } = await admin.from("admins").select("id").eq("id", user.id).maybeSingle();
    const isAdmin = !!adminRow;

    let orderQuery = admin.from("orders").select("id, user_id, status, check_type, external_order_id").eq("id", orderId);
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

    const tsForm = new FormData();
    tsForm.append("file", file, file.name);
    tsForm.append("custom_id", orderId);
    tsForm.append("service_type", service === "plag_only" ? "Turnitin Plagiarism" : "Both");
    if (exQuotes) tsForm.append("exclude_quotes", "1");
    if (exBiblio) tsForm.append("exclude_biblio", "1");
    if (exCit) tsForm.append("exclude_citations", "1");
    if (exSmallLim) {
      tsForm.append("exclude_small_matches", "1");
      tsForm.append("small_match_threshold", exSmallLim);
    }
    tsForm.append("webhook_url", `${SUPABASE_URL}/functions/v1/turnitin-webhook`);

    // TurniScan sometimes answers with an HTML error page instead of JSON. That means the provider
    // is unavailable, not that the file was refused, so it is reported separately (never sent twice).
    type SubmitResult =
      | { ok: true; fileId: string }
      | { ok: false; unavailable: boolean; ambiguous: boolean; detail: string; providerMessage: string };

    const sendToProvider = async (): Promise<SubmitResult> => {
      try {
        const tsRes = await fetch(`${TURNISCAN_BASE}/scan/submit`, {
          method: "POST",
          headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
          body: tsForm,
          signal: AbortSignal.timeout(90000),
        });
        const raw = await tsRes.text();
        let data: Record<string, unknown> | null = null;
        try {
          data = JSON.parse(raw) as Record<string, unknown>;
        } catch {
          data = null;
        }
        if (data === null) {
          return { ok: false, unavailable: true, ambiguous: false, detail: `HTTP ${tsRes.status} non-JSON body: ${raw.slice(0, 300)}`, providerMessage: `HTTP ${tsRes.status}: ${raw.slice(0, 300)}` };
        }
        const fid = data.file_id;
        if (tsRes.ok && data.success === true && typeof fid === "string") {
          return { ok: true, fileId: fid };
        }
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
    };

    // One send only: a second send could create a second check at the provider.
    const apiBefore = await providerBalance();
    const result = await sendToProvider();
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
