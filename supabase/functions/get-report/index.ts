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
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: { ...cors, "Content-Type": "application/json" } });

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authErr } = await supabase.auth.getUser(token);
    if (authErr || !user) return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: { ...cors, "Content-Type": "application/json" } });

    const url = new URL(req.url);
    let orderId = url.searchParams.get("order_id");
    let reportType = url.searchParams.get("report_type") || "ai"; // "ai" or "sim"

    if (req.method === "POST") {
      try {
        const body = await req.json();
        if (body.order_id) orderId = body.order_id;
        if (body.report_type) reportType = body.report_type;
      } catch { /* ignore */ }
    }

    if (!orderId) return new Response(JSON.stringify({ error: "Missing order_id" }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });

    // Check if admin
    const { data: profile } = await supabase.from("profiles").select("role").eq("id", user.id).single();
    const isAdmin = profile?.role === "admin";

    // Fetch order
    const orderQuery = supabase.from("orders").select("id, external_order_id, user_id, report_url, ai_report_url").eq("id", orderId);
    if (!isAdmin) orderQuery.eq("user_id", user.id);
    const { data: order, error: orderErr } = await orderQuery.single();
    if (orderErr || !order) return new Response(JSON.stringify({ error: "Order not found" }), { status: 404, headers: { ...cors, "Content-Type": "application/json" } });

    const storedUrl: string | undefined = reportType === "sim" ? order.report_url : order.ai_report_url;
    const filename = reportType === "sim" ? "sim_report.pdf" : "ai_report.pdf";

    let downloadUrl: string | null = null;
    let needsAuth = false;

    if (storedUrl && storedUrl.startsWith("proxy:")) {
      const fileId = storedUrl.replace("proxy:", "");
      downloadUrl = `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}`;
      needsAuth = true;

    } else if (storedUrl && storedUrl.includes("/storage/v1/object/")) {
      // Supabase Storage — generate signed URL and stream content
      const match = storedUrl.match(/\/storage\/v1\/object\/(?:public\/)?([^/]+)\/(.+)/);
      if (match) {
        const bucket = match[1];
        const path = decodeURIComponent(match[2]);
        const { data: signed } = await supabase.storage.from(bucket).createSignedUrl(path, 3600);
        if (signed?.signedUrl) {
          downloadUrl = signed.signedUrl;
          needsAuth = false;
        }
      }
      if (!downloadUrl) return new Response(JSON.stringify({ error: "Could not generate signed URL" }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });

    } else if (storedUrl && storedUrl.startsWith("http")) {
      downloadUrl = storedUrl;
      // TurniScan API URLs need auth; CDN download.php is public for sim, needs auth for AI
      needsAuth = storedUrl.includes("/v1/") || (reportType === "ai" && storedUrl.includes("download.php"));

    } else if (order.external_order_id) {
      downloadUrl = `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(order.external_order_id)}`;
      needsAuth = true;
    }

    if (!downloadUrl) return new Response(JSON.stringify({ error: "Report not ready" }), { status: 404, headers: { ...cors, "Content-Type": "application/json" } });

    const fetchHeaders: Record<string, string> = {};
    if (needsAuth) fetchHeaders["Authorization"] = `Bearer ${TURNISCAN_API_KEY}`;
    const tsRes = await fetch(downloadUrl, { headers: fetchHeaders });

    if (!tsRes.ok) {
      const errText = await tsRes.text();
      return new Response(errText, { status: tsRes.status, headers: { ...cors, "Content-Type": "application/json" } });
    }

    const contentType = tsRes.headers.get("Content-Type") || "application/pdf";
    const disposition = tsRes.headers.get("Content-Disposition") || `attachment; filename="${filename}"`;

    return new Response(tsRes.body, {
      status: 200,
      headers: { ...cors, "Content-Type": contentType, "Content-Disposition": disposition },
    });

  } catch (err) {
    console.error("get-report error:", err);
    return new Response(JSON.stringify({ error: "Internal server error" }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }
});
