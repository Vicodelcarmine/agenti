// =============================================================================
// WHATSAPP — riceve da Meta come sono andati i messaggi (inviato, consegnato, letto, errore)
// e i messaggi dei clienti (CIAO, il voto, STOP, domande): li passa a wa_ricevi (17-whatsapp-dialogo.sql).
// Funzione Supabase "whatsapp-webhook" (Verify JWT: OFF). Vedi supabase/16-whatsapp.sql.
// Su Meta (app → WhatsApp → Configurazione → Webhook):
//   URL di callback: https://agbvmhpktilpaoabjkre.supabase.co/functions/v1/whatsapp-webhook
//   Token di verifica: lo stesso testo del segreto WHATSAPP_VERIFICA
//   Campo da seguire: messages
// Ogni avviso di Meta è firmato con la chiave segreta dell'app (WHATSAPP_APP_SECRET): quelli
// non firmati bene si scartano. "Consegnato" = il numero della prenotazione è giusto.
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

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
const VERIFICA = Deno.env.get("WHATSAPP_VERIFICA") || "";
const APP_SECRET = Deno.env.get("WHATSAPP_APP_SECRET") || "";
const FUNZIONI = Deno.env.get("SUPABASE_URL") + "/functions/v1/";
// sveglia un'altra funzione (whatsapp-invia per le risposte, pren-avvisa per le notifiche al titolare)
const sveglia = (nome: string) =>
  fetch(FUNZIONI + nome, { method: "POST", headers: { "Content-Type": "application/json" }, body: '{"azione":"invia"}' })
    .catch((e) => console.error("sveglia", nome, e));

async function firmaGiusta(corpo: string, firma: string | null) {
  if (!APP_SECRET || !firma?.startsWith("sha256=")) return false;
  const chiave = await crypto.subtle.importKey("raw", new TextEncoder().encode(APP_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", chiave, new TextEncoder().encode(corpo)));
  const hex = Array.from(mac).map((b) => b.toString(16).padStart(2, "0")).join("");
  const attesa = firma.slice(7);
  if (attesa.length !== hex.length) return false;
  let diversi = 0;
  for (let i = 0; i < hex.length; i++) diversi |= hex.charCodeAt(i) ^ attesa.charCodeAt(i);
  return diversi === 0;
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  // Meta controlla l'indirizzo: risponde solo chi conosce il token di verifica
  if (req.method === "GET") {
    if (VERIFICA && url.searchParams.get("hub.mode") === "subscribe" && url.searchParams.get("hub.verify_token") === VERIFICA) {
      return new Response(url.searchParams.get("hub.challenge") || "", { status: 200 });
    }
    return new Response("no", { status: 403 });
  }
  if (req.method !== "POST") return new Response("no", { status: 405 });
  const corpo = await req.text();
  if (!(await firmaGiusta(corpo, req.headers.get("x-hub-signature-256")))) return new Response("firma", { status: 401 });
  let invia = false, avvisa = false;
  try {
    const d = JSON.parse(corpo);
    for (const e of d?.entry || []) {
      for (const c of e?.changes || []) {
        const v = c?.value || {};
        for (const s of v.statuses || []) {
          const errore = s?.errors?.[0] ? `${s.errors[0].title || ""} ${s.errors[0].error_data?.details || ""}`.trim() : null;
          await db.rpc("wa_aggiorna", { p_wa_id: s.id, p_stato: s.status, p_errore: errore });
        }
        for (const m of v.messages || []) {
          const nome = (v.contacts || []).find((x: any) => x.wa_id === m.from)?.profile?.name || "";
          const testo = m.text?.body || m.button?.text || m.interactive?.button_reply?.title ||
            m.interactive?.list_reply?.title || `[${m.type}]`;
          const { data, error } = await db.rpc("wa_ricevi", { p_da: m.from, p_nome: nome, p_testo: testo, p_wa_id: m.id });
          if (error) console.error("wa_ricevi", error.message);
          invia = invia || !!data?.invia;
          avvisa = avvisa || !!data?.avvisa;
        }
      }
    }
  } catch (e) {
    console.error("webhook", e);
  }
  if (invia) await sveglia("whatsapp-invia");
  if (avvisa) await sveglia("pren-avvisa");
  // a Meta si risponde sempre 200, se no riprova all'infinito
  return new Response("ok", { status: 200 });
});
