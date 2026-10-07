// =============================================================================
// VICO AGENTI — notifica all'agente quando arriva un suo tavolo.
// Funzione Supabase "pr-notifica" (Verify JWT: OFF).
//   { azione: "chiave" }  → chiave pubblica per attivare le notifiche sul telefono
//   { codice: "K7M2QX" }  → se quel buono è appena stato riscattato, avvisa l'agente
// Le chiavi delle notifiche (VAPID) le crea da sola la prima volta e le tiene
// nella tabella pr_config: nessun segreto da copiare a mano.
// Chiamarla due volte per lo stesso buono non manda due notifiche.
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
const euro = (n: unknown) => {
  const v = Math.round(Number(n || 0) * 100) / 100;
  return (Number.isInteger(v) ? String(v) : v.toFixed(2).replace(".", ",")) + " €";
};

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const corpo = await req.json().catch(() => ({}));
    const k = await chiaviVapid();
    if (corpo?.azione === "chiave") return risposta({ chiave: k.pub });

    const codice = String(corpo?.codice || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (codice.length !== 6) return risposta({ errore: "codice" }, 400);

    // segno il buono come notificato: solo la prima chiamata passa
    const { data: b } = await db.from("pr_buoni")
      .update({ notificato: true })
      .eq("codice", codice).eq("stato", "riscattato").eq("notificato", false)
      .select("codice, agente, sera_riscatto, persone, euro").maybeSingle();
    if (!b) return risposta({ inviate: 0 });

    // totale della serata in cui il tavolo si è seduto
    const { data: sera } = await db.from("pr_buoni").select("persone, euro")
      .eq("agente", b.agente).eq("sera_riscatto", b.sera_riscatto).eq("stato", "riscattato");
    const persone = (sera || []).reduce((s: number, x: any) => s + (x.persone || 0), 0);
    const totale = (sera || []).reduce((s: number, x: any) => s + Number(x.euro || 0), 0);

    const { data: subs } = await db.from("pr_push").select("endpoint, sub").eq("agente", b.agente);
    if (!subs?.length) return risposta({ inviate: 0 });

    webpush.setVapidDetails("https://vicodelcarmine.github.io", k.pub, k.priv);
    const messaggio = JSON.stringify({
      title: "🎉 È arrivato un tuo tavolo: +" + euro(b.euro),
      body: b.persone + (b.persone === 1 ? " persona" : " persone") + " al Vico del Carmine. Stasera sei a " +
        persone + " persone, " + euro(totale) + ".",
      tag: "pr-" + b.codice,
    });
    let inviate = 0;
    for (const s of subs) {
      try {
        await webpush.sendNotification(s.sub, messaggio, { urgency: "high", TTL: 3600 });
        inviate++;
      } catch (e: any) {
        console.error("push", s.endpoint.slice(0, 60), e?.statusCode || e?.message);
        if (e?.statusCode === 404 || e?.statusCode === 410) await db.from("pr_push").delete().eq("endpoint", s.endpoint);
      }
    }
    return risposta({ inviate });
  } catch (e: any) {
    console.error(e);
    return risposta({ errore: String(e?.message || e) }, 500);
  }
});
