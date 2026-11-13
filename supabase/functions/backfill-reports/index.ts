import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;
const TURNISCAN_BASE = "https://turniscan.com/v1";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// One-shot admin tool: it overwrites stored reports, so only a logged-in admin may call it.
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return new Response("Method Not Allowed", { status: 405 });

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "Unauthorized" }, 401);
  const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userErr } = await callerClient.auth.getUser();
  if (userErr || !userData?.user) return json({ error: "Unauthorized" }, 401);

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
  const { data: adminRow } = await supabase.from("admins").select("id").eq("id", userData.user.id).maybeSingle();
  if (!adminRow) return json({ error: "Forbidden" }, 403);

  const { order_id, file_id } = await req.json();
  if (!order_id || !file_id) return json({ error: "Missing order_id or file_id" }, 400);

  const result: Record<string, unknown> = {};

  for (const type of ["sim", "ai"] as const) {
    const apiUrl = type === "ai"
      ? `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(file_id)}&report_type=ai`
      : `${TURNISCAN_BASE}/scan/download?file_id=${encodeURIComponent(file_id)}`;
    const res = await fetch(apiUrl, { headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` } });
    if (!res.ok) { result[type] = `fetch failed: ${res.status} ${await res.text()}`; continue; }
    const pdf = await res.arrayBuffer();
    const path = type === "sim" ? `sim-reports/${order_id}/sim_report.pdf` : `ai-reports/${order_id}/ai_report.pdf`;
    const { error } = await supabase.storage.from("order-reports").upload(path, pdf, { contentType: "application/pdf", upsert: true });
    if (error) { result[type] = `upload failed: ${error.message}`; continue; }
    const storageUrl = `/storage/${path}`;
    const field = type === "sim" ? "report_url" : "ai_report_url";
    await supabase.from("orders").update({ [field]: storageUrl }).eq("id", order_id);
    result[type] = storageUrl;
  }

  return json(result);
});
