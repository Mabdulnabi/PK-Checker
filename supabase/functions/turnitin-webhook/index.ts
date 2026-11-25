import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { getDocumentProxy, extractText } from "npm:unpdf@1";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;
const TURNISCAN_BASE = "https://turniscan.com/v1";

// TurniScan does not sign webhooks, so the payload is never trusted on its own.
// Every status change is re-read from GET /v1/scan/status with our API key,
// and the order is only updated when its external_order_id matches the file.

async function downloadReport(fileId: string, reportType: "sim" | "ai"): Promise<ArrayBuffer | null> {
  const apiUrl = reportType === "ai"
    ? `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}&report_type=ai`
    : `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}`;
  const res = await fetch(apiUrl, { headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` } });
  if (!res.ok) {
    console.error(`webhook: ${reportType} fetch failed`, res.status, await res.text());
    return null;
  }
  return await res.arrayBuffer();
}

// ---- AI Highlights report (only for orders where the customer asked for it) ----
// TurniScan serves it from /scan/download?report_type=highlights. Turnitin only produces it for some
// files, so a missing one is normal. A reply is kept only when it is a PDF and is neither the similarity
// nor the AI report (a provider fallback must never be shown as the highlights report).
async function sha256(bytes: ArrayBuffer): Promise<string> {
  const h = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(h)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function downloadHighlights(fileId: string): Promise<ArrayBuffer | null> {
  try {
    const res = await fetch(`${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}&report_type=highlights`, {
      headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
      signal: AbortSignal.timeout(30000),
    });
    if (!res.ok) {
      console.log("highlights: not available", fileId, res.status, (await res.text()).slice(0, 200));
      return null;
    }
    const bytes = await res.arrayBuffer();
    const head = new TextDecoder().decode(new Uint8Array(bytes.slice(0, 5)));
    if (head !== "%PDF-") { console.log("highlights: reply is not a PDF", fileId); return null; }
    return bytes;
  } catch (e) {
    console.error("highlights: fetch failed", fileId, String(e));
    return null;
  }
}

// deno-lint-ignore no-explicit-any
async function storedBytes(supabase: any, stored: string | null | undefined): Promise<ArrayBuffer | null> {
  if (!stored || !stored.startsWith("/storage/")) return null;
  const { data } = await supabase.storage.from("order-reports").download(stored.replace("/storage/", ""));
  return data ? await data.arrayBuffer() : null;
}

// Tries once; returns the stored path, or null (and counts the try).
// deno-lint-ignore no-explicit-any
async function fetchAndStoreHighlights(supabase: any, orderId: string, fileId: string, others: (ArrayBuffer | null)[]): Promise<string | null> {
  const { data: row } = await supabase.from("orders").select("ai_highlights_tries").eq("id", orderId).maybeSingle();
  await supabase.from("orders").update({ ai_highlights_tries: Number(row?.ai_highlights_tries ?? 0) + 1 }).eq("id", orderId);
  // TurniScan's status names the highlights report when it exists; without it, the download endpoint
  // answers with another report, so nothing is fetched.
  const st = await fetchScanStatus(fileId);
  if (!st || !st.ai_highlights_url) { console.log("highlights: none yet", orderId); return null; }
  const bytes = await downloadHighlights(fileId);
  if (!bytes) return null;
  const hash = await sha256(bytes);
  for (const o of others) {
    if (o && await sha256(o) === hash) { console.log("highlights: same as another report, ignored", orderId); return null; }
  }
  const url = await storeFixed(supabase, `ai-highlights/${orderId}`, "ai_highlights.pdf", bytes);
  if (url) {
    const { error } = await supabase.from("orders").update({ ai_highlights_url: url }).eq("id", orderId);
    if (error) { console.error("highlights: DB update failed", orderId, error.message); return null; }
    console.log("highlights: stored", orderId);
  }
  return url;
}

// Removes the file and its reports from TurniScan (POST /v1/scan/delete). Our copies are already stored.
// true = gone there (deleted now, or already gone).
async function deleteAtProvider(fileId: string): Promise<boolean> {
  try {
    // Form-encoded, as in TurniScan's own example (curl -d "file_id=...").
    const res = await fetch(`${TURNISCAN_BASE}/scan/delete`, {
      method: "POST", headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` }, body: new URLSearchParams({ file_id: fileId }),
      signal: AbortSignal.timeout(20000),
    });
    const body = await res.text();
    if (res.ok || res.status === 404 || res.status === 410) return true;
    console.error("provider delete failed", fileId, res.status, body.slice(0, 200));
    return false;
  } catch (e) {
    console.error("provider delete failed", fileId, String(e));
    return false;
  }
}

// Fixed file name, and never overwrite: a stored report is kept as it is.
async function storeFixed(
  supabase: ReturnType<typeof createClient>,
  folder: string,
  name: string,
  bytes: ArrayBuffer,
): Promise<string | null> {
  const storagePath = `${folder}/${name}`;
  const { error } = await supabase.storage
    .from("order-reports")
    .upload(storagePath, bytes, { contentType: "application/pdf", upsert: false });
  if (error && !/already exists|duplicate/i.test(error.message)) {
    console.error("webhook: upload failed", storagePath, error.message);
    return null;
  }
  return `/storage/${storagePath}`;
}

// What the AI download actually contains. The AI page says "NN% detected as AI";
// Turnitin shows "*%" when the score is under 20%. A file with only the similarity
// pages is not an AI report.
type AiScore = { kind: "value"; value: number } | { kind: "hidden" } | { kind: "unknown" };
type AiRead = { hasAi: boolean; score: AiScore };

async function readAiPdf(bytes: ArrayBuffer): Promise<AiRead> {
  try {
    const pdf = await getDocumentProxy(new Uint8Array(bytes.slice(0)));
    const { text } = await extractText(pdf, { mergePages: false });
    const pages = text as string[];
    const hasAi = pages.some((pg) => /detected as AI/i.test(pg));
    const page2 = String(pages[1] ?? "");
    const m = page2.match(/(\d{1,3}(?:\.\d+)?)\s*%\s*detected as AI/i);
    if (m) return { hasAi, score: { kind: "value", value: Number(m[1]) } };
    if (/\*\s*%\s*detected as AI/i.test(page2)) return { hasAi, score: { kind: "hidden" } };
    return { hasAi, score: { kind: "unknown" } };
  } catch (e) {
    console.error("webhook: AI pdf read failed", String(e));
    return { hasAi: false, score: { kind: "unknown" } };
  }
}

interface ScanStatus {
  status?: string;
  similarity_score?: number;
  ai_score?: number;
  error?: string;
  error_message?: string | null;
  word_count?: number;
  ai_highlights_url?: string | null;
}

// Returns null when TurniScan can't confirm the file, so the caller can ask for a retry.
async function fetchScanStatus(fileId: string): Promise<ScanStatus | null> {
  try {
    const res = await fetch(`${TURNISCAN_BASE}/scan/status?file_id=${encodeURIComponent(fileId)}`, {
      headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
    });
    if (!res.ok) return null;
    const data = await res.json();
    console.log("webhook: scan status raw", fileId, JSON.stringify(data));
    const body = (data && typeof data === "object" && data.data && typeof data.data === "object") ? data.data : data;
    return body && typeof body.status === "string" ? (body as ScanStatus) : null;
  } catch (e) {
    console.error("webhook: status lookup failed", e);
    return null;
  }
}

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
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  let payload: Record<string, unknown>;
  try { payload = await req.json(); }
  catch { return new Response("Bad Request", { status: 400 }); }

  // Scheduled retry (every 15 minutes, internal secret only): completed checks whose AI Highlights
  // report was asked for but has not arrived yet.
  if (payload.action === "highlights_sweep") {
    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const sent = req.headers.get("x-internal-secret") ?? "";
    const { data: expected } = await supabase.rpc("get_internal_cron_secret");
    if (!expected || sent !== expected) return new Response("Forbidden", { status: 403 });
    const { data: due } = await supabase.rpc("orders_waiting_highlights");
    let stored = 0;
    for (const r of (due ?? []) as { id: string; external_order_id: string }[]) {
      const { data: o } = await supabase.from("orders").select("report_url, ai_report_url").eq("id", r.id).maybeSingle();
      const others = [await storedBytes(supabase, o?.report_url), await storedBytes(supabase, o?.ai_report_url)];
      if (await fetchAndStoreHighlights(supabase, r.id, r.external_order_id, others)) stored++;
    }
    // Completed checks whose reports are stored here: removed from TurniScan (privacy).
    const { data: toDelete } = await supabase.rpc("orders_due_provider_delete");
    let deleted = 0;
    for (const r of (toDelete ?? []) as { id: string; external_order_id: string }[]) {
      if (await deleteAtProvider(r.external_order_id)) {
        await supabase.from("orders").update({ provider_deleted_at: new Date().toISOString() }).eq("id", r.id);
        deleted++;
      }
    }
    return new Response(JSON.stringify({ success: true, checked: (due ?? []).length, stored, deleted }), { headers: { "Content-Type": "application/json" } });
  }

  const fileId   = typeof payload.file_id === "string" ? payload.file_id : undefined;
  const customId = typeof payload.custom_id === "string" ? payload.custom_id : undefined;
  if (!customId || !fileId) {
    console.error("webhook: missing custom_id or file_id");
    return new Response("OK", { status: 200 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: order } = await supabase
    .from("orders")
    .select("id, check_type, external_order_id, purged_at, completed_at, status, report_url, ai_report_url, ai_score, ai_highlights, ai_highlights_url, provider_deleted_at")
    .eq("id", customId)
    .maybeSingle();
  if (!order) return new Response("OK", { status: 200 });
  // Files were purged after the 48-hour retention window. Don't store them again.
  if (order.purged_at) return new Response("OK", { status: 200 });
  // Already removed from TurniScan after its reports were stored: nothing left to read there.
  if (order.provider_deleted_at) return new Response("OK", { status: 200 });

  // If we already stored a file id for this order, the webhook must refer to it.
  if (order.external_order_id && order.external_order_id !== fileId) {
    console.error("webhook: file_id does not match order", customId);
    return new Response("Forbidden", { status: 403 });
  }

  // Ask TurniScan directly. Failing that, return 503 so TurniScan retries.
  const scan = await fetchScanStatus(fileId);
  if (!scan) return new Response("Service Unavailable", { status: 503 });

  const s = scan.status!.toLowerCase();
  const internalStatus =
    s === "completed" ? "completed" :
    (s === "failed" || s === "rejected") ? "error" : "processing";
  // A finished order is never moved back by a late or repeated webhook.
  if (order.status === "completed" && internalStatus !== "completed") {
    return new Response("OK", { status: 200 });
  }

  const updates: Record<string, unknown> = { status: internalStatus };
  if (!order.external_order_id) updates.external_order_id = fileId;
  let simBytesKept: ArrayBuffer | null = null;
  let aiBytesKept: ArrayBuffer | null = null;

  if (internalStatus === "completed") {
    const checkType = order.check_type as string | null;

    const simBytes = await downloadReport(fileId, "sim");
    simBytesKept = simBytes;
    if (simBytes) {
      const simUrl = await storeFixed(supabase, `sim-reports/${customId}`, "sim_report.pdf", simBytes);
      if (simUrl) updates.report_url = simUrl;
    }
    // A completed order must have its similarity report. If it could not be stored, do not mark
    // the order completed: answer 503 so TurniScan sends the webhook again.
    if (!updates.report_url && !order.report_url) {
      console.error("webhook: similarity report not stored, asking for a retry", customId);
      return new Response("Service Unavailable", { status: 503 });
    }

    if (checkType !== "sim_only") {
      const aiBytes = await downloadReport(fileId, "ai");
      aiBytesKept = aiBytes;
      if (aiBytes) {
        const aiRead = await readAiPdf(aiBytes);
        console.log("webhook: AI download", customId, JSON.stringify(aiRead));
        if (aiRead.hasAi) {
          const aiUrl = await storeFixed(supabase, `ai-reports/${customId}`, "ai_report.pdf", aiBytes);
          if (aiUrl) updates.ai_report_url = aiUrl;
          if (aiRead.score.kind === "value")  updates.ai_score = aiRead.score.value;
          if (aiRead.score.kind === "hidden") updates.ai_score = null;
        } else {
          // Not an AI report: keep the existing AI links and score untouched.
          console.log("webhook: AI download has no AI page, links unchanged", customId);
        }
      }
    }

    // Keep the first completion time: a re-run must not move the delivery time.
    if (!order.completed_at) updates.completed_at = new Date().toISOString();
    if (typeof scan.similarity_score === "number") updates.similarity_score = scan.similarity_score;
    // Turnitin's own word count replaces the estimate made in the customer's browser.
    if (typeof scan.word_count === "number" && scan.word_count > 0) updates.word_count = scan.word_count;
  } else if (internalStatus === "error") {
    console.error("webhook: provider reported failure", JSON.stringify(scan));
    updates.error_reason = "The check could not be completed.";
    updates.completed_at = new Date().toISOString();
  }

  const { error } = await supabase.from("orders").update(updates).eq("id", customId);
  // AI Highlights: asked for, AI part checked and the AI score not above 20%. Never blocks the order.
  if (!error && internalStatus === "completed" && order.ai_highlights && !order.ai_highlights_url && order.check_type !== "sim_only") {
    const score = "ai_score" in updates ? updates.ai_score as number | null : order.ai_score as number | null;
    if (score == null || score <= 20) {
      try {
        const simB = simBytesKept ?? await storedBytes(supabase, order.report_url as string | null);
        const aiB = aiBytesKept ?? await storedBytes(supabase, order.ai_report_url as string | null);
        await fetchAndStoreHighlights(supabase, customId, fileId, [simB, aiB]);
      } catch (e) { console.error("highlights: failed", customId, String(e)); }
    }
  }
  if (error) {
    // Answer with an error so TurniScan retries the webhook.
    console.error("webhook: DB update failed", error, customId);
    return new Response("Internal Server Error", { status: 500 });
  }
  console.log("webhook: order", customId, "->", internalStatus);
  if (internalStatus === "completed" || internalStatus === "error") {
    const { data: last } = await supabase.from("api_credit_log").select("api_after")
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    const prev = last?.api_after != null ? Number(last.api_after) : null;
    const apiNow = await providerBalance();
    await logApiCredit(supabase, customId, internalStatus === "completed" ? "completed" : "failed",
      prev, apiNow, internalStatus === "completed" ? "report ready" : "provider reported failure");
  }
  // An order that was waiting in "checking" (unknown outcome) and is now refused by the provider: give the slot back.
  if (internalStatus === "error" && order.status === "checking") {
    const { error: relErr } = await supabase.rpc("release_slot", { p_idempotency_key: `order:${customId}` });
    if (relErr) console.error("webhook: release_slot failed", relErr.message, customId);
  }
  if (internalStatus === "error") await saveProviderError(supabase, customId, String(scan.error_message ?? scan.error ?? (scan as Record<string, unknown>).message ?? ""));

  return new Response("OK", { status: 200 });
});
