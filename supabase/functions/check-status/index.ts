import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { getDocumentProxy, extractText } from "npm:unpdf@1";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;
const TURNISCAN_BASE = "https://turniscan.com/v1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function mapStatus(s: string): string {
  const l = s.toLowerCase();
  if (l === "completed") return "completed";
  if (l === "failed" || l === "rejected") return "error";
  if (l === "processing") return "processing";
  return "run";
}

async function downloadReport(fileId: string, reportType: "sim" | "ai"): Promise<ArrayBuffer | null> {
  const apiUrl = reportType === "ai"
    ? `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}&report_type=ai`
    : `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}`;
  const res = await fetch(apiUrl, { headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` } });
  if (!res.ok) {
    console.error(`check-status: ${reportType} fetch failed`, res.status, await res.text());
    return null;
  }
  return await res.arrayBuffer();
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
    console.error("check-status: upload failed", storagePath, error.message);
    return null;
  }
  return `/storage/${storagePath}`;
}

// What the AI download actually contains: "NN% detected as AI" on the AI page,
// "*%" when the score is under 20%. A similarity-only file is not an AI report.
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
    console.error("check-status: AI pdf read failed", String(e));
    return { hasAi: false, score: { kind: "unknown" } };
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ success: false, error: "Unauthorized" }, 401);

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authErr } = await supabase.auth.getUser(token);
    if (authErr || !user) return json({ success: false, error: "Unauthorized" }, 401);

    const url = new URL(req.url);
    const orderId = url.searchParams.get("order_id");
    if (!orderId) return json({ success: false, error: "Missing order_id" }, 400);

    const { data: order, error: orderErr } = await supabase
      .from("orders")
      .select("id, external_order_id, status, user_id, check_type, completed_at, report_url, ai_report_url")
      .eq("id", orderId).eq("user_id", user.id).single();
    if (orderErr || !order) return json({ success: false, error: "Order not found" }, 404);

    const fileId = (order as { external_order_id: string }).external_order_id;
    if (!fileId) return json({ success: false, polled: false, error: "No external_order_id yet" });

    const tsRes = await fetch(`${TURNISCAN_BASE}/scan/status?file_id=${encodeURIComponent(fileId)}`, {
      headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
    });
    const tsData = await tsRes.json();
    if (!tsRes.ok || !tsData.success) {
      console.error("check-status: provider status error", JSON.stringify(tsData));
      return json({ success: false, polled: false, error: "The check status is not available right now. Please try again later." });
    }

    const internalStatus = mapStatus(tsData.status as string);
    const updates: Record<string, unknown> = { status: internalStatus };
    const reports: { similarity?: { downloadUrl: string }; ai?: { downloadUrl: string } } = {};

    const checkType = (order as { check_type: string }).check_type;
    if (internalStatus === "completed") {
      // Reports already stored are not downloaded again on every poll.
      const haveSim = !!(order as { report_url: string | null }).report_url;
      const haveAi = !!(order as { ai_report_url: string | null }).ai_report_url;
      if (haveSim) reports.similarity = { downloadUrl: (order as { report_url: string }).report_url };
      if (haveAi) reports.ai = { downloadUrl: (order as { ai_report_url: string }).ai_report_url };
      const simBytes = haveSim ? null : await downloadReport(fileId, "sim");
      if (simBytes) {
        const simUrl = await storeFixed(supabase, `sim-reports/${orderId}`, "sim_report.pdf", simBytes);
        if (simUrl) { updates.report_url = simUrl; reports.similarity = { downloadUrl: simUrl }; }
      }

      if (checkType !== "sim_only" && !haveAi) {
        const aiBytes = await downloadReport(fileId, "ai");
        if (aiBytes) {
          const aiRead = await readAiPdf(aiBytes);
          if (aiRead.hasAi) {
            const aiUrl = await storeFixed(supabase, `ai-reports/${orderId}`, "ai_report.pdf", aiBytes);
            if (aiUrl) { updates.ai_report_url = aiUrl; reports.ai = { downloadUrl: aiUrl }; }
            if (aiRead.score.kind === "value")  updates.ai_score = aiRead.score.value;
            if (aiRead.score.kind === "hidden") updates.ai_score = null;
          }
        }
      }

      // Keep the first completion time.
      if (!(order as { completed_at: string | null }).completed_at) {
        updates.completed_at = new Date().toISOString();
      }
      if (typeof tsData.similarity_score === "number") updates.similarity_score = tsData.similarity_score;

    } else if (internalStatus === "error") {
      console.error("check-status: provider reported failure", JSON.stringify(tsData));
      updates.error_reason = "The check could not be completed.";
      updates.completed_at = new Date().toISOString();
    }

    await supabase.from("orders").update(updates).eq("id", orderId);
    if (internalStatus === "error") await saveProviderError(supabase, orderId, String(tsData.error ?? tsData.message ?? ""));
    // An order that was waiting in "checking" and is now refused: give its slot back (same as the webhook).
    if (internalStatus === "error" && (order as { status: string }).status === "checking") {
      const { error: relErr } = await supabase.rpc("release_slot", { p_idempotency_key: `order:${orderId}` });
      if (relErr) console.error("check-status: release_slot failed", relErr.message, orderId);
    }

    return json({ success: true, polled: true, status: internalStatus, reports,
      ...(internalStatus === "error" ? { error: updates.error_reason } : {}) });

  } catch (err) {
    console.error("check-status error:", err);
    return json({ success: false, polled: false, error: "Internal server error" }, 500);
  }
});
