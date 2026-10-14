// =============================================================================
// CLUB DEL VICO — manda gli avvisi ai clienti del Club.
// Funzione Supabase "club-invia" (Verify JWT: OFF).
//   { azione: "chiave" } → chiave pubblica per accendere le notifiche (la stessa degli agenti)
//   { azione: "stato" }  → { email: true/false }: il servizio email è collegato?
//   { azione: "invia" }  → manda gli avvisi in coda (tabella club_messaggi). Si può chiamare
//                          quante volte si vuole: ogni avviso parte una volta sola.
// Notifiche: le chiavi VAPID sono quelle degli agenti (tabella pr_config).
// Email: partono solo con l'interruttore "Email" acceso nella dashboard E il segreto
// RESEND_API_KEY (Supabase → Edge Functions → Secrets). Mittente: CLUB_EMAIL_DA.
// Le offerte e il compleanno per email vanno solo a chi ha confermato l'indirizzo.
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

// Supabase ora fornisce le chiavi come elenco JSON; resta il ripiego sulle vecchie.
function pickKey(json: string | undefined, legacy: string | undefined): string {
  if (json) {
    try {
      const j = JSON.parse(json);
      const v = Array.isArray(j) ? j[0] : Object.values(j)[0];
      const k = typeof v === "string" ? v : (v?.api_key || v?.key || v?.secret);
      if (k) return k;
    } catch (_) { /* ignora */ }
  }
  return legacy || "";
}
const SERVICE_KEY = pickKey(Deno.env.get("SUPABASE_SECRET_KEYS"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
const db = createClient(Deno.env.get("SUPABASE_URL")!, SERVICE_KEY);

const MENU = "https://vicodelcarmine.github.io/menu/";
const RESEND = Deno.env.get("RESEND_API_KEY") || "";
const DA = Deno.env.get("CLUB_EMAIL_DA") || "Vico del Carmine <club@ai-io.it>";
const RISPONDI = Deno.env.get("CLUB_EMAIL_RISPONDI") || "vicodelcarmine1@gmail.com";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const risposta = (dati: unknown, status = 200) =>
  new Response(JSON.stringify(dati), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function chiaviVapid() {
  const leggi = async () => {
    const { data } = await db.from("pr_config").select("chiave, valore").in("chiave", ["vapid_pub", "vapid_priv"]);
    const m: Record<string, string> = {};
    (data || []).forEach((r: any) => m[r.chiave] = r.valore);
    return m;
  };
  let m = await leggi();
  if (!m.vapid_pub || !m.vapid_priv) {
    const k = webpush.generateVAPIDKeys();
    await db.from("pr_config").upsert([
      { chiave: "vapid_pub", valore: k.publicKey },
      { chiave: "vapid_priv", valore: k.privateKey },
    ], { onConflict: "chiave", ignoreDuplicates: true });
    m = await leggi();
  }
  return { pub: m.vapid_pub, priv: m.vapid_priv };
}

async function emailAccese() {
  const { data } = await db.from("club_impostazioni").select("email_attive").eq("id", 1).maybeSingle();
  return !!(data && data.email_attive) && !!RESEND;
}

const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" } as Record<string, string>)[c]);

// l'email: semplice, nei colori del menu, con un tasto e il link per non ricevere più offerte
function email(m: any) {
  const it = m.lingua === "it";
  const stop = MENU + "?club_stop=" + m.token;
  let tasto = "", url = MENU + "?club=apri";
  if (m.tipo === "benvenuto") { url = MENU + "?club_email=" + m.token; tasto = it ? "Conferma la tua email" : "Confirm your email"; }
  else if (m.tipo !== "codice") tasto = it ? "Apri la tua tessera" : "Open your card";
  const codice = m.tipo === "codice" && m.codice
    ? '<p style="font-size:34px;letter-spacing:8px;font-weight:700;color:#e6b24a;margin:18px 0">' + esc(m.codice) + "</p>" : "";
  const piede = m.tipo === "codice" ? "" :
    '<p style="font-size:12px;color:#8d7a68;margin-top:22px">' +
    (it ? "Non vuoi più ricevere le offerte del Club? " : "Don't want Club offers any more? ") +
    '<a href="' + stop + '" style="color:#cbb49c">' + (it ? "Tocca qui" : "Tap here") + "</a></p>";
  const html =
    '<div style="background:#1a1210;padding:28px 14px;font-family:Helvetica,Arial,sans-serif">' +
    '<div style="max-width:460px;margin:0 auto;background:#241816;border:1px solid #4a3326;border-radius:18px;padding:26px 22px;color:#f7efe2;text-align:center">' +
    '<p style="font-size:13px;letter-spacing:3px;color:#e6b24a;margin:0 0 6px">VICO DEL CARMINE</p>' +
    '<h1 style="font-family:Georgia,serif;font-size:24px;color:#edcf94;margin:6px 0 12px">' + esc(m.titolo) + "</h1>" +
    '<p style="font-size:16px;line-height:1.5;color:#f7efe2;margin:0">' + esc(m.testo) + "</p>" + codice +
    (tasto ? '<p style="margin:22px 0 4px"><a href="' + url + '" style="background:#e6b24a;color:#2a1a08;text-decoration:none;font-weight:700;padding:13px 22px;border-radius:12px;display:inline-block">' + esc(tasto) + "</a></p>" : "") +
    piede +
    '<p style="font-size:12px;color:#8d7a68;margin-top:14px">Vico del Carmine · Via Pisana 40/r · Firenze</p></div></div>';
  const testo = m.titolo + "\n\n" + m.testo + (m.tipo === "codice" && m.codice ? "\n\n" + m.codice : "") +
    (tasto ? "\n\n" + tasto + ": " + url : "") + (piede ? "\n\n" + (it ? "Niente più offerte: " : "No more offers: ") + stop : "");
  return { subject: m.titolo, html, text: testo, stop: m.tipo === "codice" ? "" : stop };
}

async function mandaEmail(m: any) {
  const e = email(m);
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: "Bearer " + RESEND, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: DA, to: [m.indirizzo], reply_to: RISPONDI, subject: e.subject, html: e.html, text: e.text,
      headers: e.stop ? { "List-Unsubscribe": "<" + e.stop + ">" } : undefined,
    }),
  });
  if (r.ok) return "ok";
  return "errore " + r.status + " " + (await r.text()).slice(0, 120);
}

async function invia() {
  const k = await chiaviVapid();
  webpush.setVapidDetails("https://vicodelcarmine.github.io", k.pub, k.priv);
  const conEmail = await emailAccese();
  let inviati = 0;
  for (let giro = 0; giro < 6; giro++) {
    const { data: lista, error } = await db.rpc("club_prendi_messaggi", { n: 50 });
    if (error) throw new Error(error.message);
    if (!lista || !lista.length) break;
    for (const m of lista) {
      const esito: Record<string, unknown> = { push: 0, email: "no" };
      // offerte e compleanno: se nel frattempo ha detto no alle offerte, non parte niente
      const promozione = m.tipo === "promo" || m.tipo === "compleanno";
      if (promozione && !m.promo) {
        esito.email = "offerte spente";
      } else {
        if (m.push && m.subs?.length) {
          const corpo = JSON.stringify({ title: m.titolo, body: m.testo, tag: "club-" + m.tipo, url: "./?club=apri" });
          for (const s of m.subs) {
            try {
              await webpush.sendNotification(s.sub, corpo, { urgency: "normal", TTL: 12 * 3600 });
              (esito.push as number)++;
            } catch (e: any) {
              console.error("push", String(s.endpoint).slice(0, 60), e?.statusCode || e?.message);
              if (e?.statusCode === 404 || e?.statusCode === 410) await db.from("club_push").delete().eq("endpoint", s.endpoint);
            }
          }
        }
        if (m.email) {
          if (!conEmail) esito.email = "spente";
          else if (!m.indirizzo) esito.email = "manca l'indirizzo";
          else if ((promozione || m.tipo === "prova") && !m.confermata) esito.email = "non confermata";
          else {
            try { esito.email = await mandaEmail(m); } catch (e: any) { esito.email = "errore " + (e?.message || e); }
          }
        }
      }
      await db.from("club_messaggi").update({ esito }).eq("id", m.id);
      inviati++;
    }
  }
  return inviati;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const corpo = await req.json().catch(() => ({}));
    if (corpo?.azione === "chiave") return risposta({ chiave: (await chiaviVapid()).pub });
    if (corpo?.azione === "stato") return risposta({ email: !!RESEND });
    if (corpo?.azione === "invia") return risposta({ inviati: await invia() });
    return risposta({ errore: "azione" }, 400);
  } catch (e: any) {
    console.error(e);
    return risposta({ errore: String(e?.message || e) }, 500);
  }
});
