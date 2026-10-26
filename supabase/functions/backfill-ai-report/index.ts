import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;
const TURNISCAN_BASE = "https://turniscan.com/v1";

// One-shot: download AI PDF for completed orders and store in Supabase Storage.
// Call with POST body: { "order_id": "...", "file_id": "FL-xxx" }
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  let orderId: string, fileId: string;
  try {
    const body = await req.json();
    orderId = body.order_id;
    fileId  = body.file_id;
    if (!orderId || !fileId) throw new Error("Missing order_id or file_id");
  } catch (e) {
    return new Response(JSON.stringify({ error: String(e) }), { status: 400 });
  }

  // Download AI PDF from TurniScan
  const res = await fetch(
    `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(fileId)}&report_type=ai`,
    { headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` } },
  );

  if (!res.ok) {
    const text = await res.text();
    return new Response(JSON.stringify({ error: `TurniScan ${res.status}: ${text}` }), { status: 502 });
  }

  const pdf = await res.arrayBuffer();
  const path = `ai-reports/${orderId}/ai_report.pdf`;

  const { error: uploadErr } = await supabase.storage
    .from("order-reports")
    .upload(path, pdf, { contentType: "application/pdf", upsert: true });

  if (uploadErr) {
    return new Response(JSON.stringify({ error: uploadErr.message }), { status: 500 });
  }

  const storageUrl = `${SUPABASE_URL}/storage/v1/object/order-reports/${path}`;

  const { error: dbErr } = await supabase
    .from("orders")
    .update({ ai_report_url: storageUrl })
    .eq("id", orderId);

  if (dbErr) {
    return new Response(JSON.stringify({ error: dbErr.message }), { status: 500 });
  }

  return new Response(JSON.stringify({ success: true, ai_report_url: storageUrl }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
});
