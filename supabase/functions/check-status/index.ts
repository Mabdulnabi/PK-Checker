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

// Maps TurniScan status string → internal phase stored in orders.status
function mapStatus(s: string): string {
  const l = s.toLowerCase();
  if (l === "completed") return "completed";
  if (l === "failed" || l === "rejected") return "error";
  if (l === "processing") return "processing";
  return "run"; // Pending / Queued / unknown → keep polling
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  try {
    // Auth
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ success: false, error: "Unauthorized" }, 401);

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authErr } = await supabase.auth.getUser(token);
    if (authErr || !user) return json({ success: false, error: "Unauthorized" }, 401);

    // Order ID from query string
    const url = new URL(req.url);
    const orderId = url.searchParams.get("order_id");
    if (!orderId) return json({ success: false, error: "Missing order_id" }, 400);

    // Fetch order (verify belongs to user)
    const { data: order, error: orderErr } = await supabase
      .from("orders")
      .select("id, external_order_id, status, user_id")
      .eq("id", orderId)
      .eq("user_id", user.id)
      .single();

    if (orderErr || !order) return json({ success: false, error: "Order not found" }, 404);

    const fileId = (order as { external_order_id: string }).external_order_id;
    if (!fileId) return json({ success: false, polled: false, error: "No external_order_id yet" });

    // Poll TurniScan
    const tsRes = await fetch(`${TURNISCAN_BASE}/scan/status?file_id=${encodeURIComponent(fileId)}`, {
      headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
    });
    const tsData = await tsRes.json();

    if (!tsRes.ok || !tsData.success) {
      return json({ success: false, polled: false, error: tsData.message || "TurniScan status check failed" });
    }

    const internalStatus = mapStatus(tsData.status as string);
    const updates: Record<string, unknown> = { status: internalStatus };

    let reports: { similarity?: { downloadUrl: string }; ai?: { downloadUrl: string } } = {};

    if (internalStatus === "completed") {
      // Follow redirects to get actual public CDN URLs (no auth needed by browser)
      const simRes = await fetch(`${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}`, {
        headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
        redirect: "manual",
      });
      const simCdnUrl = simRes.headers.get("location") || tsData.download_url;

      const aiRes = await fetch(`${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}&report_type=ai`, {
        headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
        redirect: "manual",
      });
      const aiCdnUrl = aiRes.headers.get("location");

      if (simCdnUrl) {
        updates.report_url = simCdnUrl;
        reports.similarity = { downloadUrl: simCdnUrl };
      }
      if (aiCdnUrl) {
        updates.ai_report_url = aiCdnUrl;
        reports.ai = { downloadUrl: aiCdnUrl };
      }
      updates.completed_at = new Date().toISOString();

      if (tsData.similarity_score !== undefined) updates.similarity_score = tsData.similarity_score;
      if (tsData.ai_score !== undefined) updates.ai_score = tsData.ai_score;

    } else if (internalStatus === "error") {
      const errMsg = (tsData.error_message as string) || (tsData.message as string) || `TurniScan: ${tsData.status}`;
      updates.error_reason = errMsg;
    }

    // Persist to DB
    await supabase.from("orders").update(updates).eq("id", orderId);

    return json({
      success: true,
      polled: true,
      status: internalStatus,
      reports,
      ...(internalStatus === "error" ? { error: updates.error_reason } : {}),
    });

  } catch (err) {
    console.error("check-status error:", err);
    return json({ success: false, polled: false, error: "Internal server error" }, 500);
  }
});
