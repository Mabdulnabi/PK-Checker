import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;
const TURNISCAN_BASE = "https://turniscan.com/v1";

// TurniScan does not sign webhooks, so the payload is never trusted on its own.
// Every status change is re-read from GET /v1/scan/status with our API key,
// and the order is only updated when its external_order_id matches the file.

function extractFilename(contentDisposition: string | null, fallback: string): string {
  if (contentDisposition) {
    const m = contentDisposition.match(/filename\*?=(?:UTF-8'')?["']?([^"';\r\n]+)["']?/i);
    if (m) return decodeURIComponent(m[1].trim());
  }
  return fallback;
}

async function fetchAndStore(
  supabase: ReturnType<typeof createClient>,
  fileId: string,
  folder: string,
  reportType: "sim" | "ai",
): Promise<string | null> {
  const apiUrl = reportType === "ai"
    ? `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}&report_type=ai`
    : `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}`;

  const res = await fetch(apiUrl, { headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` } });
  if (!res.ok) {
    console.error(`webhook: ${reportType} fetch failed`, res.status, await res.text());
    return null;
  }
  const filename = extractFilename(res.headers.get("Content-Disposition"), `${reportType}_report.pdf`);
  const storagePath = `${folder}/${filename}`;
  const pdf = await res.arrayBuffer();
  const { error } = await supabase.storage
    .from("order-reports")
    .upload(storagePath, pdf, { contentType: "application/pdf", upsert: true });
  if (error) { console.error(`webhook: ${reportType} upload failed`, error.message); return null; }
  return `/storage/${storagePath}`;
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
    .select("id, check_type, external_order_id")
    .eq("id", customId)
    .maybeSingle();
  if (!order) return new Response("OK", { status: 200 });

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

    const simUrl = await fetchAndStore(supabase, fileId, `sim-reports/${customId}`, "sim");
    if (simUrl) updates.report_url = simUrl;

    if (checkType !== "sim_only") {
      const aiUrl = await fetchAndStore(supabase, fileId, `ai-reports/${customId}`, "ai");
      if (aiUrl) updates.ai_report_url = aiUrl;
    }

    updates.completed_at = new Date().toISOString();
    if (typeof scan.similarity_score === "number") updates.similarity_score = scan.similarity_score;
    if (typeof scan.ai_score === "number")         updates.ai_score = scan.ai_score;
  } else if (internalStatus === "error") {
    updates.error_reason = scan.error || `TurniScan: ${scan.status}`;
  }

  const { error } = await supabase.from("orders").update(updates).eq("id", customId);
  if (error) console.error("webhook: DB update failed", error, customId);
  else       console.log("webhook: order", customId, "→", internalStatus);

  return new Response("OK", { status: 200 });
});
