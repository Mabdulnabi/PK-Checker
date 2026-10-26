import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;
const TURNISCAN_BASE = "https://turniscan.com/v1";

async function uploadAiPdfToStorage(
  supabase: ReturnType<typeof createClient>,
  orderId: string,
  fileId: string,
): Promise<string | null> {
  try {
    const res = await fetch(
      `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}&report_type=ai`,
      { headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` } },
    );
    if (!res.ok) {
      console.error("turnitin-webhook: AI PDF fetch failed", res.status, await res.text());
      return null;
    }
    const pdf = await res.arrayBuffer();
    const path = `ai-reports/${orderId}/ai_report.pdf`;
    const { error } = await supabase.storage
      .from("order-reports")
      .upload(path, pdf, { contentType: "application/pdf", upsert: true });
    if (error) {
      console.error("turnitin-webhook: Storage upload failed", error.message);
      return null;
    }
    return `${SUPABASE_URL}/storage/v1/object/order-reports/${path}`;
  } catch (e) {
    console.error("turnitin-webhook: uploadAiPdfToStorage error", e);
    return null;
  }
}

// No JWT verification — TurniScan calls this endpoint without a Supabase token.
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return new Response("Bad Request", { status: 400 });
  }

  const fileId           = payload.file_id as string | undefined;
  const customId         = payload.custom_id as string | undefined;
  const status           = (payload.status as string) || "";
  const similarityScore  = payload.similarity_score as number | undefined;
  const aiScore          = payload.ai_score as number | undefined;

  if (!customId) {
    console.error("turnitin-webhook: missing custom_id", payload);
    return new Response("OK", { status: 200 });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const s = status.toLowerCase();
  let internalStatus: string;
  if (s === "completed")                  internalStatus = "completed";
  else if (s === "failed" || s === "rejected") internalStatus = "error";
  else                                    internalStatus = "processing";

  const updates: Record<string, unknown> = { status: internalStatus };
  if (fileId) updates.external_order_id = fileId;

  if (internalStatus === "completed" && fileId) {
    try {
      // Sim: follow redirect to get public CDN URL
      const simRes = await fetch(`${TURNISCAN_BASE}/scan/download?file_id=${fileId}`, {
        headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
        redirect: "manual",
      });
      const simUrl = simRes.headers.get("location");
      if (simUrl) updates.report_url = simUrl;

      // AI: download PDF and store in Supabase Storage
      const aiStorageUrl = await uploadAiPdfToStorage(supabase, customId, fileId);
      if (aiStorageUrl) updates.ai_report_url = aiStorageUrl;

    } catch (e) {
      console.error("turnitin-webhook: report fetch error", e);
      const fallback = payload.download_url as string | undefined;
      if (fallback) updates.report_url = fallback;
    }

    updates.completed_at = new Date().toISOString();
    if (similarityScore !== undefined) updates.similarity_score = similarityScore;
    if (aiScore !== undefined)         updates.ai_score = aiScore;

  } else if (internalStatus === "error") {
    updates.error_reason =
      (payload.error_message as string) ||
      (payload.message as string) ||
      `TurniScan scan ${status}`;
  }

  const { error } = await supabase.from("orders").update(updates).eq("id", customId);
  if (error) console.error("turnitin-webhook: DB update failed", error, "order:", customId);
  else       console.log("turnitin-webhook: order", customId, "→", internalStatus);

  return new Response("OK", { status: 200 });
});
