import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;

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
    const res = await fetch("https://turniscan.com/v1/account/balance", {
      headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
    });
    const data = await res.json();

    if (!res.ok || !data.success) {
      return json({ success: false, error: { code: res.status, message: data.message || "API error" } }, 200);
    }

    return json({
      success: true,
      creditsRemaining: data.available_credits,
      creditsTotal: data.total_credits,
      isActive: data.status === "Active" && !data.is_expired,
      currentConcurrent: 0,
      concurrencyLimit: 0,
    });
  } catch (err) {
    console.error("get-api-credits error:", err);
    return json({ success: false, error: { code: 500, message: "Internal error" } }, 200);
  }
});
