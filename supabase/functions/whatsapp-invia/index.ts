// =============================================================================
// WHATSAPP — manda la conferma delle prenotazioni dal sito (WhatsApp Cloud API di Meta).
// Funzione Supabase "whatsapp-invia" (Verify JWT: OFF). Vedi supabase/16-whatsapp.sql.
//   { azione: "invia" } → manda i messaggi in coda: le conferme (prenotazioni con wa_stato =
//                         'in_coda') e la coda wa_uscita (prosecco, Club, voto, risposte: vedi
//                         17-whatsapp-dialogo.sql). Ogni messaggio parte una volta sola.
//                         La chiamano il sito, il webhook e l'orologio ogni 2 minuti.
//   { azione: "stato" } → { pronto: true/false }: c'è la chiave di WhatsApp?
// Modelli (approvati su WhatsApp Manager, in italiano "it"; "en" quando approvati):
//   prenotazione_benvenuto  {{1}} nome, {{2}} giorno, {{3}} ora, {{4}} persone ("rispondi CIAO…")
//   prenotazione_confermata {{1}} nome, {{2}} giorno, {{3}} ora, {{4}} persone
//   voto_serata             {{1}} nome, tasti 5 4 3 2 1
//   regalo_sorpresa_richiamo {{1}} nome, bottone col link ?c={{1}} (19-campagna-whatsapp.sql)
// Il segreto (WHATSAPP_TOKEN, token permanente dell'utente di sistema) sta nei Secrets di Supabase.
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
const TOKEN = Deno.env.get("WHATSAPP_TOKEN") || "";
const GRAPH = "https://graph.facebook.com/v25.0";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const risposta = (dati: unknown, status = 200) =>
  new Response(JSON.stringify(dati), { status, headers: { ...cors, "Content-Type": "application/json" } });

const testo = (t: string) => ({ type: "text", text: String(t || "").slice(0, 120) });

async function chiama(numeroId: string, corpo: Record<string, unknown>) {
  const r = await fetch(`${GRAPH}/${numeroId}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${TOKEN}`, "Content-Type": "application/json" },
    body: JSON.stringify({ messaging_product: "whatsapp", ...corpo }),
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d?.error?.error_data?.details || d?.error?.message || `errore ${r.status}`);
  return d?.messages?.[0]?.id || "";
}
// un modello approvato (si può mandare quando si vuole); link = il pezzo variabile del bottone col link
const manda = (numeroId: string, m: any, modello: string, parametri: string[], link?: string) =>
  chiama(numeroId, {
    to: String(m.telefono).replace(/\D/g, ""), type: "template",
    template: { name: modello, language: { code: m.lingua }, components: [
      { type: "body", parameters: parametri.map(testo) },
      ...(link ? [{ type: "button", sub_type: "url", index: "0", parameters: [{ type: "text", text: String(link) }] }] : []),
    ] },
  });
// un messaggio libero (solo entro 24 ore dall'ultimo messaggio del cliente)
const scrivi = (numeroId: string, m: any) =>
  chiama(numeroId, { to: String(m.telefono).replace(/\D/g, ""), type: "text", text: { body: m.testo, preview_url: true } });

async function invia() {
  if (!TOKEN) throw new Error("manca il segreto WHATSAPP_TOKEN");
  let inviati = 0;
  for (let giro = 0; giro < 4; giro++) {
    const { data, error } = await db.rpc("wa_prendi", { n: 20 });
    if (error) throw new Error(error.message);
    const lista = data?.messaggi || [];
    if (!lista.length) break;
    const c = data.config || {};
    for (const m of lista) {
      let id = "", errore = "";
      try {
        if (!c.numeroId) throw new Error("manca il Phone number ID");
        if (m.stato === "annullata") throw new Error("prenotazione annullata prima dell'invio");
        id = await manda(c.numeroId, m, m.benvenuto ? c.modelloNuovo : c.modello, [m.nome, m.giorno, m.ora, m.persone]);
        inviati++;
      } catch (e: any) {
        errore = String(e?.message || e);
        console.error("whatsapp", m.codice, errore);
      }
      await db.rpc("wa_esito", { p_id: m.id, p_wa_id: id, p_errore: errore || null });
    }
  }
  // la coda del dialogo: prosecco, Club, voto, grazie, risposte del titolare, richiamo della campagna
  for (let giro = 0; giro < 4; giro++) {
    const { data, error } = await db.rpc("wa_prendi_uscita", { n: 20 });
    if (error) throw new Error(error.message);
    const lista = data?.messaggi || [];
    if (!lista.length) break;
    for (const m of lista) {
      let id = "", errore = "";
      try {
        if (!data.numeroId) throw new Error("manca il Phone number ID");
        id = m.modello ? await manda(data.numeroId, m, m.modello, m.parametri || [], m.link) : await scrivi(data.numeroId, m);
        inviati++;
      } catch (e: any) {
        errore = String(e?.message || e);
        console.error("whatsapp", m.tipo, errore);
      }
      // la campagna riprova fra un'ora (3 tentativi), il resto no
      if (errore && m.tipo === "campagna") await db.rpc("camp_rimanda", { p_id: m.id, p_errore: errore });
      else await db.rpc("wa_esito_uscita", { p_id: m.id, p_wa_id: id, p_errore: errore || null });
    }
  }
  return inviati;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const corpo = await req.json().catch(() => ({}));
    if (corpo?.azione === "invia") return risposta({ inviati: await invia() });
    if (corpo?.azione === "stato") return risposta({ pronto: !!TOKEN });
    return risposta({ errore: "azione" }, 400);
  } catch (e: any) {
    console.error(e);
    return risposta({ errore: String(e?.message || e) }, 500);
  }
});
