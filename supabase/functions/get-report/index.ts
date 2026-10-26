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
    // Also accept POST body (avoids ad blocker blocking UUID in URL path)
    if (req.method === "POST") {
      try {
        const body = await req.json();
        if (body.order_id) orderId = body.order_id;
      } catch { /* ignore, fall back to query params */ }
    }

    if (!orderId) return new Response(JSON.stringify({ error: "Missing order_id" }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });

    // Check if user is admin
    const { data: profile } = await supabase
      .from("profiles")
      .select("role")
      .eq("id", user.id)
      .single();
    const isAdmin = profile?.role === "admin";

    // Fetch order — admins can access any order, users only their own
    const orderQuery = supabase
      .from("orders")
      .select("id, external_order_id, user_id, ai_report_url")
      .eq("id", orderId);
    if (!isAdmin) orderQuery.eq("user_id", user.id);
    const { data: order, error: orderErr } = await orderQuery.single();

    if (orderErr || !order) return new Response(JSON.stringify({ error: "Order not found" }), { status: 404, headers: { ...cors, "Content-Type": "application/json" } });

    // Determine the actual download URL and whether it needs an API key
    let downloadUrl: string | null = null;
    let needsAuth = false;
    const storedUrl: string | undefined = order.ai_report_url;

    if (storedUrl && storedUrl.startsWith("proxy:")) {
      // proxy:FL-xxx → API endpoint, needs Bearer auth
      const fileId = storedUrl.replace("proxy:", "");
      downloadUrl = `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}`;
      needsAuth = true;
    } else if (storedUrl && storedUrl.includes("/storage/v1/object/")) {
      // Supabase Storage URL — generate a signed URL server-side
      const match = storedUrl.match(/\/storage\/v1\/object\/(?:public\/)?([^/]+)\/(.+)/);
      if (match) {
        const bucket = match[1];
        const path = decodeURIComponent(match[2]);
        const { data: signed } = await supabase.storage.from(bucket).createSignedUrl(path, 3600);
        if (signed?.signedUrl) {
          return Response.redirect(signed.signedUrl, 302);
        }
      }
      return new Response(JSON.stringify({ error: "Could not generate signed URL" }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
    } else if (storedUrl && storedUrl.startsWith("http")) {
      // Full URL already stored:
      // - download.php URLs are public CDN (no auth needed)
      // - /v1/ URLs are API endpoints (need auth)
      downloadUrl = storedUrl;
      needsAuth = storedUrl.includes("/v1/");
    } else if (order.external_order_id) {
      // Fallback: construct from file_id
      downloadUrl = `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(order.external_order_id)}`;
      needsAuth = true;
    }

    if (!downloadUrl) return new Response(JSON.stringify({ error: "Report not ready" }), { status: 404, headers: { ...cors, "Content-Type": "application/json" } });

    // Proxy the download from TurniScan
    const fetchHeaders: Record<string, string> = {};
    if (needsAuth) fetchHeaders["Authorization"] = `Bearer ${TURNISCAN_API_KEY}`;
    const tsRes = await fetch(downloadUrl, { headers: fetchHeaders });

    if (!tsRes.ok) {
      const errText = await tsRes.text();
      return new Response(errText, { status: tsRes.status, headers: { ...cors, "Content-Type": "application/json" } });
    }

    // Stream the PDF back
    const contentType = tsRes.headers.get("Content-Type") || "application/pdf";
    const disposition = tsRes.headers.get("Content-Disposition") || `attachment; filename="ai_report.pdf"`;

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
