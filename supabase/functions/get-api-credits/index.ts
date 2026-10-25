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
      available_credits: data.available_credits,
      total_credits: data.total_credits,
      used_credits: data.used_credits,
      status: data.status,
      expiry_date: data.expiry_date,
      is_expired: data.is_expired,
    });
  } catch (err) {
    console.error("get-api-credits error:", err);
    return json({ success: false, error: { code: 500, message: "Internal error" } }, 200);
  }
});
