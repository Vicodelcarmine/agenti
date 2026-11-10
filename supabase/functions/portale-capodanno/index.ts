// =============================================================================
// PORTALE CAPODANNOFIRENZE.IT → CRUSCOTTO DEL VICO (funzione "portale-capodanno", Verify JWT: OFF)
// Ogni ora l'orologio del database (cron "portale-capodanno") la chiama. Entra nel gestionale
// https://prenotazioni.capodannofirenze.it/ con PORTALE_UTENTE e PORTALE_PASSWORD (segreti delle
// funzioni: li inserisce il titolare, qui non si scrivono mai), legge tutte le pagine dell'elenco
// (solo lettura: apre le pagine, non tocca niente), esce e passa l'elenco a pren_portale_elabora.
// Se qualcosa non va lo segnala al titolare con portale_segnala. Vedi supabase/34-portale-server.sql.
// Parte solo se l'intestazione x-vico-portale è il segreto del cron (portale_turno).
// Corpo {"prova": true}: fa tutto e poi annulla (niente salvato, niente segnalato).
// Nei registri e nelle risposte solo conteggi: mai nomi, telefoni o note.
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";
import { DOMParser } from "npm:linkedom@0.18.5";

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
const PORTALE = "https://prenotazioni.capodannofirenze.it";
const UA = "Mozilla/5.0 (compatible; VicoDelCarmine-cruscotto/1.0)";
const UTENTE = (Deno.env.get("PORTALE_UTENTE") || "").trim();
const PASSWORD = Deno.env.get("PORTALE_PASSWORD") || "";

const risposta = (dati: unknown, status = 200) =>
  new Response(JSON.stringify(dati), { status, headers: { "Content-Type": "application/json" } });

// un errore da far leggere al titolare
class Problema extends Error {}

// ---------- i cookie della visita (il portale ricorda l'accesso con un cookie) ----------
const biscotti = new Map<string, string>();
// per capire cosa non va (solo in prova): passi fatti e avviso del portale, mai cookie o credenziali
let passi: string[] = [];
let avvisoPortale = "";
function prendiBiscotti(res: Response) {
  for (const c of res.headers.getSetCookie()) {
    const coppia = c.split(";")[0];
    const i = coppia.indexOf("=");
    if (i < 1) continue;
    const nome = coppia.slice(0, i).trim(), valore = coppia.slice(i + 1).trim();
    if (!valore || valore === "deleted" || /max-age=0\b/i.test(c) || /expires=[^;]*1970/i.test(c)) biscotti.delete(nome);
    else biscotti.set(nome, valore);
  }
}
// apre un indirizzo seguendo i reindirizzamenti a mano, con i cookie; torna risposta, testo e indirizzo finale
async function apri(url: string, init: RequestInit = {}): Promise<{ status: number; url: string; html: string }> {
  let u = url, opz: RequestInit = init;
  for (let salti = 0; salti < 6; salti++) {
    const h = new Headers(opz.headers || {});
    h.set("User-Agent", UA);
    if (biscotti.size) h.set("Cookie", [...biscotti].map(([k, v]) => k + "=" + v).join("; "));
    const res = await fetch(u, { ...opz, headers: h, redirect: "manual", signal: AbortSignal.timeout(25000) });
    prendiBiscotti(res);
    passi.push((opz.method || "GET") + " " + new URL(u).pathname + " → " + res.status);
    const dove = res.headers.get("location");
    if (res.status >= 300 && res.status < 400 && dove) {
      await res.body?.cancel();
      u = new URL(dove, u).toString();
      opz = { method: "GET" };
      continue;
    }
    return { status: res.status, url: u, html: await res.text() };
  }
  throw new Problema("Il portale rimanda da una pagina all'altra senza fermarsi");
}
const entita = (s: string) => s.replace(/&amp;/g, "&").replace(/&quot;/g, '"').replace(/&#0?39;/g, "'").replace(/&lt;/g, "<").replace(/&gt;/g, ">");

async function entra() {
  const p = await apri(PORTALE + "/users/login");
  const tag = p.html.match(/<input[^>]*name="_csrfToken"[^>]*>/);
  const tok = tag && tag[0].match(/value="([^"]*)"/);
  if (p.status !== 200 || !tok) throw new Problema("La pagina di accesso del portale è cambiata: non riesco a entrare");
  const corpo = new URLSearchParams({ _csrfToken: entita(tok[1]), username: UTENTE, password: PASSWORD });
  const r = await apri(PORTALE + "/users/login", {
    method: "POST", body: corpo.toString(),
    headers: { "Content-Type": "application/x-www-form-urlencoded", Origin: PORTALE, Referer: PORTALE + "/users/login" },
  });
  if (/\/users\/login/.test(r.url) || /type="password"/i.test(r.html)) {
    // il messaggio che il portale mostra sopra il modulo (per esempio "credenziali non valide")
    const m = r.html.match(/<div[^>]*class="[^"]*(?:message|flash|alert|error|errore)[^"]*"[^>]*>([\s\S]{0,400}?)<\/div>/i);
    avvisoPortale = m ? pulito(m[1].replace(/<[^>]+>/g, " ")).slice(0, 160) : "";
    throw new Problema("Il portale non accetta nome utente e password: controlla i segreti PORTALE_UTENTE e PORTALE_PASSWORD in Supabase");
  }
}
async function esci() {
  try { await apri(PORTALE + "/users/logout"); } catch (_) { /* pazienza */ }
}

// ---------- lettura della tabella "Prenotazioni" ----------
const pulito = (s: unknown) => String(s ?? "").replace(/\s+/g, " ").trim();
const CAMPI: Record<string, string> = {
  "id": "id", "nome": "nome", "cognome": "cognome", "locale/evento": "locale", "biglietto": "biglietto",
  "persone": "persone", "pagamento": "pagamento", "stato prenotazione": "stato", "totale": "totale",
  "acconto": "acconto", "saldo": "saldo", "telefono": "telefono", "note": "note", "note pag.": "note_pag",
};
const SERVONO = ["id", "locale", "biglietto", "persone", "stato"];

// deno-lint-ignore no-explicit-any
function valore(td: any): string {
  const s = td.querySelector("select");
  if (s) { const o = s.querySelector("option[selected]"); return pulito(o ? o.textContent : ""); }
  const i = td.querySelector("input:not([type=hidden]):not([type=checkbox])");
  if (i) return pulito(i.getAttribute("value"));
  return pulito(td.textContent);
}
// deno-lint-ignore no-explicit-any
function celle(tr: any): any[] {
  // deno-lint-ignore no-explicit-any
  const out: any[] = [];
  for (const c of Array.from(tr.children)) {
    out.push(c);
    // deno-lint-ignore no-explicit-any
    const span = parseInt((c as any).getAttribute("colspan") || "1", 10) || 1;
    for (let k = 1; k < span; k++) out.push(null);
  }
  return out;
}
type Riga = Record<string, string>;
function leggiPagina(html: string): { righe?: Riga[]; accesso?: boolean; manca?: boolean; mancano?: string[] } {
  if (/type="password"/i.test(html)) return { accesso: true };
  const doc = new DOMParser().parseFromString(html, "text/html");
  const t = doc.querySelector("#tblTickets");
  if (!t) return { manca: true };
  const testa = t.querySelector("thead tr");
  if (!testa) return { manca: true };
  const pos: Record<string, number> = {};
  celle(testa).forEach((c, i) => { if (!c) return; const k = CAMPI[pulito(c.textContent).toLowerCase()]; if (k && !(k in pos)) pos[k] = i; });
  const mancano = SERVONO.filter((k) => !(k in pos));
  if (mancano.length) return { mancano };
  const righe: Riga[] = [];
  for (const tr of Array.from(t.querySelectorAll("tbody tr"))) {
    const cs = celle(tr);
    if (cs.length <= pos.stato) continue;                  // riga "nessun risultato" o simili
    const r: Riga = {};
    for (const k in pos) r[k] = cs[pos[k]] ? valore(cs[pos[k]]) : "";
    if (!/^\d+$/.test(r.id)) {                             // il numero a volte sta solo nel link
      // deno-lint-ignore no-explicit-any
      const a = (tr as any).querySelector("a[href*='/view/'], a[href*='/edit/']");
      const m = a && String(a.getAttribute("href")).match(/\/(\d+)(?:[/?#]|$)/);
      r.id = m ? m[1] : "";
    }
    if (r.id) righe.push(r);
  }
  return { righe };
}
async function leggiTutto(): Promise<{ righe: Riga[]; pagine: number }> {
  const tutte = new Map<string, Riga>();
  let pagine = 0;
  for (let n = 1; n <= 100; n++) {
    const p = await apri(PORTALE + "/?page=" + n);
    if (/\/users\/login/.test(p.url)) throw new Problema("Il portale mi ha fatto uscire mentre leggevo l'elenco");
    if (p.status !== 200) { if (n === 1) throw new Problema("Il portale risponde con un errore (" + p.status + ")"); break; }
    const x = leggiPagina(p.html);
    if (x.accesso) throw new Problema("Il portale mi ha fatto uscire mentre leggevo l'elenco");
    if (x.manca) { if (n === 1) throw new Problema("Non trovo più la tabella delle prenotazioni sul portale"); break; }
    if (x.mancano) throw new Problema("La tabella del portale è cambiata: mancano le colonne " + x.mancano.join(", "));
    pagine = n;
    let nuove = 0;
    for (const r of x.righe!) if (!tutte.has(r.id)) { tutte.set(r.id, r); nuove++; }
    if (!x.righe!.length || !nuove) break;                 // finite (o la pagina si ripete)
  }
  return { righe: [...tutte.values()], pagine };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return risposta({ ok: true });
  // deno-lint-ignore no-explicit-any
  let corpo: any = {};
  try { corpo = await req.json(); } catch (_) { /* vuoto */ }
  const prova = corpo?.prova === true;

  const { data: via, error: e0 } = await db.rpc("portale_turno", { p_segreto: req.headers.get("x-vico-portale") || "" });
  if (e0) { console.error("portale turno", e0.message); return risposta({ errore: "interno" }, 500); }
  if (via !== "ok") return risposta({ errore: via }, via === "segreto" ? 401 : 429);
  biscotti.clear();                                        // ogni giro è una visita nuova
  passi = [];
  avvisoPortale = "";

  const segnala = async (esito: unknown, errore: string | null) => {
    if (prova) return;
    const { error } = await db.rpc("portale_segnala", { p_esito: esito, p_errore: errore });
    if (error) console.error("portale segnala", error.message);
  };

  if (!UTENTE || !PASSWORD) {
    const msg = "Mancano nome utente e password del portale nei segreti di Supabase (PORTALE_UTENTE, PORTALE_PASSWORD)";
    console.log("portale:", msg);
    await segnala(null, msg);
    return risposta({ ok: false, errore: msg });
  }

  let letto: { righe: Riga[]; pagine: number };
  try {
    await entra();
    letto = await leggiTutto();
  } catch (e) {
    const msg = e instanceof Problema ? e.message : "Il portale non risponde (" + String((e as Error)?.name || "errore") + ")";
    console.log("portale:", msg, JSON.stringify(passi), avvisoPortale);
    const diagnosi = prova ? {
      passi: [...passi], avviso: avvisoPortale,
      utente_con_chiocciola: UTENTE.includes("@"),
      password_con_spazi_ai_lati: PASSWORD !== PASSWORD.trim(),
    } : undefined;
    await esci();
    await segnala(null, msg);
    return risposta({ ok: false, errore: msg, diagnosi });
  }
  await esci();

  const stati: Record<string, number> = {};
  for (const r of letto.righe) stati[r.stato || "?"] = (stati[r.stato || "?"] || 0) + 1;
  const persone = letto.righe.filter((r) => r.stato === "Confermata" || r.stato === "In attesa di accredito")
    .reduce((s, r) => s + (parseInt(String(r.persone).replace(/\D/g, ""), 10) || 0), 0);
  const base = { pagine: letto.pagine, prenotazioni: letto.righe.length, persone_attive: persone, stati };

  const { data, error } = await db.rpc("pren_portale_elabora", { p_righe: letto.righe, p_prova: prova });
  if (error) {
    const m = String(error.message || "");
    if (prova && /^PROVA_OK/.test(m)) {
      console.log("portale PROVA", JSON.stringify(base), m.slice(0, 300));
      return risposta({ ok: true, prova: true, ...base, conteggi: JSON.parse(m.replace(/^PROVA_OK\s*/, "")) });
    }
    const msg = "Non riesco a caricare le prenotazioni del portale nel cruscotto";
    console.error("portale elabora", m.split("\n")[0].slice(0, 200));
    await segnala(null, msg);
    return risposta({ ok: false, errore: msg, ...base }, 500);
  }
  const esito = { ...base, conteggi: data };
  const altri = Number(data?.altri || 0);
  await segnala(esito, altri > 0
    ? "Sul portale ci sono " + altri + " prenotazioni di un biglietto o locale non collegato al cruscotto (va aggiunto a portale_eventi)"
    : null);
  console.log("portale", JSON.stringify(esito));
  return risposta({ ok: true, ...esito });
});
