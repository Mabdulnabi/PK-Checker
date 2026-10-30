import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Exposes the TurniScan account balance, so only admins may call it.
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

    const callerClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) return json({ success: false, error: "Unauthorized" }, 401);

    const adminClient = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);
    const { data: adminRow } = await adminClient
      .from("admins")
      .select("id")
      .eq("id", userData.user.id)
      .maybeSingle();
    if (!adminRow) return json({ success: false, error: "Forbidden" }, 403);

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
