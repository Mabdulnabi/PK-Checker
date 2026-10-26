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

function mapStatus(s: string): string {
  const l = s.toLowerCase();
  if (l === "completed") return "completed";
  if (l === "failed" || l === "rejected") return "error";
  if (l === "processing") return "processing";
  return "run";
}

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
  console.log(`check-status: ${reportType} fetch status=`, res.status);
  if (!res.ok) {
    console.error(`check-status: ${reportType} fetch failed`, res.status, await res.text());
    return null;
  }
  const pdf = await res.arrayBuffer();
  const { error } = await supabase.storage
    .from("order-reports")
    .upload(storagePath, pdf, { contentType: "application/pdf", upsert: true });
  if (error) { console.error(`check-status: ${reportType} upload failed`, error.message); return null; }
  console.log(`check-status: ${reportType} uploaded to`, storagePath);
  return `/storage/${storagePath}`;
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
      .select("id, external_order_id, status, user_id")
      .eq("id", orderId).eq("user_id", user.id).single();
    if (orderErr || !order) return json({ success: false, error: "Order not found" }, 404);

    const fileId = (order as { external_order_id: string }).external_order_id;
    if (!fileId) return json({ success: false, polled: false, error: "No external_order_id yet" });

    const tsRes = await fetch(`${TURNISCAN_BASE}/scan/status?file_id=${encodeURIComponent(fileId)}`, {
      headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
    });
    const tsData = await tsRes.json();
    if (!tsRes.ok || !tsData.success) {
      return json({ success: false, polled: false, error: tsData.message || "TurniScan status check failed" });
    }

    const internalStatus = mapStatus(tsData.status as string);
    const updates: Record<string, unknown> = { status: internalStatus };
    const reports: { similarity?: { downloadUrl: string }; ai?: { downloadUrl: string } } = {};

    if (internalStatus === "completed") {
      const simUrl = await fetchAndStore(supabase, fileId, `sim-reports/${orderId}/sim_report.pdf`, "sim");
      if (simUrl) { updates.report_url = simUrl; reports.similarity = { downloadUrl: simUrl }; }

      const aiUrl = await fetchAndStore(supabase, fileId, `ai-reports/${orderId}/ai_report.pdf`, "ai");
      if (aiUrl) { updates.ai_report_url = aiUrl; reports.ai = { downloadUrl: aiUrl }; }

      updates.completed_at = new Date().toISOString();
      if (tsData.similarity_score !== undefined) updates.similarity_score = tsData.similarity_score;
      if (tsData.ai_score !== undefined)         updates.ai_score = tsData.ai_score;

    } else if (internalStatus === "error") {
      updates.error_reason =
        (tsData.error_message as string) || (tsData.message as string) || `TurniScan: ${tsData.status}`;
    }

    await supabase.from("orders").update(updates).eq("id", orderId);

    return json({ success: true, polled: true, status: internalStatus, reports,
      ...(internalStatus === "error" ? { error: updates.error_reason } : {}) });

  } catch (err) {
    console.error("check-status error:", err);
    return json({ success: false, polled: false, error: "Internal server error" }, 500);
  }
});
