// Supabase Edge Function: notify-email
// Triggered by a Database Webhook on INSERT into public.notifications.
// Emails each notification over SMTP (Gmail, college mail, etc.).
//
// Security: the request body is NOT trusted. Only the notification id is
// taken from it; the title, message and recipient are re-read from the
// database with the service-role key. A notification is claimed (emailed_at
// set) before sending, so each one is emailed at most once even if the
// webhook is replayed. Anyone who calls this function directly can therefore
// only cause a real, not-yet-sent notification to be delivered to its real
// recipient. Arbitrary emails cannot be sent this way.
//
// Required secrets (Dashboard → Edge Functions → Secrets, or `supabase secrets set`):
//   SMTP_HOST   e.g. smtp.gmail.com
//   SMTP_PORT   465 (implicit TLS) or 587 (STARTTLS)
//   SMTP_USER   the mailbox that sends the mail
//   SMTP_PASS   its password / Gmail "App password"
//   SMTP_FROM   e.g. Robotics and Automation Club <yourclub@gmail.com>
//   PORTAL_URL  (optional) link shown in the email, e.g. https://your-portal.netlify.app
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";

// Notifications older than this are never emailed (protects old rows).
const MAX_AGE_MS = 24 * 60 * 60 * 1000;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

const reply = (body: string, status = 200) => new Response(body, { status });

function requireEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing secret ${name}`);
  return v;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply("method not allowed", 405);

  let payload: any;
  try {
    payload = await req.json();
  } catch {
    return reply("bad json", 400);
  }
  const id = payload?.record?.id;
  if (payload?.type !== "INSERT" || typeof id !== "string" || !UUID.test(id)) return reply("ignored");

  const db = createClient(requireEnv("SUPABASE_URL"), requireEnv("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false },
  });

  // Atomically claim the notification. Only one caller can win.
  const { data: rec, error: claimErr } = await db
    .from("notifications")
    .update({ emailed_at: new Date().toISOString() })
    .eq("id", id)
    .is("emailed_at", null)
    .gte("created_at", new Date(Date.now() - MAX_AGE_MS).toISOString())
    .select("id, recipient, title, message")
    .maybeSingle();
  if (claimErr) {
    console.error("claim failed:", claimErr);
    return reply("claim failed", 500);
  }
  if (!rec) return reply("already sent, too old, or not found");

  const release = () => db.from("notifications").update({ emailed_at: null }).eq("id", id);

  let client: SMTPClient | null = null;
  try {
    // Work out who should receive the email
    let to: string[] = [];
    if (rec.recipient === "admin") {
      const { data, error } = await db.from("profiles").select("email").eq("role", "admin");
      if (error) throw error;
      to = (data ?? []).map((r: { email: string }) => r.email);
    } else if (UUID.test(rec.recipient)) {
      const { data, error } = await db.from("profiles").select("email").eq("id", rec.recipient).maybeSingle();
      if (error) throw error;
      if (data?.email) to = [data.email];
    }
    if (!to.length) return reply("no recipient");

    const port = Number(Deno.env.get("SMTP_PORT") ?? "465");
    const from = Deno.env.get("SMTP_FROM") ?? requireEnv("SMTP_USER");
    const portal = Deno.env.get("PORTAL_URL") ?? "";

    client = new SMTPClient({
      connection: {
        hostname: requireEnv("SMTP_HOST"),
        port,
        tls: port === 465, // 587 upgrades with STARTTLS automatically
        auth: { username: requireEnv("SMTP_USER"), password: requireEnv("SMTP_PASS") },
      },
    });

    const subject = `[RAC Inventory] ${rec.title}`;
    const text = `${rec.message}\n\n${portal ? "Open the portal: " + portal + "\n\n" : ""}— Robotics and Automation Club, Kumaraguru College`;
    const html = `<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;color:#10243a">
  <div style="background:#073b70;color:#fff;padding:16px 20px;border-radius:10px 10px 0 0;font-weight:700">Robotics and Automation Club · Inventory Portal</div>
  <div style="border:1px solid #e2eaf2;border-top:0;padding:22px 20px;border-radius:0 0 10px 10px">
    <h2 style="margin:0 0 12px;font-size:18px">${esc(rec.title)}</h2>
    <p style="font-size:14px;line-height:1.6;margin:0 0 18px">${esc(rec.message)}</p>
    ${portal ? `<a href="${esc(portal)}" style="background:#07529b;color:#fff;text-decoration:none;padding:10px 16px;border-radius:8px;font-size:13px;font-weight:700">Open the portal</a>` : ""}
    <p style="font-size:11px;color:#66788c;margin:22px 0 0">This is an automatic message from the club inventory system.</p>
  </div></div>`;

    // one email per recipient so addresses are not exposed to each other
    const failed: string[] = [];
    for (const addr of to) {
      try {
        await client.send({ from, to: addr, subject, content: text, html });
      } catch (e) {
        console.error(`send to ${addr} failed:`, e);
        failed.push(addr);
      }
    }
    if (failed.length === to.length) {
      await release(); // nothing went out — allow a retry
      return reply("all sends failed", 500);
    }
    return reply(`sent to ${to.length - failed.length}/${to.length}`);
  } catch (e) {
    console.error("notify-email failed:", e);
    await release();
    return reply(String((e as Error)?.message ?? e), 500);
  } finally {
    try { await client?.close(); } catch { /* ignore */ }
  }
});
