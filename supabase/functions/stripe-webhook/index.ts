// =============================================================================
// STRIPE — una caparra pagata con un link di pagamento diventa una prenotazione.
// Funzione Supabase "stripe-webhook" (Verify JWT: OFF). Vedi supabase/31-caparre-stripe.sql.
// Su Stripe: Sviluppatori → Webhook → destinazione con questo indirizzo e gli eventi
// checkout.session.completed, checkout.session.async_payment_succeeded e charge.refunded.
// Ogni avviso è firmato: si accetta solo se la firma torna con il segreto della destinazione
// (STRIPE_WEBHOOK_SECRET per i pagamenti veri, STRIPE_WEBHOOK_SECRET_TEST per la modalità di test).
// Gli avvisi di test fanno la prova completa e poi annullano: nelle tabelle non resta niente.
// Nei registri solo tipo di evento ed esito, mai nomi o telefoni.
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
const SEGRETO = (Deno.env.get("STRIPE_WEBHOOK_SECRET") || "").trim();
const SEGRETO_TEST = (Deno.env.get("STRIPE_WEBHOOK_SECRET_TEST") || "").trim();
const TOLLERANZA = 300;   // secondi: avvisi più vecchi (o ripetuti da altri) non valgono

const risposta = (dati: unknown, status = 200) =>
  new Response(JSON.stringify(dati), { status, headers: { "Content-Type": "application/json" } });

const testo = new TextEncoder();
async function firma(segreto: string, messaggio: string): Promise<string> {
  const chiave = await crypto.subtle.importKey("raw", testo.encode(segreto), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const f = new Uint8Array(await crypto.subtle.sign("HMAC", chiave, testo.encode(messaggio)));
  return Array.from(f, (b) => b.toString(16).padStart(2, "0")).join("");
}
function uguali(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}
// "t=…,v1=…,v1=…": torna "vero", "test" o "" (firma non valida)
async function verifica(intestazione: string, corpo: string): Promise<"vero" | "test" | ""> {
  const parti = intestazione.split(",").map((p) => p.trim().split("="));
  const t = parti.find((p) => p[0] === "t")?.[1] || "";
  const firme = parti.filter((p) => p[0] === "v1").map((p) => p[1] || "");
  if (!t || !firme.length || Math.abs(Date.now() / 1000 - Number(t)) > TOLLERANZA) return "";
  for (const [segreto, tipo] of [[SEGRETO, "vero"], [SEGRETO_TEST, "test"]] as const) {
    if (!segreto) continue;
    const attesa = await firma(segreto, `${t}.${corpo}`);
    if (firme.some((f) => uguali(f, attesa))) return tipo;
  }
  return "";
}

// i campi del link: "Quanti secondi di carne", "Quanti secondi di pesce", "Allergie o note"
function campo(s: any, parola: RegExp): string {
  const c = (s.custom_fields || []).find((x: any) => parola.test(String(x?.label?.custom || x?.key || "")));
  if (!c) return "";
  return String(c.numeric?.value ?? c.text?.value ?? c.dropdown?.value ?? "").trim();
}

// un errore "PROVA_OK" è la prova riuscita (la funzione del database fa tutto e poi annulla)
function esito(error: any): "prova" | "errore" | "" {
  if (!error) return "";
  return /PROVA_OK/.test(String(error.message || "")) ? "prova" : "errore";
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return risposta({ ok: true });
  const corpo = await req.text();
  const tipo = await verifica(req.headers.get("stripe-signature") || "", corpo);
  if (!tipo) return risposta({ errore: "firma" }, 400);
  try {
    const evento = JSON.parse(corpo);
    const prova = tipo === "test";
    if (!prova && evento.livemode !== true) return risposta({ errore: "modalità" }, 400);
    const o = evento?.data?.object || {};

    if (evento.type === "checkout.session.completed" || evento.type === "checkout.session.async_payment_succeeded") {
      if (o.payment_status !== "paid") {
        console.log("stripe", evento.type, "non ancora pagato");
        return risposta({ ok: true, attesa: true });
      }
      // con i prezzi adattivi il cliente paga nella sua valuta: l'importo in euro sta in currency_conversion
      const conv = o.currency_conversion;
      const importo = conv && String(conv.source_currency).toLowerCase() === "eur" ? conv.amount_total
        : String(o.currency).toLowerCase() === "eur" ? o.amount_total : null;
      if (importo == null) throw new Error("valuta " + o.currency);
      const { data, error } = await db.rpc("pren_da_stripe", {
        p: {
          sessione: o.id, pagamento: o.payment_intent || "", link: o.payment_link || "", importo_cent: importo,
          nome: o.customer_details?.name || "", telefono: o.customer_details?.phone || "",
          carne: campo(o, /carne/i), pesce: campo(o, /pesce/i), note: campo(o, /allerg|note/i),
        },
        p_prova: prova,
      });
      const e = esito(error);
      if (e === "errore") throw new Error(error.message);
      console.log("stripe", evento.type, prova ? "PROVA" : "vero", e === "prova" ? "prova riuscita, annullata" : JSON.stringify(
        { ok: data?.ok, gia: data?.gia, ignorato: data?.ignorato, persone: data?.persone }));
      if (e === "prova") console.log("stripe prova:", String(error.message).replace(/"telefono":[^,}]*/, '"telefono":"…"').slice(0, 400));
      return risposta({ ok: true });
    }

    if (evento.type === "charge.refunded") {
      if (!(o.amount_refunded >= o.amount) || !o.payment_intent) return risposta({ ok: true, parziale: true });
      const { data, error } = await db.rpc("pren_rimborso_stripe", { p_pagamento: o.payment_intent, p_prova: prova });
      const e = esito(error);
      if (e === "errore") throw new Error(error.message);
      console.log("stripe rimborso", prova ? "PROVA" : "vero", JSON.stringify({ annullata: data?.annullata, ignorato: data?.ignorato }));
      return risposta({ ok: true });
    }

    return risposta({ ok: true, ignorato: evento.type });
  } catch (e: any) {
    console.error("stripe", String(e?.message || e));
    return risposta({ errore: "interno" }, 500);   // Stripe riprova più tardi
  }
});
