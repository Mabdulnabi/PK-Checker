import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "order-reports";
const SOURCE_BUCKET = "order-source-files";
const SOURCE_RETENTION_MS = 48 * 60 * 60 * 1000;
const FINAL_STATUSES = ["completed", "error", "rejected", "failed_invalid", "cancelled"];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Removes an order's report files from storage, then marks the order purged.
// The order row stays, for billing history.
async function purgeOrder(admin: ReturnType<typeof createClient>, orderId: string): Promise<number> {
  // The customer's original upload (source copy) goes too.
  const { data: srcRow } = await admin.from("orders").select("source_file_path").eq("id", orderId).maybeSingle();
  if (srcRow?.source_file_path) {
    const { error: srcErr } = await admin.storage.from(SOURCE_BUCKET).remove([srcRow.source_file_path]);
    if (srcErr) throw srcErr;
    const { error: srcDbErr } = await admin.from("orders").update({ source_file_path: null }).eq("id", orderId);
    if (srcDbErr) throw srcDbErr;
  }
  const paths: string[] = [];
  for (const folder of ["sim-reports", "ai-reports"]) {
    const { data, error } = await admin.storage.from(BUCKET).list(`${folder}/${orderId}`, { limit: 100 });
    if (error) throw error;
    for (const f of data ?? []) {
      if (f.name) paths.push(`${folder}/${orderId}/${f.name}`);
    }
  }
  if (paths.length) {
    const { error } = await admin.storage.from(BUCKET).remove(paths);
    if (error) throw error;
  }
  const { error: markErr } = await admin.rpc("mark_order_purged", { p_order_id: orderId });
  if (markErr) throw markErr;
  return paths.length;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

  try {
    const body = await req.json();
    const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

    // Scheduled purge: only touches orders already past 48 hours.
    if (body.action === "purge_due") {
      // Only the database's own scheduler may call this (it sends the internal secret).
      const sent = req.headers.get("x-internal-secret") ?? "";
      const { data: expected } = await admin.rpc("get_internal_cron_secret");
      if (!expected || sent !== expected) return json({ success: false, error: "Forbidden" }, 403);
      const { data: due, error } = await admin.rpc("orders_due_for_purge");
      if (error) throw error;
      let purgedFiles = 0;
      for (const row of due ?? []) {
        purgedFiles += await purgeOrder(admin, row.id);
      }
      return json({ success: true, orders: (due ?? []).length, files: purgedFiles });
    }

    // Scheduled cleanup of the original uploads older than 48 hours (internal secret, as purge_due).
    if (body.action === "purge_sources") {
      const sent = req.headers.get("x-internal-secret") ?? "";
      const { data: expected } = await admin.rpc("get_internal_cron_secret");
      if (!expected || sent !== expected) return json({ success: false, error: "Forbidden" }, 403);
      const cutoff = new Date(Date.now() - SOURCE_RETENTION_MS).toISOString();
      const { data: rows, error } = await admin
        .from("orders")
        .select("id, source_file_path")
        .not("source_file_path", "is", null)
        .lt("submitted_at", cutoff)
        .limit(500);
      if (error) throw error;
      let removed = 0;
      for (const r of rows ?? []) {
        const { error: rmErr } = await admin.storage.from(SOURCE_BUCKET).remove([r.source_file_path]);
        if (rmErr) { console.error("manage-files: source remove failed", r.id, rmErr.message); continue; }
        const { error: upErr } = await admin.from("orders").update({ source_file_path: null }).eq("id", r.id);
        if (upErr) { console.error("manage-files: source path not cleared", r.id, upErr.message); continue; }
        removed++;
      }
      return json({ success: true, found: (rows ?? []).length, removed });
    }

    // Customer delete: only their own order, and only once the check has finished.
    if (body.action === "delete") {
      const authHeader = req.headers.get("Authorization");
      if (!authHeader) return json({ success: false, error: "Unauthorized" }, 401);
      const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
        global: { headers: { Authorization: authHeader } },
      });
      const { data: userData, error: userErr } = await caller.auth.getUser();
      if (userErr || !userData?.user) return json({ success: false, error: "Unauthorized" }, 401);

      const { data: order } = await admin
        .from("orders")
        .select("id, user_id, status, purged_at")
        .eq("id", body.order_id)
        .maybeSingle();
      if (!order || order.user_id !== userData.user.id) return json({ success: false, error: "Not found" }, 404);
      if (order.purged_at) return json({ success: true, alreadyDeleted: true });
      if (!FINAL_STATUSES.includes(order.status)) {
        return json({ success: false, code: "STILL_PROCESSING" }, 409);
      }

      await purgeOrder(admin, order.id);
      return json({ success: true });
    }

    return json({ success: false, error: "Unknown action" }, 400);
  } catch (err) {
    console.error("manage-files error:", err);
    return json({ success: false, error: "Internal server error" }, 500);
  }
});
