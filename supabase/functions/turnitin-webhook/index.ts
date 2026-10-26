import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;
const TURNISCAN_BASE = "https://turniscan.com/v1";

async function fetchAndStore(
  supabase: ReturnType<typeof createClient>,
  fileId: string,
  storagePath: string,
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
  const pdf = await res.arrayBuffer();
  const { error } = await supabase.storage
    .from("order-reports")
    .upload(storagePath, pdf, { contentType: "application/pdf", upsert: true });
  if (error) { console.error(`webhook: ${reportType} upload failed`, error.message); return null; }
  return `/storage/${storagePath}`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  let payload: Record<string, unknown>;
  try { payload = await req.json(); }
  catch { return new Response("Bad Request", { status: 400 }); }

  const fileId          = payload.file_id as string | undefined;
  const customId        = payload.custom_id as string | undefined;
  const status          = (payload.status as string) || "";
  const similarityScore = payload.similarity_score as number | undefined;
  const aiScore         = payload.ai_score as number | undefined;

  if (!customId) {
    console.error("webhook: missing custom_id", payload);
    return new Response("OK", { status: 200 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const s = status.toLowerCase();
  const internalStatus =
    s === "completed" ? "completed" :
    (s === "failed" || s === "rejected") ? "error" : "processing";

  const updates: Record<string, unknown> = { status: internalStatus };
  if (fileId) updates.external_order_id = fileId;

  if (internalStatus === "completed" && fileId) {
    const simUrl = await fetchAndStore(supabase, fileId, `sim-reports/${customId}/sim_report.pdf`, "sim");
    if (simUrl) updates.report_url = simUrl;

    const aiUrl = await fetchAndStore(supabase, fileId, `ai-reports/${customId}/ai_report.pdf`, "ai");
    if (aiUrl) updates.ai_report_url = aiUrl;

    updates.completed_at = new Date().toISOString();
    if (similarityScore !== undefined) updates.similarity_score = similarityScore;
    if (aiScore !== undefined)         updates.ai_score = aiScore;
  } else if (internalStatus === "error") {
    updates.error_reason =
      (payload.error_message as string) || (payload.message as string) || `TurniScan: ${status}`;
  }

  const { error } = await supabase.from("orders").update(updates).eq("id", customId);
  if (error) console.error("webhook: DB update failed", error, customId);
  else       console.log("webhook: order", customId, "→", internalStatus);

  return new Response("OK", { status: 200 });
});
