import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_SUBJECT = "https://pkchecker.com";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Access-Control-Allow-Origin": "*" },
  });

const fromB64u = (s: string) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
const toB64u = (u: Uint8Array) => btoa(String.fromCharCode(...u)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

// VAPID keys live in Vault. The first call creates the pair; the private key never leaves the database.
async function vapidKeys(admin: ReturnType<typeof createClient>): Promise<{ publicKey: string; privateKey: string }> {
  const { data } = await admin.rpc("push_get_vapid");
  if (data?.public && data?.private) return { publicKey: data.public, privateKey: data.private };

  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const jwk = await crypto.subtle.exportKey("jwk", pair.privateKey) as JsonWebKey;
  const x = fromB64u(jwk.x!);
  const y = fromB64u(jwk.y!);
  const point = new Uint8Array(65);
  point[0] = 4;
  point.set(x, 1);
  point.set(y, 33);
  const publicKey = toB64u(point);
  const privateKey = jwk.d!;
  await admin.rpc("push_set_vapid", { p_public: publicKey, p_private: privateKey });

  const again = await admin.rpc("push_get_vapid");
  return { publicKey: again.data?.public ?? publicKey, privateKey: again.data?.private ?? privateKey };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "content-type, x-push-secret" } });
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Public key for the browser (not a secret).
  if (req.method === "GET") {
    const { publicKey } = await vapidKeys(admin);
    return json({ publicKey });
  }

  // Events come from the database and must carry the shared webhook secret.
  const { data: secret } = await admin.rpc("push_get_secret");
  if (!secret || req.headers.get("x-push-secret") !== secret) return json({ error: "forbidden" }, 403);

  const body = await req.json().catch(() => ({} as Record<string, unknown>));
  const { publicKey, privateKey } = await vapidKeys(admin);
  if (body.action === "init") return json({ ok: true });

  webpush.setVapidDetails(VAPID_SUBJECT, publicKey, privateKey);
  const payload = JSON.stringify({ title: body.title, body: body.body, url: body.url, tag: body.tag });

  const { data: subs } = await admin.from("admin_push_subscriptions").select("endpoint, p256dh, auth");
  let sent = 0;
  let removed = 0;
  await Promise.all((subs ?? []).map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 3600 });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) {
        // The device unsubscribed or the browser dropped it: forget it.
        await admin.from("admin_push_subscriptions").delete().eq("endpoint", s.endpoint);
        removed++;
      } else {
        console.error("admin-push: send failed", code, String(e));
      }
    }
  }));
  return json({ sent, removed });
});
