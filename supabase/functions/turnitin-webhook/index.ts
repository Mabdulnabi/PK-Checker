import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// No JWT verification — TurniScan calls this endpoint without a Supabase token.
// Auth is implicit: only TurniScan knows this URL (passed as webhook_url on submit).
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return new Response("Bad Request", { status: 400 });
  }

  const fileId       = payload.file_id as string | undefined;
  const customId     = payload.custom_id as string | undefined; // our order ID
  const status       = (payload.status as string) || "";
  const downloadUrl  = payload.download_url as string | undefined;
  const similarityScore = payload.similarity_score as number | undefined;
  const aiScore      = payload.ai_score as number | undefined;

  if (!customId) {
    console.error("turnitin-webhook: missing custom_id in payload", payload);
    return new Response("OK", { status: 200 }); // ack to prevent retries
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  // Map TurniScan status → internal phase
  const s = status.toLowerCase();
  let internalStatus: string;
  if (s === "completed") {
    internalStatus = "completed";
  } else if (s === "failed" || s === "rejected") {
    internalStatus = "error";
  } else {
    internalStatus = "processing";
  }

  const updates: Record<string, unknown> = { status: internalStatus };

  if (fileId) updates.external_order_id = fileId;

  if (internalStatus === "completed") {
    if (downloadUrl) updates.report_url = downloadUrl;
    // AI report is the same file viewed with report_type=ai
    if (fileId) {
      updates.ai_report_url = `https://turniscan.com/v1/scan/download?file_id=${fileId}&report_type=ai`;
    }
    if (similarityScore !== undefined) updates.similarity_score = similarityScore;
    if (aiScore !== undefined) updates.ai_score = aiScore;
  } else if (internalStatus === "error") {
    const errMsg =
      (payload.error_message as string) ||
      (payload.message as string) ||
      `TurniScan scan ${status}`;
    updates.error_reason = errMsg;
  }

  const { error } = await supabase
    .from("orders")
    .update(updates)
    .eq("id", customId);

  if (error) {
    console.error("turnitin-webhook: DB update failed", error, "| order:", customId);
  } else {
    console.log("turnitin-webhook: order", customId, "→", internalStatus);
  }

  // Always 200 so TurniScan doesn't retry
  return new Response("OK", { status: 200 });
});
