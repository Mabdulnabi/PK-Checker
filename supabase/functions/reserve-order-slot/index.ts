import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Manual-review orders don't go to TurniScan, so no provider check here.
// The slot is still reserved once per order, keyed by the order id.
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) return json({ success: false, error: "Unauthorized" }, 401);

    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: { user }, error: authErr } = await admin.auth.getUser(authHeader.replace("Bearer ", ""));
    if (authErr || !user) return json({ success: false, error: "Unauthorized" }, 401);

    const { order_id, grant_id } = await req.json();
    if (!order_id) return json({ success: false, error: "order_id is required" }, 400);

    const { data: order } = await admin
      .from("orders")
      .select("id, check_type")
      .eq("id", order_id)
      .eq("user_id", user.id)
      .maybeSingle();
    if (!order) return json({ success: false, error: "Order not found" }, 404);

    const service = order.check_type === "sim_only" ? "plag_only" : "plag_ai";
    const { data: reserved, error: reserveErr } = await admin.rpc("reserve_slot", {
      p_user_id: user.id,
      p_slot_type: service,
      p_idempotency_key: `order:${order_id}`,
      p_order_id: order_id,
      p_grant_id: grant_id || null,
    });
    if (reserveErr) {
      if (String(reserveErr.message).includes("NO_SLOT_AVAILABLE")) {
        return json({ success: false, code: "NO_SLOTS", slot_type: service }, 402);
      }
      throw reserveErr;
    }

    return json({ success: true, slot_type: service, reservation: reserved });
  } catch (err) {
    console.error("reserve-order-slot error:", err);
    return json({ success: false, error: "Internal server error" }, 500);
  }
});
