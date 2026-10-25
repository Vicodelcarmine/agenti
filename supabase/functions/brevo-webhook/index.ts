// =============================================================================
// BREVO — chi si toglie dalle email della campagna non riceve il WhatsApp di richiamo.
// Funzione Supabase "brevo-webhook" (Verify JWT: OFF). Vedi supabase/19-campagna-whatsapp.sql.
// Su Brevo: Impostazioni → Webhook → webhook di marketing con questo indirizzo e gli eventi
// "Disiscritto" e "Spam". Brevo manda { event, email, … } (o un elenco, se a lotti).
// L'unico effetto è segnare il contatto come disiscritto (camp_brevo_evento): un evento finto
// può solo togliere un WhatsApp, mai mandarne uno. Se c'è il segreto BREVO_WEBHOOK_TOKEN,
// Brevo deve mandarlo come "Authorization: Bearer …" e senza non si accetta niente.
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
const GETTONE = (Deno.env.get("BREVO_WEBHOOK_TOKEN") || "").trim();

const risposta = (dati: unknown, status = 200) =>
  new Response(JSON.stringify(dati), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return risposta({ ok: true });
  if (GETTONE && (req.headers.get("authorization") || "") !== `Bearer ${GETTONE}`) return risposta({ errore: "chiave" }, 401);
  try {
    const corpo = await req.json().catch(() => null);
    const eventi = Array.isArray(corpo) ? corpo : corpo ? [corpo] : [];
    let tolti = 0;
    for (const e of eventi.slice(0, 500)) {
      const email = String(e?.email || "").trim();
      const evento = String(e?.event || "");
      if (!email || !/(unsub|spam|complaint)/i.test(evento)) continue;
      const { data, error } = await db.rpc("camp_brevo_evento", { p_email: email, p_evento: evento });
      if (error) throw new Error(error.message);
      tolti += data || 0;
    }
    console.log("brevo", eventi.length, "eventi,", tolti, "contatti tolti");   // niente email nei registri
    return risposta({ ok: true, tolti });
  } catch (e: any) {
    console.error("brevo", String(e?.message || e));
    return risposta({ errore: "interno" }, 500);   // Brevo riprova più tardi
  }
});
