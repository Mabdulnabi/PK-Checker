import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import JSZip from "npm:jszip@3.10.1";
import { getDocumentProxy, extractText } from "npm:unpdf@1";

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

// Arabic is not accepted: in the file name, or as the language of the document.
const ARABIC_CHARS = /[\u0600-\u06FF\u0750-\u077F\u08A0-\u08FF\uFB50-\uFDFF\uFE70-\uFEFF]/g;
const LATIN_CHARS = /[A-Za-z]/g;
const ARABIC_REJECT = {
  error: "الملف باللغة العربية ومش مسموح برفعه. The file is in Arabic and cannot be submitted.",
  code: "ARABIC_NOT_ALLOWED",
};

async function documentText(file: File): Promise<string> {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const name = file.name.toLowerCase();
  try {
    if (name.endsWith(".docx")) {
      const zip = await JSZip.loadAsync(bytes);
      const xml = (await zip.file("word/document.xml")?.async("string")) ?? "";
      return xml.replace(/<[^>]+>/g, " ");
    }
    if (name.endsWith(".pdf")) {
      const pdf = await getDocumentProxy(bytes);
      const { text } = await extractText(pdf, { mergePages: true });
      return String(text);
    }
  } catch (e) {
    console.error("submit-check: could not read the document text", String(e));
  }
  return "";
}

// Arabic when there are enough Arabic letters and they are a large share of the letters.
function isArabicDocument(text: string): boolean {
  const arabic = (text.match(ARABIC_CHARS) || []).length;
  const latin = (text.match(LATIN_CHARS) || []).length;
  const letters = arabic + latin;
  return arabic >= 50 && letters > 0 && arabic / letters >= 0.2;
}

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

    // Arabic file name or Arabic document: refused before any slot is used.
    if (/[\u0600-\u06FF]/.test(file.name) || isArabicDocument(await documentText(file))) {
      return cors_json({ success: false, code: ARABIC_REJECT.code, error: ARABIC_REJECT.error }, 422);
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
      p_grant_id: grantId,
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
      console.error("submit-check: provider request failed", e);
    }

    if (!tsOk) {
      // Not accepted for processing, so the slot goes back.
      await admin.rpc("release_slot", { p_idempotency_key: slotKey });
      // Provider details stay in the logs only; the customer sees a neutral message.
      console.error("submit-check: provider refused", JSON.stringify(tsData));
      const errMsg = "The file could not be submitted for checking. Please try again later.";
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
