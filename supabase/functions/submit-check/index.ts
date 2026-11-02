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
  const { data: row } = await admin
    .from("service_availability")
    .select("enabled, min_provider_credits, message_ar, message_en")
    .eq("service", service)
    .maybeSingle();

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
  if (!row || !row.enabled) reason = "disabled";
  else if (!providerActive) reason = "provider_unavailable";
  else if (providerSlots < Number(row.min_provider_credits)) reason = "no_provider_slots";

  return {
    available: reason === "ok",
    reason,
    message_ar: reason === "ok" ? null : (row?.message_ar ?? null),
    message_en: reason === "ok" ? null : (row?.message_en ?? null),
  };
}

const cors_json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

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

    if (!orderId || !file) return cors_json({ success: false, error: "Missing order_id or file" }, 400);

    const { data: order, error: orderErr } = await admin
      .from("orders")
      .select("id, check_type, external_order_id")
      .eq("id", orderId)
      .eq("user_id", user.id)
      .maybeSingle();
    if (orderErr || !order) return cors_json({ success: false, error: "Order not found" }, 404);

    // A retried request for an order that was already sent does nothing new.
    if (order.external_order_id) {
      return cors_json({ success: true, externalOrderId: order.external_order_id, alreadySubmitted: true });
    }

    const service: ServiceKey = order.check_type === "sim_only" ? "plag_only" : "plag_ai";

    const availability = await providerAvailability(admin, service);
    if (!availability.available) {
      await admin.from("orders").update({ status: "error", error_reason: `MAINTENANCE:${availability.reason}` }).eq("id", orderId);
      return cors_json({ success: false, code: "MAINTENANCE", reason: availability.reason,
        message_ar: availability.message_ar, message_en: availability.message_en }, 503);
    }

    const slotKey = `order:${orderId}`;
    const { error: reserveErr } = await admin.rpc("reserve_slot", {
      p_user_id: user.id,
      p_slot_type: service,
      p_idempotency_key: slotKey,
      p_order_id: orderId,
    });
    if (reserveErr) {
      if (String(reserveErr.message).includes("NO_SLOT_AVAILABLE")) {
        await admin.from("orders").update({ status: "error", error_reason: "NO_SLOTS" }).eq("id", orderId);
        return cors_json({ success: false, code: "NO_SLOTS", slot_type: service }, 402);
      }
      throw reserveErr;
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

    let tsData: Record<string, unknown> = {};
    let tsOk = false;
    try {
      const tsRes = await fetch(`${TURNISCAN_BASE}/scan/submit`, {
        method: "POST",
        headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
        body: tsForm,
      });
      tsData = await tsRes.json();
      tsOk = tsRes.ok && tsData.success === true && typeof tsData.file_id === "string";
    } catch (e) {
      console.error("submit-check: TurniScan request failed", e);
    }

    if (!tsOk) {
      // Not accepted for processing, so the slot goes back.
      await admin.rpc("release_slot", { p_idempotency_key: slotKey });
      const errMsg = (tsData.message as string) || "TurniScan submission failed";
      await admin.from("orders").update({ status: "error", error_reason: errMsg }).eq("id", orderId);
      return cors_json({ success: false, error: errMsg }, 422);
    }

    const fileId = tsData.file_id as string;
    await admin.from("orders").update({ external_order_id: fileId, status: "run" }).eq("id", orderId);

    return cors_json({ success: true, externalOrderId: fileId, slot_type: service });
  } catch (err) {
    console.error("submit-check error:", err);
    return cors_json({ success: false, error: "Internal server error" }, 500);
  }
});
