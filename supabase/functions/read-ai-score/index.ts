import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { getDocumentProxy, extractText } from "npm:unpdf@1";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Read-only check: reads the AI report stored for an order and returns what its
// page 2 says. It never writes to storage or to the orders table.
Deno.serve(async (req: Request) => {
  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

  try {
    const url = new URL(req.url);
    const orderId = url.searchParams.get("order_id");
    if (!orderId) return json({ error: "Missing order_id" }, 400);

    const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: order, error: orderErr } = await supabase
      .from("orders")
      .select("id, ai_report_url, ai_score")
      .eq("id", orderId)
      .maybeSingle();
    if (orderErr || !order) return json({ error: "Order not found" }, 404);
    if (!order.ai_report_url) return json({ error: "No AI report stored" }, 404);

    const path = String(order.ai_report_url).replace("/storage/", "");
    const { data, error } = await supabase.storage.from("order-reports").download(path);
    if (error || !data) return json({ error: "Could not read stored file", path }, 500);

    const pdf = await getDocumentProxy(new Uint8Array(await data.arrayBuffer()));
    const { text } = await extractText(pdf, { mergePages: false });
    const pages = text as string[];
    const page2 = String(pages[1] ?? "");
    const m = page2.match(/(\d{1,3}(?:\.\d+)?)\s*%\s*detected as AI/i);
    const hidden = /\*\s*%\s*detected as AI/i.test(page2);

    const markers = pages
      .map((pg, i) => ({ page: i + 1, ai: /detected as AI/i.test(pg), sim: /Overall Similarity/i.test(pg) }))
      .filter((x) => x.ai || x.sim);

    return json({
      order_id: order.id,
      path,
      pages: pages.length,
      reads: m ? { kind: "value", value: Number(m[1]) } : hidden ? { kind: "hidden" } : { kind: "unknown" },
      stored_ai_score: order.ai_score,
      markers,
      page2_start: page2.slice(0, 300),
    });
  } catch (e) {
    console.error("read-ai-score error:", String(e));
    return json({ error: "Internal server error" }, 500);
  }
});
