import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_SUBJECT = "https://pkchecker.com";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// The VAPID pair is shared with the admin push (created once, kept in Vault).
async function vapidKeys(admin: ReturnType<typeof createClient>): Promise<{ publicKey: string; privateKey: string }> {
  const { data } = await admin.rpc("push_get_vapid");
  if (data?.public && data?.private) return { publicKey: data.public, privateKey: data.private };
  throw new Error("VAPID keys missing: call admin-push init first");
}

// Customer events from the database. Same webhook secret as the admin push.
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  const { data: secret } = await admin.rpc("push_get_secret");
  if (!secret || req.headers.get("x-push-secret") !== secret) return json({ error: "forbidden" }, 403);

  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  if (typeof body.user_id !== "string") return json({ error: "user_id required" }, 400);

  const { publicKey, privateKey } = await vapidKeys(admin);
  webpush.setVapidDetails(VAPID_SUBJECT, publicKey, privateKey);

  const { data: subs } = await admin
    .from("customer_push_subscriptions")
    .select("endpoint, p256dh, auth, lang")
    .eq("user_id", body.user_id);

  let sent = 0;
  let removed = 0;
  await Promise.all((subs ?? []).map(async (s) => {
    const ar = s.lang !== "en";
    const payload = JSON.stringify({
      title: ar ? body.title_ar : body.title_en,
      body: ar ? body.body_ar : body.body_en,
      url: body.url || "/dashboard.html",
      tag: body.tag,
    });
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600 });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) {
        await admin.from("customer_push_subscriptions").delete().eq("endpoint", s.endpoint);
        removed++;
      } else {
        console.error("customer-push: send failed", code, String(e));
      }
    }
  }));
  return json({ sent, removed });
});
