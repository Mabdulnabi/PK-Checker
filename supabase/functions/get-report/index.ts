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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    // Auth
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: { ...cors, "Content-Type": "application/json" } });

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authErr } = await supabase.auth.getUser(token);
    if (authErr || !user) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: { ...cors, "Content-Type": "application/json" } });

    const url = new URL(req.url);
    let orderId = url.searchParams.get("order_id");
    let reportType = url.searchParams.get("report_type") || "ai";
    // Also accept POST body (avoids ad blocker blocking UUID in URL path)
    if (req.method === "POST") {
      try {
        const body = await req.json();
        if (body.order_id) orderId = body.order_id;
        if (body.report_type) reportType = body.report_type;
      } catch { /* ignore, fall back to query params */ }
    }

    if (!orderId) return new Response(JSON.stringify({ error: "Missing order_id" }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });

    // Fetch order (verify ownership)
    const { data: order, error: orderErr } = await supabase
      .from("orders")
      .select("id, external_order_id, user_id, ai_report_url")
      .eq("id", orderId)
      .eq("user_id", user.id)
      .single();

    if (orderErr || !order) return new Response(JSON.stringify({ error: "Order not found" }), { status: 404, headers: { ...cors, "Content-Type": "application/json" } });

    // Extract file_id from proxy marker or external_order_id
    let fileId: string | null = null;
    if (order.ai_report_url && order.ai_report_url.startsWith("proxy:")) {
      fileId = order.ai_report_url.replace("proxy:", "");
    } else {
      fileId = order.external_order_id;
    }

    if (!fileId) return new Response(JSON.stringify({ error: "Report not ready" }), { status: 404, headers: { ...cors, "Content-Type": "application/json" } });

    // Proxy the download from TurniScan
    const tsRes = await fetch(`${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}&report_type=${reportType}`, {
      headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
    });

    if (!tsRes.ok) {
      const errText = await tsRes.text();
      return new Response(errText, { status: tsRes.status, headers: { ...cors, "Content-Type": "application/json" } });
    }

    // Stream the PDF back
    const contentType = tsRes.headers.get("Content-Type") || "application/pdf";
    const disposition = tsRes.headers.get("Content-Disposition") || `attachment; filename="${reportType}_report.pdf"`;

    return new Response(tsRes.body, {
      status: 200,
      headers: {
        ...cors,
        "Content-Type": contentType,
        "Content-Disposition": disposition,
      },
    });

  } catch (err) {
    console.error("download-report error:", err);
    return new Response(JSON.stringify({ error: "Internal server error" }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
