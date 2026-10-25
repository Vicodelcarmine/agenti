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
// trim: copiata dalla pagina di Meta può portarsi dietro uno spazio o un a capo
const APP_SECRET = (Deno.env.get("WHATSAPP_APP_SECRET") || "").trim();
const FUNZIONI = Deno.env.get("SUPABASE_URL") + "/functions/v1/";
const GRAPH = "https://graph.facebook.com/v25.0";
const APP_ID = "1449456029870740";                       // l'app "vico del carmine social" su Meta
// sveglia un'altra funzione (whatsapp-invia per le risposte, pren-avvisa per le notifiche al titolare)
const sveglia = (nome: string) =>
  fetch(FUNZIONI + nome, { method: "POST", headers: { "Content-Type": "application/json" }, body: '{"azione":"invia"}' })
    .catch((e) => console.error("sveglia", nome, e));

// Meta firma il testo con lettere accentate ed emoji scritte come è (lo dice la sua guida),
// e a volte con le barre scritte come \/, ma lo manda con i caratteri veri: si provano tutte le forme
const nonAscii = /[^\x00-\x7f]/g;
const escapato = (s: string) => s.replace(nonAscii, (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));
const barre = (s: string) => s.replace(/(?<!\\)\//g, "\\/");
const forme = (s: string) => [s, escapato(s), barre(s), barre(escapato(s))];

const esa = (b: ArrayBuffer | Uint8Array) => Array.from(new Uint8Array(b)).map((x) => x.toString(16).padStart(2, "0")).join("");
async function hmacCon(segreto: string, hash: "SHA-256" | "SHA-1", dati: Uint8Array) {
  const chiave = await crypto.subtle.importKey("raw", new TextEncoder().encode(segreto), { name: "HMAC", hash }, false, ["sign"]);
  return esa(await crypto.subtle.sign("HMAC", chiave, dati));
}
const hmac = (hash: "SHA-256" | "SHA-1", dati: Uint8Array) => hmacCon(APP_SECRET, hash, dati);
function uguali(a: string, b: string) {
  if (a.length !== b.length) return false;
  let diversi = 0;
  for (let i = 0; i < a.length; i++) diversi |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diversi === 0;
}
// si firma prima sui byte esattamente come sono arrivati, poi sulle altre forme del testo
async function firmaGiusta(byte: Uint8Array, corpo: string, firma: string | null) {
  if (!APP_SECRET || !firma?.startsWith("sha256=")) return false;
  const attesa = firma.slice(7).toLowerCase();
  if (uguali(await hmac("SHA-256", byte), attesa)) return true;
  for (const testo of new Set(forme(corpo))) {
    if (uguali(await hmac("SHA-256", new TextEncoder().encode(testo)), attesa)) return true;
  }
  return false;
}

// Controllo dei segreti senza mostrarli: chiede a Meta se la chiave dell'app e il token funzionano
// (GET ?controllo=<WHATSAPP_VERIFICA>&waba=<id account WhatsApp>). Risponde solo sì/no e nomi.
async function graph(percorso: string, token: string) {
  const r = await fetch(`${GRAPH}/${percorso}${percorso.includes("?") ? "&" : "?"}access_token=${encodeURIComponent(token)}`);
  const d = await r.json().catch(() => ({}));
  return r.ok ? d : { errore: d?.error?.message || `errore ${r.status}` };
}
async function controlla(waba: string | null) {
  const token = Deno.env.get("WHATSAPP_TOKEN") || "";
  const { data: cfg } = await db.from("wa_config").select("numero_id").eq("id", 1).maybeSingle();
  const app = await graph(`${APP_ID}?fields=name`, `${APP_ID}|${APP_SECRET}`);
  // queste due Meta le accetta solo con la vera chiave dell'app
  const iscrizioni = await graph(`${APP_ID}/subscriptions`, `${APP_ID}|${APP_SECRET}`);
  const tok = await graph(`debug_token?input_token=${encodeURIComponent(token)}`, `${APP_ID}|${APP_SECRET}`);
  const numero = await graph(`${cfg?.numero_id}?fields=display_phone_number,verified_name,quality_rating`, token);
  const collegate = waba ? await graph(`${waba}/subscribed_apps`, token) : null;
  return {
    // calcolo di prova con chiave e testo inventati: si confronta con lo stesso calcolo fatto altrove
    provaHmac: await hmacCon("chiave-di-prova", "SHA-256", new TextEncoder().encode('{"prova":"vico"}')),
    chiaveApp: app.errore ? `sbagliata: ${app.errore}` : `giusta (${app.name})`,
    iscrizioniApp: iscrizioni.errore ? `errore: ${iscrizioni.errore}`
      : (iscrizioni.data || []).map((s: any) => ({ oggetto: s.object, indirizzo: s.callback_url, attiva: s.active,
          campi: (s.fields || []).map((f: any) => f.name).join(",") })),
    tokenDiQualeApp: tok.errore ? `errore: ${tok.errore}`
      : { app: tok.data?.app_id, valido: tok.data?.is_valid, scade: tok.data?.expires_at },
    token: numero.errore ? `non funziona: ${numero.errore}` : "funziona",
    numero: numero.errore ? null : numero,
    appCollegate: collegate?.errore ? collegate.errore
      : (collegate?.data || []).map((a: any) => `${a.whatsapp_business_api_data?.name} (${a.whatsapp_business_api_data?.id})`),
  };
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  // Meta controlla l'indirizzo: risponde solo chi conosce il token di verifica
  if (req.method === "GET") {
    if (VERIFICA && url.searchParams.get("controllo") === VERIFICA) {
      return new Response(JSON.stringify(await controlla(url.searchParams.get("waba")), null, 2),
        { headers: { "Content-Type": "application/json" } });
    }
    if (VERIFICA && url.searchParams.get("hub.mode") === "subscribe" && url.searchParams.get("hub.verify_token") === VERIFICA) {
      return new Response(url.searchParams.get("hub.challenge") || "", { status: 200 });
    }
    return new Response("no", { status: 403 });
  }
  if (req.method !== "POST") return new Response("no", { status: 405 });
  const byte = new Uint8Array(await req.arrayBuffer());
  const corpo = new TextDecoder().decode(byte);
  if (!(await firmaGiusta(byte, corpo, req.headers.get("x-hub-signature-256")))) {
    // la chiave non si scrive mai: solo se ha la forma di una chiave segreta di Meta (32 cifre esadecimali);
    // del contenuto solo che tipo di avviso è e un'impronta, niente numeri né testi dei clienti
    let forma: unknown = "non JSON";
    try {
      const d = JSON.parse(corpo), c = d?.entry?.[0]?.changes?.[0];
      forma = { oggetto: d?.object, campo: c?.field, chiavi: Object.keys(c?.value || {}).join(",") };
    } catch (_) { /* resta "non JSON" */ }
    const sha = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(corpo)));
    // le firme non svelano la chiave: si confrontano i primi caratteri di quella arrivata e di quella calcolata
    const f256 = req.headers.get("x-hub-signature-256") || "", f1 = req.headers.get("x-hub-signature") || "";
    console.warn("firma non valida", { forma, impronta: esa(sha.slice(0, 6)), byte: byte.length,
      arrivata256: f256.slice(0, 19), calcolata256: (await hmac("SHA-256", byte)).slice(0, 12),
      arrivata1: f1.slice(0, 17), calcolata1: (await hmac("SHA-1", byte)).slice(0, 12),
      firma: !!f256,
      chiaveLunga: APP_SECRET.length, chiaveForma: /^[0-9a-f]{32}$/.test(APP_SECRET),
      lunghezza: corpo.length, accenti: corpo.match(nonAscii)?.length || 0, barre: corpo.split("/").length - 1,
      tipo: req.headers.get("content-type"), codifica: req.headers.get("content-encoding") });
    return new Response("firma", { status: 401 });
  }
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
