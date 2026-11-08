import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PIXEL_ID = "1174873375104920";
const GRAPH_VERSION = "v21.0";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

async function sha256Hex(text: string): Promise<string> {
  const data = new TextEncoder().encode(text.trim().toLowerCase());
  const digest = await crypto.subtle.digest("SHA-256", data);
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

// Server-side Meta events. Called only by the database (same shared secret as the admin push).
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: secret } = await admin.rpc("push_get_secret");
  if (!secret || req.headers.get("x-push-secret") !== secret) return json({ error: "forbidden" }, 403);

  const { data: token } = await admin.rpc("meta_get_token");
  if (!token) return json({ error: "no token" }, 500);

  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  const userData: Record<string, unknown> = {};
  if (typeof body.email === "string" && body.email) userData.em = [await sha256Hex(body.email)];
  if (typeof body.external_id === "string" && body.external_id) userData.external_id = [await sha256Hex(body.external_id)];

  const event: Record<string, unknown> = {
    event_name: body.event_name,
    event_time: Math.floor(Date.now() / 1000),
    event_id: body.event_id,
    action_source: "website",
    event_source_url: body.event_source_url || "https://pkchecker.com/dashboard.html",
    user_data: userData,
  };
  if (body.value != null) event.custom_data = { value: Number(body.value), currency: body.currency || "EGP" };

  const res = await fetch(`https://graph.facebook.com/${GRAPH_VERSION}/${PIXEL_ID}/events?access_token=${encodeURIComponent(token as string)}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ data: [event] }),
  });
  const out = await res.text();
  if (!res.ok) console.error("meta-capi: graph error", res.status, out.slice(0, 300));
  return json({ status: res.status }, res.ok ? 200 : 502);
});
