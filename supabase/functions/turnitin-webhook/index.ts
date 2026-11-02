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

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  let payload: Record<string, unknown>;
  try { payload = await req.json(); }
  catch { return new Response("Bad Request", { status: 400 }); }

  const fileId   = typeof payload.file_id === "string" ? payload.file_id : undefined;
  const customId = typeof payload.custom_id === "string" ? payload.custom_id : undefined;
  if (!customId || !fileId) {
    console.error("webhook: missing custom_id or file_id");
    return new Response("OK", { status: 200 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: order } = await supabase
    .from("orders")
    .select("id, check_type, external_order_id, purged_at")
    .eq("id", customId)
    .maybeSingle();
  if (!order) return new Response("OK", { status: 200 });
  // Files were purged after the 48-hour retention window. Don't store them again.
  if (order.purged_at) return new Response("OK", { status: 200 });

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

  const updates: Record<string, unknown> = { status: internalStatus };
  if (!order.external_order_id) updates.external_order_id = fileId;

  if (internalStatus === "completed") {
    const checkType = order.check_type as string | null;

    const simBytes = await downloadReport(fileId, "sim");
    if (simBytes) {
      const simUrl = await storeFixed(supabase, `sim-reports/${customId}`, "sim_report.pdf", simBytes);
      if (simUrl) updates.report_url = simUrl;
    }

    if (checkType !== "sim_only") {
      const aiBytes = await downloadReport(fileId, "ai");
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

    updates.completed_at = new Date().toISOString();
    if (typeof scan.similarity_score === "number") updates.similarity_score = scan.similarity_score;
  } else if (internalStatus === "error") {
    updates.error_reason = scan.error || `TurniScan: ${scan.status}`;
  }

  const { error } = await supabase.from("orders").update(updates).eq("id", customId);
  if (error) console.error("webhook: DB update failed", error, customId);
  else       console.log("webhook: order", customId, "->", internalStatus);

  return new Response("OK", { status: 200 });
});
