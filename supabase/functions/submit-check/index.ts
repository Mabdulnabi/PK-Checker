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

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ success: false, error: "Unauthorized" }, 401);

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const token = authHeader.replace("Bearer ", "");
    const { data: { user }, error: authErr } = await supabase.auth.getUser(token);
    if (authErr || !user) return json({ success: false, error: "Unauthorized" }, 401);

    const fd = await req.formData();
    const orderId    = fd.get("order_id") as string;
    const file       = fd.get("file") as File | null;
    const exQuotes   = fd.get("excludeQuotes") === "true";
    const exBiblio   = fd.get("excludeBibliography") === "true";
    const exCit      = fd.get("excludeCitations") === "true";
    const exSmallLim = fd.get("excludeSmallMatchesWordLimit") as string | null;

    if (!orderId || !file) return json({ success: false, error: "Missing order_id or file" }, 400);

    // Verify order belongs to user
    const { data: order, error: orderErr } = await supabase
      .from("orders")
      .select("id, check_type")
      .eq("id", orderId)
      .eq("user_id", user.id)
      .single();
    if (orderErr || !order) return json({ success: false, error: "Order not found" }, 404);

    // Build TurniScan submission form
    const tsForm = new FormData();
    tsForm.append("file", file, file.name);
    tsForm.append("custom_id", orderId);

    // service_type: sim_only → Plagiarism only, sim_ai → Both
    const checkType = (order as { check_type: string }).check_type;
    tsForm.append("service_type", checkType === "sim_only" ? "Turnitin Plagiarism" : "Both");

    if (exQuotes)  tsForm.append("exclude_quotes", "1");
    if (exBiblio)  tsForm.append("exclude_biblio", "1");
    if (exCit)     tsForm.append("exclude_citations", "1");
    if (exSmallLim) {
      tsForm.append("exclude_small_matches", "1");
      tsForm.append("small_match_threshold", exSmallLim);
    }

    // Webhook for instant completion callback
    tsForm.append("webhook_url", `${SUPABASE_URL}/functions/v1/turnitin-webhook`);

    // Submit to TurniScan
    const tsRes = await fetch(`${TURNISCAN_BASE}/scan/submit`, {
      method: "POST",
      headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
      body: tsForm,
    });
    const tsData = await tsRes.json();

    if (!tsRes.ok || !tsData.success) {
      const errMsg = (tsData.message as string) || "TurniScan submission failed";
      await supabase.from("orders").update({ status: "error", error_reason: errMsg }).eq("id", orderId);
      return json({ success: false, error: errMsg }, 422);
    }

    const fileId: string = tsData.file_id;

    // Persist external ID and advance status to 'run'
    await supabase.from("orders").update({
      external_order_id: fileId,
      status: "run",
    }).eq("id", orderId);

    return json({ success: true, externalOrderId: fileId });
  } catch (err) {
    console.error("submit-check error:", err);
    return json({ success: false, error: "Internal server error" }, 500);
  }
});
