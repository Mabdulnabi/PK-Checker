import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const TURNISCAN_API_KEY = Deno.env.get("TURNISCAN_API_KEY")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNISCAN_BASE = "https://turniscan.com/v1";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Public endpoint. It returns only availability and the maintenance message,
// never the provider balance.
// A check type is available when: the admin switch is on, the provider account
// is active and not expired, and the provider's remaining slots are at least
// min_provider_credits.
Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  try {
    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    const { data: rows, error: rowsErr } = await admin
      .from("service_availability")
      .select("service, enabled, min_provider_credits, message_ar, message_en");
    if (rowsErr) throw rowsErr;

    let providerActive = false;
    let providerSlots = 0;
    try {
      const res = await fetch(`${TURNISCAN_BASE}/account/balance`, {
        headers: { Authorization: `Bearer ${TURNISCAN_API_KEY}` },
        signal: AbortSignal.timeout(8000),
      });
      const d = await res.json();
      providerActive = res.ok && d?.success === true && d?.status === "Active" && !d?.is_expired;
      providerSlots = Number(d?.available_credits ?? 0);
    } catch (e) {
      console.error("check-availability: provider unreachable", e);
    }

    // 'master' switches the whole API off; 'capacity' is shown when the provider has too few slots.
    const byKey: Record<string, { enabled: boolean; min_provider_credits: number; message_ar: string; message_en: string }> = {};
    for (const row of rows ?? []) byKey[row.service] = row;
    const master = byKey["master"];
    const capacity = byKey["capacity"];
    const masterOff = !!master && !master.enabled;

    type Reason = "ok" | "disabled" | "maintenance" | "provider_unavailable" | "no_provider_slots";
    const services: Record<string, unknown> = {};
    for (const key of ["plag_ai", "plag_only"]) {
      const row = byKey[key];
      if (!row) continue;
      let reason: Reason = "ok";
      if (masterOff) reason = "maintenance";
      else if (!row.enabled) reason = "disabled";
      else if (!providerActive) reason = "maintenance";
      else if (providerSlots < Number(row.min_provider_credits)) reason = "no_provider_slots";

      let msgAr: string | null = null;
      let msgEn: string | null = null;
      if (reason === "maintenance" && master) { msgAr = master.message_ar; msgEn = master.message_en; }
      else if (reason === "no_provider_slots" && capacity) { msgAr = capacity.message_ar; msgEn = capacity.message_en; }
      else if (reason === "disabled" || reason === "maintenance") { msgAr = row.message_ar; msgEn = row.message_en; }

      services[key] = {
        available: reason === "ok",
        reason,
        message_ar: reason === "ok" ? null : msgAr,
        message_en: reason === "ok" ? null : msgEn,
      };
    }

    return json({ services });
  } catch (err) {
    console.error("check-availability error:", err);
    return json({ success: false, error: "Internal error" }, 500);
  }
});
