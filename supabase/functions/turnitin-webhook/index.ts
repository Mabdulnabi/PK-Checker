import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;
const TURNISCAN_BASE = "https://turniscan.com/v1";

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

  if (internalStatus === "completed" && fileId) {
    // Fetch status from TurniScan to get the direct CDN download_url.
    // The webhook payload's download_url is the API endpoint (requires auth),
    // while the status endpoint returns the direct CDN URL usable in a browser.
    try {
      const tsStatus = await fetch(`${TURNISCAN_BASE}/scan/status?file_id=${fileId}`, {
        headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
      });
      const tsData = await tsStatus.json();
      if (tsStatus.ok && tsData.success && tsData.download_url) {
        // Follow the redirect to get the actual public CDN URL (no auth needed)
        const simRes = await fetch(`${TURNISCAN_BASE}/scan/download?file_id=${fileId}`, {
          headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
          redirect: "manual",
        });
        updates.report_url = simRes.headers.get("location") || tsData.download_url;

        // Try to get AI CDN URL from status response fields
        const aiCdnUrl: string | null =
          (tsData.ai_download_url as string | undefined) ||
          (tsData.ai_report_url as string | undefined) ||
          null;
        if (aiCdnUrl) updates.ai_report_url = aiCdnUrl;
      }
    } catch (e) {
      console.error("turnitin-webhook: failed to fetch status from TurniScan", e);
      // Fall back to the webhook's own download_url
      const fallbackUrl = payload.download_url as string | undefined;
      if (fallbackUrl) updates.report_url = fallbackUrl;
    }

    updates.completed_at = new Date().toISOString();
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
