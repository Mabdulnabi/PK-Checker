// pk-api/index.ts — PK Checker Developer API (phase 1).
// Same shape as TurniScan's API, so a site built for theirs works with ours:
//   POST /v1/scan/submit      send a file (or text) for checking          (1 check from the balance)
//   GET  /v1/scan/status      state, scores and download links            (free)
//   GET  /v1/scan/download    the PDF report (report_type=plagiarism|ai|highlights)  (free)
//   GET  /v1/account/balance  checks available                            (free)
// Served at https://www.pkchecker.com/v1/... (Vercel rewrite) and at
// https://<project>.supabase.co/functions/v1/pk-api/v1/....
// Auth: "Authorization: Bearer pk_live_..." (a key the customer creates on the site; only its hash is
// stored). 60 requests a minute per key. While in testing only testing accounts can use it.
// A submitted file becomes a normal order of the key's owner and goes through submit-check exactly
// like a file sent from the site (slot, queue when TurniScan is busy, refunds, reports).
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PUBLIC_BASE = "https://www.pkchecker.com/v1";
const MAX_BYTES = 50 * 1024 * 1024;
const FORMATS = ["pdf", "docx", "doc", "txt", "odt"];

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, "Content-Type": "application/json" } });
const fail = (status: number, error: string, extra: Record<string, unknown> = {}) => json({ success: false, error, ...extra }, status);

const isOn = (v: FormDataEntryValue | null) => v != null && ["1", "true", "yes", "on"].includes(String(v).toLowerCase());
const epoch = (t: string | null) => (t ? Math.floor(new Date(t).getTime() / 1000) : null);

// deno-lint-ignore no-explicit-any
type Db = any;

function publicStatus(status: string): string {
  if (status === "completed") return "Completed";
  if (["error", "failed_invalid", "rejected", "cancelled"].includes(status)) return "Failed";
  if (["run", "processing", "checking"].includes(status)) return "Processing";
  return "Pending";   // floating, uploading, pending, queued (waiting to be sent)
}

async function balanceOf(db: Db, userId: string) {
  const { data } = await db.rpc("api_balance", { p_user: userId });
  return (data || {}) as Record<string, number>;
}

// ── POST /v1/scan/submit ──
async function submit(req: Request, db: Db, userId: string, keyId: string) {
  let fd: FormData;
  try { fd = await req.formData(); } catch { return fail(400, "Send the request as multipart/form-data."); }

  let file = fd.get("file") as File | null;
  const text = fd.get("text");
  if (!(file instanceof File) || !file.size) file = null;
  if (!file && typeof text === "string" && text.trim()) {
    const words = (text.match(/\S+/g) || []).length;
    if (words < 40) return fail(400, "Text must have at least 40 words.");
    file = new File([text], "document.txt", { type: "text/plain" });
  }
  if (!file) return fail(400, "Missing required parameters: send a file or text.");
  if (file.size > MAX_BYTES) return fail(400, "The file is larger than 50 MB.");
  const ext = ((file.name.match(/\.([A-Za-z0-9]+)$/) || [])[1] || "").toLowerCase();
  if (!FORMATS.includes(ext)) return fail(400, "Unsupported file format. Use PDF, DOCX, DOC, TXT or ODT.");

  // service_type: our packages are Plagiarism + AI, so "Both" is the default here.
  const service = String(fd.get("service_type") || "Both").trim();
  const map: Record<string, string> = { "both": "sim_ai", "turnitin ai": "sim_ai", "turnitin plagiarism": "sim_only" };
  const checkType = map[service.toLowerCase()];
  if (!checkType) return fail(400, 'service_type must be "Turnitin Plagiarism", "Turnitin AI" or "Both".');

  const smallOn = isOn(fd.get("exclude_small_matches"));
  const thrRaw = Number(fd.get("small_match_threshold") ?? fd.get("exclude_words") ?? 8);
  if (smallOn && !(thrRaw >= 8 && thrRaw <= 250)) return fail(400, "small_match_threshold must be between 8 and 250.");
  const threshold = smallOn ? Math.round(thrRaw) : null;
  const customId = fd.get("custom_id") ? String(fd.get("custom_id")).slice(0, 100) : null;

  // No check left of the needed type: refused before any order is made.
  const bal = await balanceOf(db, userId);
  const left = checkType === "sim_only" ? (bal.plag_only_available ?? 0) : (bal.plag_ai_available ?? 0);
  if (left < 1) return fail(402, "Insufficient scan credits.", { available_credits: bal.available_credits ?? 0 });

  const { data: order, error: insErr } = await db.from("orders").insert({
    user_id: userId, file_name: file.name.slice(0, 200), file_size: file.size, check_type: checkType,
    status: "uploading", processing_mode: "api",
    exclude_bibliography: isOn(fd.get("exclude_biblio")) || isOn(fd.get("exclude_bibliography")),
    exclude_quotes: isOn(fd.get("exclude_quotes")), exclude_abstract: false,
    exclude_citations: isOn(fd.get("exclude_citations")),
    exclude_small_matches_word_limit: threshold,
    source: "api", api_key_id: keyId, custom_id: customId,
    ai_highlights: checkType !== "sim_only" && isOn(fd.get("ai_highlights")),
  }).select("id, display_id").single();
  if (insErr || !order) { console.error("pk-api: order insert failed", insErr?.message); return fail(500, "Could not create the order."); }

  // Sent exactly like a file from the site (submit-check), on the key owner's behalf.
  const { data: secret } = await db.rpc("get_internal_cron_secret");
  const form = new FormData();
  form.append("order_id", order.id);
  form.append("file", file, file.name);
  form.append("excludeQuotes", String(isOn(fd.get("exclude_quotes"))));
  form.append("excludeBibliography", String(isOn(fd.get("exclude_biblio")) || isOn(fd.get("exclude_bibliography"))));
  form.append("excludeCitations", String(isOn(fd.get("exclude_citations"))));
  if (threshold) form.append("excludeSmallMatchesWordLimit", String(threshold));
  let r: Record<string, unknown> = {};
  let httpStatus = 500;
  try {
    const res = await fetch(`${SUPABASE_URL}/functions/v1/submit-check`, {
      method: "POST",
      headers: { "x-internal-secret": String(secret || ""), "x-api-user": userId, Authorization: `Bearer ${SERVICE_KEY}` },
      body: form,
    });
    httpStatus = res.status;
    r = await res.json().catch(() => ({}));
  } catch (e) { console.error("pk-api: submit-check call failed", String(e)); }

  const base = { file_id: order.display_id, filename: file.name, custom_id: customId };
  if (r.success) {
    const after = await balanceOf(db, userId);
    const queued = !!r.queued;
    return json({ success: true, ...base, status: "Pending",
      message: queued ? "File received. The check service is busy; it will be sent automatically as soon as possible."
        : "File submitted successfully and queued for Turnitin scanning",
      slots_remaining: checkType === "sim_only" ? (after.plag_only_available ?? 0) : (after.plag_ai_available ?? 0) });
  }
  const code = String(r.code || "");
  if (code === "NO_SLOTS") return fail(402, "Insufficient scan credits.", base);
  if (code === "FILE_COOLDOWN") return fail(429, "This file just failed. Wait a minute before submitting it again.", base);
  if (code === "MAINTENANCE" || code === "PROVIDER_UNAVAILABLE" || httpStatus === 503)
    return fail(503, "The check service is temporarily unavailable. Please try again in a few minutes. No check was used.", base);
  return fail(httpStatus >= 400 && httpStatus < 500 ? 422 : 500, String(r.error || "The file could not be submitted for checking."), base);
}

// ── GET /v1/scan/status?file_id= ──
async function status(url: URL, db: Db, userId: string) {
  const fileId = url.searchParams.get("file_id");
  if (!fileId) return fail(400, "Missing required parameter: file_id");
  const { data: o } = await db.from("orders")
    .select("display_id, file_name, custom_id, status, similarity_score, ai_score, word_count, report_url, ai_report_url, completed_at, error_reason, purged_at, check_type, ai_highlights_url")
    .eq("user_id", userId).eq("display_id", fileId).maybeSingle();
  if (!o) return fail(404, "File not found.");
  const st = publicStatus(o.status);
  const done = st === "Completed";
  const out: Record<string, unknown> = {
    success: true, file_id: o.display_id, filename: o.file_name, custom_id: o.custom_id, status: st,
    similarity_score: o.similarity_score != null ? Number(o.similarity_score) : null,
    ai_score: o.ai_score != null ? Number(o.ai_score) : null,
    word_count: o.word_count ?? null,
    download_url: done && o.report_url && !o.purged_at ? `${PUBLIC_BASE}/scan/download?file_id=${encodeURIComponent(o.display_id)}` : null,
    ai_download_url: done && o.ai_report_url && !o.purged_at ? `${PUBLIC_BASE}/scan/download?file_id=${encodeURIComponent(o.display_id)}&report_type=ai` : null,
    ai_highlights_url: done && o.ai_highlights_url && !o.purged_at ? `${PUBLIC_BASE}/scan/download?file_id=${encodeURIComponent(o.display_id)}&report_type=highlights` : null,
    completed_at: done ? epoch(o.completed_at) : null,
  };
  if (st === "Failed") out.error = o.status === "cancelled" ? "Cancelled." : (o.error_reason || "The check could not be completed.");
  if (done && o.purged_at) out.message = "Reports are deleted 48 hours after delivery.";
  return json(out);
}

// ── GET /v1/scan/download?file_id=&report_type=plagiarism|ai ──
async function download(url: URL, db: Db, userId: string) {
  const fileId = url.searchParams.get("file_id");
  if (!fileId) return fail(400, "Missing required parameter: file_id");
  const type = (url.searchParams.get("report_type") || "plagiarism").toLowerCase();
  const hl = ["highlights", "ai_highlights"].includes(type);
  if (!hl && !["plagiarism", "similarity", "ai"].includes(type)) return fail(400, 'report_type must be "plagiarism", "ai" or "highlights".');
  const { data: o } = await db.from("orders").select("display_id, status, report_url, ai_report_url, ai_highlights_url, purged_at")
    .eq("user_id", userId).eq("display_id", fileId).maybeSingle();
  if (!o) return fail(404, "File not found.");
  if (o.status !== "completed") return fail(409, "The report is not ready yet.");
  if (o.purged_at) return fail(410, "Reports are deleted 48 hours after delivery.");
  const link = String((hl ? o.ai_highlights_url : type === "ai" ? o.ai_report_url : o.report_url) || "");
  if (!link) return fail(404, hl ? "There is no AI highlights report for this file." : type === "ai" ? "There is no AI report for this file." : "The report is not available.");
  const m = link.match(/\/storage\/(.+)$/);
  if (!m) return fail(404, "The report is not available.");
  const path = m[1].split("/").map(decodeURIComponent).join("/");
  const { data: blob, error } = await db.storage.from("order-reports").download(path);
  if (error || !blob) return fail(404, "The report is not available.");
  const name = `${o.display_id}-${hl ? "AI-Highlights" : type === "ai" ? "AI" : "Similarity"}-Report.pdf`;
  return new Response(blob, { headers: { ...CORS, "Content-Type": "application/pdf", "Content-Disposition": `attachment; filename="${name}"` } });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  try {
    const url = new URL(req.url);
    const path = (url.pathname.replace(/^.*?\/pk-api/, "") || "/").replace(/\/+$/, "");

    const key = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "").trim();
    if (!key) return fail(401, "Missing or invalid Bearer API key");
    const db = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: chk } = await db.rpc("api_key_check", { p_key: key });
    if (!chk) return fail(401, "Missing or invalid Bearer API key");
    if (chk.rate) return fail(429, "Too many requests. Standard limit is 60 req/min");
    const userId = String(chk.user_id), keyId = String(chk.key_id);

    if (path === "/v1/account/balance" && req.method === "GET") {
      const b = await balanceOf(db, userId);
      return json({ success: true, status: "Active", available_credits: b.available_credits ?? 0,
        total_credits: b.total_credits ?? 0, used_credits: b.used_credits ?? 0 });
    }
    if (path === "/v1/scan/submit" && req.method === "POST") return await submit(req, db, userId, keyId);
    if (path === "/v1/scan/status" && req.method === "GET") return await status(url, db, userId);
    if (path === "/v1/scan/download" && req.method === "GET") return await download(url, db, userId);
    return fail(404, "Unknown endpoint.");
  } catch (e) {
    console.error("pk-api error", e);
    return fail(500, "Internal server error");
  }
});
