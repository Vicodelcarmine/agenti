// =============================================================================
// PRENOTAZIONI — avvisa il titolare a ogni prenotazione nuova o annullata dal sito.
// Funzione Supabase "pren-avvisa" (Verify JWT: OFF).
//   { azione: "invia" } → manda le notifiche in coda (tabella pren_avvisi) ai telefoni del
//                         titolare (tabella pren_push). Si può chiamare quante volte si vuole:
//                         ogni avviso parte una volta sola. La chiama il sito dopo ogni
//                         prenotazione, e ogni 5 minuti l'orologio se è rimasto qualcosa.
// Le chiavi VAPID sono quelle degli agenti (tabella pr_config).
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

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const risposta = (dati: unknown, status = 200) =>
  new Response(JSON.stringify(dati), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function chiaviVapid() {
  const { data } = await db.from("pr_config").select("chiave, valore").in("chiave", ["vapid_pub", "vapid_priv"]);
  const m: Record<string, string> = {};
  (data || []).forEach((r: any) => m[r.chiave] = r.valore);
  if (!m.vapid_pub || !m.vapid_priv) throw new Error("chiavi VAPID mancanti");
  return { pub: m.vapid_pub, priv: m.vapid_priv };
}

async function invia() {
  const k = await chiaviVapid();
  webpush.setVapidDetails("https://vicodelcarmine.github.io", k.pub, k.priv);
  let inviati = 0;
  for (let giro = 0; giro < 4; giro++) {
    const { data, error } = await db.rpc("pren_prendi_avvisi", { n: 30 });
    if (error) throw new Error(error.message);
    const avvisi = data?.avvisi || [];
    if (!avvisi.length) break;
    const subs = data.subs || [];
    for (const a of avvisi) {
      let ok = 0;
      const corpo = JSON.stringify({ title: a.titolo, body: a.testo, tag: "pren-" + a.prenotazione, url: "./?tab=prenota" });
      for (const s of subs) {
        try {
          await webpush.sendNotification(s.sub, corpo, { urgency: "high", TTL: 6 * 3600 });
          ok++;
        } catch (e: any) {
          console.error("push", String(s.endpoint).slice(0, 60), e?.statusCode || e?.message);
          if (e?.statusCode === 404 || e?.statusCode === 410) await db.from("pren_push").delete().eq("endpoint", s.endpoint);
        }
      }
      await db.from("pren_avvisi").update({ esito: { push: ok, telefoni: subs.length } }).eq("id", a.id);
      inviati++;
    }
  }
  return inviati;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const corpo = await req.json().catch(() => ({}));
    if (corpo?.azione === "invia") return risposta({ inviati: await invia() });
    return risposta({ errore: "azione" }, 400);
  } catch (e: any) {
    console.error(e);
    return risposta({ errore: String(e?.message || e) }, 500);
  }
});
