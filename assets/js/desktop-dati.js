/* Vico del Carmine · Dashboard da computer — i dati.
   Parla con il database (funzioni dash_* in supabase/20-dashboard-fondamenta.sql e
   21-dashboard-statistiche.sql, più camp_panoramica e pr_entra). Ogni funzione vuole il PIN
   del titolare; gli errori portano il loro codice nel campo "hint".
   ?demo=1 → dati finti generati nel browser (stessa forma dei veri), PIN 1234; ?demo=0 per uscire. */
(function () {
  "use strict";

  const URL = "https://agbvmhpktilpaoabjkre.supabase.co";
  const CHIAVE = "sb_publishable_2O5l8ZbQqGnwDXwxZnsZ2Q_0Mt1V8T7";   // pubblica: va bene nel sito

  const DEMO = (function () {
    try {
      if (/[?&]demo=1/.test(location.search)) sessionStorage.setItem("vdc_desk_demo", "1");
      if (/[?&]demo=0/.test(location.search)) sessionStorage.removeItem("vdc_desk_demo");
      return sessionStorage.getItem("vdc_desk_demo") === "1";
    } catch (e) { return false; }
  })();

  function errore(codice, msg) { const e = new Error(msg); e.codice = codice; return e; }

  async function rpc(nome, corpo) {
    let r;
    try {
      r = await fetch(URL + "/rest/v1/rpc/" + nome, {
        method: "POST",
        headers: { apikey: CHIAVE, "Content-Type": "application/json" },
        body: JSON.stringify(corpo || {}),
      });
    } catch (e) { throw errore("rete", "Connessione assente: riprova tra poco."); }
    const testo = await r.text();
    let d = null;
    try { d = testo ? JSON.parse(testo) : null; } catch (e) {}
    if (!r.ok) throw errore((d && d.hint) || "server", (d && d.message) || "Errore del server");
    return d;
  }

  const vero = {
    entra: function (pin) { return rpc("pr_entra", { p_pin: pin }); },
    riepilogo: function (pin, dal, al) { return rpc("dash_riepilogo", { p_pin: pin, p_dal: dal, p_al: al }); },
    clienti: function (pin, dal, al) { return rpc("dash_clienti", { p_pin: pin, p_dal: dal, p_al: al }); },
    cerca: function (pin, q) { return rpc("dash_cerca", { p_pin: pin, p_cerca: q }); },
    cliente: function (pin, tel) { return rpc("dash_cliente", { p_pin: pin, p_telefono: tel }); },
    salute: function (pin) { return rpc("dash_salute", { p_pin: pin }); },
    impostazioni: function (pin) { return rpc("dash_impostazioni", { p_pin: pin }); },
    campagne: function (pin) { return rpc("camp_panoramica", { p_pin: pin }); },
    periodoSalva: function (pin, p) {
      return rpc("dash_periodo_salva", { p_pin: pin, p_id: p.id || null, p_nome: p.nome, p_tipo: p.tipo,
        p_dal: p.dal, p_al: p.al || null, p_note: p.note || "" });
    },
    periodoElimina: function (pin, id) { return rpc("dash_periodo_elimina", { p_pin: pin, p_id: id }); },
    cassaSalva: function (pin, sera, incasso, coperti, scontrini) {
      return rpc("dash_cassa_salva", { p_pin: pin, p_sera: sera, p_incasso: incasso, p_coperti: coperti, p_scontrini: scontrini });
    },
    erpChiave: function (pin) { return rpc("dash_erp_nuova_chiave", { p_pin: pin }); },
    cassaArticoli: function (pin, dal, al) { return rpc("dash_cassa_articoli", { p_pin: pin, p_dal: dal, p_al: al }); },
  };

  /* ================= la demo: dati finti ma credibili, sempre uguali per lo stesso giorno ================= */

  function seme(s) { let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; }
  function caso(s) { let x = seme(s); return function () { x ^= x << 13; x ^= x >>> 17; x ^= x << 5; return ((x >>> 0) % 10000) / 10000; }; }
  function aData(s) { const p = s.split("-").map(Number); return new Date(Date.UTC(p[0], p[1] - 1, p[2])); }
  function daData(d) { return d.toISOString().slice(0, 10); }
  function piu(s, n) { const d = aData(s); d.setUTCDate(d.getUTCDate() + n); return daData(d); }
  function giorni(dal, al) { const out = []; for (let s = dal; s <= al; s = piu(s, 1)) out.push(s); return out; }
  function oggiRoma() { return new Intl.DateTimeFormat("en-CA", { timeZone: "Europe/Rome" }).format(new Date()); }
  const INIZIO_DEMO = "2026-06-01", CAMPAGNA_DEMO = "2026-10-26";

  const PIATTI = ["Pizza Vico", "Margherita", "Diavola", "Chitarra allo scoglio", "Carbonara classica", "Tabarro",
    "Entrecôte al Chianti", "Branzino", "Parmigiana", "Gnocchi alla sorrentina", "Tiramisù", "Babà"];
  const PREZZI = [12, 8, 9, 18, 13, 11, 22, 19, 10, 12, 6, 6];
  const CANALI = ["google", "instagram", "diretto", "campagna:regalo", "facebook", "menu", "whatsapp"];
  const NOMI = ["Giulia Rossi", "Marco Bianchi", "Sara Verdi", "Luca Neri", "Elena Galli", "Paolo Conti", "Chiara Fabbri",
    "Andrea Moretti", "Francesca Lombardi", "Davide Ricci", "Martina Romano", "Simone Greco"];

  function giornoDemo(g) {
    const r = caso("g" + g), dow = aData(g).getUTCDay();           // 0 dom … 6 sab
    const prima = g < INIZIO_DEMO || g > oggiRoma();
    const peso = [1.0, 0.45, 0.55, 0.65, 0.85, 1.25, 1.45][dow];
    const campagna = g >= CAMPAGNA_DEMO ? 1.3 : 1;
    const pren = prima ? 0 : Math.round((3 + r() * 6) * peso * campagna);
    const persone = Math.round(pren * (2.2 + r() * 1.4));
    const coperti = prima ? null : Math.round(persone + 25 * peso + r() * 20);
    const asp = prima || dow === 6 ? 0 : Math.round(r() * 6 * peso);
    const ord = prima ? 0 : Math.round(r() * 5 * peso);
    const giocate = prima || dow === 6 ? 0 : Math.round(r() * 14 * peso);
    const tavoli = Math.round(giocate * (0.25 + r() * 0.2));
    const prPersone = Math.round(tavoli * (2 + r() * 2));
    return {
      g: g, pren: pren, persone: persone, annullate: r() < 0.2 ? 1 : 0, noshow: r() < 0.08 ? 1 : 0,
      incasso: coperti == null || g === oggiRoma() ? null : Math.round(coperti * (27 + r() * 8)),
      coperti: g === oggiRoma() ? null : coperti, scontrini: coperti == null || g === oggiRoma() ? null : Math.round(coperti / 2.6),
      cassaFonte: coperti == null || g === oggiRoma() ? null : (r() < 0.9 ? "erp" : "manuale"),
      asp: asp, aspEuro: Math.round(asp * (24 + r() * 14)), ordini: ord, ordiniEuro: Math.round(ord * (38 + r() * 30)),
      club: prima ? 0 : Math.round(r() * 4 * campagna), premiUsati: prima ? 0 : Math.round(r() * 4),
      giocate: giocate, tavoli: tavoli, prPersone: prPersone, prEuro: prPersone * 2,
      fortuna: prima ? 0 : Math.round(r() * 3), visite: prima ? 0 : Math.round((20 + r() * 40) * peso * campagna),
      waInviati: Math.round(pren * 0.8 + (g >= CAMPAGNA_DEMO ? r() * 15 : 0)), waRicevuti: Math.round(pren * 0.5),
    };
  }
  function somma(lista, k) { return lista.reduce(function (s, x) { return s + (Number(x[k]) || 0); }, 0); }
  function riparti(tot, chiavi, s) {
    const r = caso(s), pesi = chiavi.map(function () { return 0.2 + r(); }), t = pesi.reduce(function (a, b) { return a + b; }, 0);
    const out = {}; let resto = tot;
    chiavi.forEach(function (k, i) { const n = i === chiavi.length - 1 ? resto : Math.round(tot * pesi[i] / t); out[k] = Math.max(0, n); resto -= out[k]; });
    return out;
  }

  function riepilogoDemo(dal, al) {
    const gg = giorni(dal, al).map(giornoDemo), s = dal + al, r = caso(s);
    const pren = somma(gg, "pren"), persone = somma(gg, "persone");
    const canali = riparti(pren, ["sito", "manuale:telefono", "manuale:thefork", "google", "instagram", "campagna:regalo"], s + "c");
    const canaliPren = {};
    Object.keys(canali).forEach(function (k) { if (canali[k]) canaliPren[k] = { n: canali[k], persone: Math.round(canali[k] * 2.7) }; });
    const settimana = [1, 2, 3, 4, 5, 6, 7].map(function (d) {
      const del = gg.filter(function (x) { return (aData(x.g).getUTCDay() || 7) === d; });
      return { d: d, n: somma(del, "pren"), persone: somma(del, "persone") };
    });
    const ore = ["19:00", "19:30", "20:00", "20:30", "21:00", "21:30", "22:00"];
    const orari = ore.map(function (o, i) { const n = Math.round(pren * [0.08, 0.14, 0.22, 0.24, 0.18, 0.1, 0.04][i]); return { ora: o, n: n, persone: Math.round(n * 2.6) }; });
    const mappa = [];
    settimana.forEach(function (w) { ore.forEach(function (o, i) { mappa.push({ d: w.d, ora: o, persone: Math.round(w.persone * [0.08, 0.14, 0.22, 0.24, 0.18, 0.1, 0.04][i]) }); }); });
    const cassa = gg.filter(function (x) { return x.incasso != null; });
    const piatti = PIATTI.map(function (n, i) { const q = Math.round((somma(gg, "asp") + somma(gg, "ordini")) * (0.3 + r()) * (i < 4 ? 1.6 : 0.7)); return { nome: n, qta: q, euro: q * PREZZI[i] }; })
      .sort(function (a, b) { return b.qta - a.qta; });
    const voti = riparti(Math.round(pren * 0.35), ["1", "2", "3", "4", "5"], s + "v");
    voti["5"] += voti["1"]; voti["1"] = Math.round(voti["1"] * 0.1);
    const nv = Object.values(voti).reduce(function (a, b) { return a + b; }, 0);
    const mediaV = nv ? Math.round(100 * Object.keys(voti).reduce(function (a, k) { return a + k * voti[k]; }, 0) / nv) / 100 : null;
    return {
      dal: dal, al: al, giorni: gg,
      prenotazioni: { totale: pren, persone: persone, annullate: somma(gg, "annullate"), noshow: somma(gg, "noshow"),
        canali: canaliPren, settimana: settimana, orari: orari, mappa: mappa,
        gruppi: riparti(pren, ["1-2", "3-4", "5-6", "7+"], s + "g"), anticipo: Math.round(10 * (1 + r() * 3)) / 10,
        benvenuto: Math.round(pren * 0.3), voti: { n: nv, media: mediaV, distribuzione: voti } },
      cassa: { sere: cassa.length, incasso: somma(cassa, "incasso"), coperti: somma(cassa, "coperti"), scontrini: somma(cassa, "scontrini"), daErp: cassa.length },
      club: { nuovi: somma(gg, "club"), promo: Math.round(somma(gg, "club") * 0.6),
        canali: riparti(somma(gg, "club"), ["prenotazione", "campagna:regalo", "asporto", "menu-qr", "instagram"], s + "k"),
        premi: { benvenuto: { emessi: Math.round(somma(gg, "club") * 0.7), usati: Math.round(somma(gg, "premiUsati") * 0.5) },
          compleanno: { emessi: Math.round(gg.length / 6), usati: Math.round(gg.length / 12) },
          regalo: { emessi: Math.round(somma(gg, "club") * 0.3), usati: Math.round(somma(gg, "premiUsati") * 0.3) },
          promo: { emessi: Math.round(gg.length / 10), usati: Math.round(gg.length / 20) } },
        totale: 40 + Math.round((aData(al) - aData(INIZIO_DEMO)) / 864e5 * 1.6) },
      agenti: ["Leonardo", "Marta", "Kevin"].map(function (n, i) {
        const t = Math.round(somma(gg, "tavoli") * [0.55, 0.3, 0.15][i]), p = Math.round(somma(gg, "prPersone") * [0.55, 0.3, 0.15][i]);
        return { id: "demo" + i, nome: n, attivo: i < 2, giocate: Math.round(somma(gg, "giocate") * [0.5, 0.33, 0.17][i]), tavoli: t, persone: p, euro: p * 2, pagato: Math.round(p * 1.4) };
      }),
      asporto: { ordini: somma(gg, "asp"), euro: somma(gg, "aspEuro"), pezzi: somma(gg, "asp") * 3, annullati: Math.round(somma(gg, "asp") * 0.05),
        clienti: Math.round(somma(gg, "asp") * 0.7),
        ritiri: ["19:30", "20:00", "20:30", "21:00", "21:30", "22:00"].map(function (o, i) { return { ora: o, n: Math.round(somma(gg, "asp") * [0.1, 0.2, 0.25, 0.22, 0.15, 0.08][i]) }; }),
        minuti: 22, piatti: piatti.slice(0, 12) },
      ordini: { ordini: somma(gg, "ordini"), euro: somma(gg, "ordiniEuro"), coperti: Math.round(somma(gg, "ordini") * 2.8),
        tavoli: Math.round(somma(gg, "ordini") * 0.8), minuti: 3, piatti: piatti.slice(0, 12) },
      whatsapp: { conferme: { inviate: Math.round(pren * 0.7), lette: Math.round(pren * 0.6), errori: Math.round(pren * 0.02), attivati: Math.round(pren * 0.25) },
        messaggi: { prosecco: { inviati: Math.round(pren * 0.25), letti: Math.round(pren * 0.24), errori: 0, saltati: 0 },
          club: { inviati: Math.round(pren * 0.15), letti: Math.round(pren * 0.12), errori: 0, saltati: Math.round(pren * 0.05) },
          voto: { inviati: Math.round(pren * 0.5), letti: Math.round(pren * 0.45), errori: 1, saltati: 0 },
          campagna: { inviati: al >= CAMPAGNA_DEMO ? 140 : 0, letti: al >= CAMPAGNA_DEMO ? 118 : 0, errori: al >= CAMPAGNA_DEMO ? 4 : 0, saltati: al >= CAMPAGNA_DEMO ? 21 : 0 } },
        ricevuti: somma(gg, "waRicevuti"), stop: Math.round(gg.length / 15) },
      fortuna: { giocate: somma(gg, "fortuna"), riscattate: Math.round(somma(gg, "fortuna") * 0.4),
        premi: riparti(somma(gg, "fortuna"), ["🥂 Prosecco", "🍰 Dolce", "🍹 Spritz", "🎉 -10%"], s + "f") },
      sito: { visite: somma(gg, "visite"),
        canali: riparti(somma(gg, "visite"), CANALI, s + "s"), pagine: riparti(somma(gg, "visite"), ["home", "home-en", "regalo"], s + "p") },
    };
  }

  function clientiDemo(dal, al) {
    const r = caso("cl" + dal + al), attivi = Math.round(giorni(dal, al).length * 4.2);
    const nuovi = Math.round(attivi * (0.45 + r() * 0.15));
    const tel = function (i) { return "+39333" + String(1000000 + i * 7919).slice(-7); };
    return {
      attivi: attivi, nuovi: nuovi, tornati: attivi - nuovi, conosciuti: 380 + Math.round(r() * 60),
      frequenza: { "1": Math.round(attivi * 0.52), "2": Math.round(attivi * 0.22), "3": Math.round(attivi * 0.11), "4-5": Math.round(attivi * 0.09), "6+": Math.round(attivi * 0.06) },
      intervalloMedio: 24.5,
      top: NOMI.map(function (n, i) { return { telefono: tel(i), nome: n, visite: 14 - i, nelPeriodo: Math.max(1, 4 - Math.floor(i / 3)), prima: "2026-06-1" + (i % 9), ultima: piu(al, -i * 2), intervallo: 9 + i, club: i % 3 !== 2 }; }),
      daRiconquistare: NOMI.slice(3).map(function (n, i) { return { telefono: tel(i + 20), nome: n, visite: 6 - Math.floor(i / 2), ultima: piu(al, -50 - i * 9), giorni: 50 + i * 9 }; }),
      asporto: { clienti: Math.round(attivi * 0.6), ricorrenti: Math.round(attivi * 0.2) },
    };
  }
  function clienteDemo(tel) {
    const i = Math.abs(seme(tel)) % NOMI.length;
    return {
      telefono: tel, nome: NOMI[i], presenze: 9,
      club: { dal: "2026-07-03T20:11:00Z", email: "esempio@example.com", nascita: "1988-04-12", promo: true, canale: "instagram", lingua: "it", ultimoContatto: "2026-10-20T19:00:00Z" },
      prenotazioni: [0, 1, 2, 3].map(function (k) { return { sera: piu(oggiRoma(), -k * 13 - 2), turno: ["20:00", "20:30", "21:00"][k % 3], persone: 2 + (k % 3), canale: ["instagram", "sito", "manuale:telefono", "google"][k], stato: "confermata", voto: k === 0 ? 5 : null, nota: k === 1 ? "Tavolo vicino alla finestra" : "", benvenuto: k === 3 ? 2 : 0 }; }),
      asporto: [{ sera: piu(oggiRoma(), -20), ritiro: "20:30", totale: 34, pezzi: 3, stato: "ritirato", righe: [{ nome: "Pizza Vico", qta: 2, prezzo: 12 }, { nome: "Tiramisù", qta: 1, prezzo: 6 }] }],
      premi: [{ tipo: "benvenuto", emoji: "🍹", nome: "Spritz o dolce offerto", dal: "2026-07-04", al: "2026-07-20", usato: "2026-07-11" },
        { tipo: "regalo", emoji: "🔥", nome: "30% di sconto sul conto", dal: "2026-10-27", al: "2026-11-15", usato: null }],
      campagne: [{ campagna: "regalo-thefork", gruppo: 1, aperto: "2026-10-26T11:40:00Z", premio: "TRENTA", scoperto: "2026-10-26T11:42:00Z", whatsapp: null, disiscritto: null }],
      whatsapp: { stop: false, ultimoMessaggio: "2026-10-20T19:05:00Z", ricevuti: 3, inviati: 7 },
    };
  }
  function cercaDemo(q) {
    q = String(q || "").toLowerCase();
    return NOMI.map(function (n, i) { return { telefono: "+39333" + String(1000000 + i * 7919).slice(-7), nome: n }; })
      .filter(function (x) { return x.nome.toLowerCase().indexOf(q) >= 0 || x.telefono.indexOf(q) >= 0; });
  }
  let periodiDemo = [{ id: 1, nome: "Regalo a sorpresa · clienti TheFork", tipo: "campagna", dal: CAMPAGNA_DEMO, al: null, note: "Email a gruppi + WhatsApp" },
    { id: 2, nome: "Chiusura per ferie", tipo: "chiusura", dal: "2026-08-10", al: "2026-08-24", note: "" }];
  const cassaDemo = {};
  function controlla(pin) { if (pin !== "1234") throw errore("pin", "PIN sbagliato"); }
  function attendi(fn) { return new Promise(function (ok, ko) { setTimeout(function () { try { ok(fn()); } catch (e) { ko(e); } }, 120); }); }

  const finto = {
    entra: function (pin) { return attendi(function () { controlla(pin); return true; }); },
    riepilogo: function (pin, dal, al) {
      return attendi(function () {
        controlla(pin);
        const r = riepilogoDemo(dal, al);
        r.giorni.forEach(function (x) { if (cassaDemo[x.g]) Object.assign(x, cassaDemo[x.g]); });
        return r;
      });
    },
    clienti: function (pin, dal, al) { return attendi(function () { controlla(pin); return clientiDemo(dal, al); }); },
    cerca: function (pin, q) { return attendi(function () { controlla(pin); return cercaDemo(q); }); },
    cliente: function (pin, tel) { return attendi(function () { controlla(pin); return clienteDemo(tel); }); },
    salute: function (pin) {
      return attendi(function () {
        controlla(pin);
        return { adesso: new Date().toISOString(), waCoda: 0, waErrori24h: 1, waUltimoErrore: "(#131026) Message undeliverable",
          waUltimoInvio: new Date(Date.now() - 36e5).toISOString(), waAcceso: true, avvisiFermi: 0, clubCoda: 0,
          erp: { collegato: true, creata: "2026-10-26T08:00:00Z", ultimoInvio: new Date(Date.now() - 5 * 36e5).toISOString(), ultimoEsito: "ok " + piu(oggiRoma(), -1) },
          ultimaSeraCassa: piu(oggiRoma(), -1), oggi: oggiRoma(),
          orologio: [{ lavoro: "whatsapp-invia", ultimo: new Date(Date.now() - 6e4).toISOString(), esito: "succeeded" },
            { lavoro: "pren-avvisa", ultimo: new Date(Date.now() - 18e4).toISOString(), esito: "succeeded" }] };
      });
    },
    impostazioni: function (pin) {
      return attendi(function () {
        controlla(pin);
        return { oggi: oggiRoma(), sera: oggiRoma(), periodi: periodiDemo.slice().sort(function (a, b) { return a.dal < b.dal ? 1 : -1; }),
          erp: { collegato: true, creata: "2026-10-26T08:00:00Z", ultimoInvio: new Date(Date.now() - 5 * 36e5).toISOString(), ultimoEsito: "ok" },
          inizio: { agenti: INIZIO_DEMO, club: INIZIO_DEMO, prenotazioni: INIZIO_DEMO, asporto: INIZIO_DEMO, ordini: INIZIO_DEMO, cassa: INIZIO_DEMO, sito: INIZIO_DEMO },
          campagne: [{ id: "regalo-thefork", nome: "Regalo a sorpresa · clienti TheFork" }] };
      });
    },
    campagne: function (pin) {
      return attendi(function () {
        controlla(pin);
        return [{ id: "regalo-thefork", nome: "Regalo a sorpresa · clienti TheFork", attiva: true, sere: 15, contatti: 384, aperti: 141,
          scoperti: 63, disiscritti: 5, prenotati: 29, usati: 11,
          premi: [{ emoji: "🎉", nome: "50% di sconto sul conto", usciti: 5, limite: 15 }, { emoji: "🔥", nome: "30% di sconto sul conto", usciti: 9, limite: 30 },
            { emoji: "⭐", nome: "20% di sconto sul conto", usciti: 16, limite: null }, { emoji: "🍕", nome: "10% di sconto sul conto", usciti: 7, limite: null },
            { emoji: "🥂", nome: "Prosecco di benvenuto", usciti: 10, limite: null }, { emoji: "🍰", nome: "Dolce della casa", usciti: 10, limite: null },
            { emoji: "🍹", nome: "Spritz offerto", usciti: 6, limite: null }],
          wa: { attivo: true, giorni: 3, inviati: 140, letti: 118, errori: 4, scopertiDopo: 22 },
          gruppi: [1, 2, 3, 4, 5, 6, 7, 8].map(function (g) { return { gruppo: g, contatti: g === 8 ? 34 : 50, scoperti: Math.max(0, 14 - g), whatsapp: Math.max(0, 40 - g * 5) }; }) }];
      });
    },
    periodoSalva: function (pin, p) {
      return attendi(function () {
        controlla(pin);
        if (!p.nome || p.nome.trim().length < 2) throw errore("nome", "Scrivi un nome");
        if (!p.dal || (p.al && p.al < p.dal)) throw errore("date", "Date non valide");
        if (p.id) periodiDemo = periodiDemo.map(function (x) { return x.id === p.id ? Object.assign({}, x, p) : x; });
        else periodiDemo.push(Object.assign({ id: Date.now() }, p));
        return periodiDemo.slice().sort(function (a, b) { return a.dal < b.dal ? 1 : -1; });
      });
    },
    periodoElimina: function (pin, id) {
      return attendi(function () { controlla(pin); periodiDemo = periodiDemo.filter(function (x) { return x.id !== id; }); return periodiDemo; });
    },
    cassaSalva: function (pin, sera, incasso, coperti, scontrini) {
      return attendi(function () {
        controlla(pin);
        if (incasso == null) delete cassaDemo[sera];
        else cassaDemo[sera] = { incasso: incasso, coperti: coperti, scontrini: scontrini };
        return { ok: true };
      });
    },
    erpChiave: function (pin) { return attendi(function () { controlla(pin); return { chiave: "DEMO-questa-non-e-una-chiave-vera-0000" }; }); },
    cassaArticoli: function (pin, dal, al) {
      return attendi(function () {
        controlla(pin);
        const gg = giorni(dal, al).map(giornoDemo).filter(function (x) { return x.incasso != null; }), r = caso("art" + dal + al);
        const nomi = ["MARGHERITA", "ACQUA NATURALE", "CHIARA MEDIA", "PIZZA VICO", "DIAVOLA", "TIRAMISU", "4 FORMAGGI", "CARBONARA",
          "CHITARRA ALLO SCOGLIO", "CALICE VINO ROSSO", "HAMBURGER", "PATATINE FRITTE", "POSITANO", "COCA COLA", "APEROL SPRTZ",
          "ENTRECOTE AL CHIANTI", "BRANZINO", "CAPRESE", "TORTA CAPRESE", "CHIANTI CLASSICO"];
        const prezzi = [8, 3.5, 5.5, 12, 9, 6.5, 12.5, 14, 18, 6, 15, 7, 10.5, 4, 8, 22, 19, 13.5, 7, 25];
        const sere = gg.length, coperti = gg.reduce(function (s, x) { return s + (x.coperti || 0); }, 0);
        const articoli = nomi.map(function (n, i) {
          const q = Math.round(coperti * (0.04 + r() * 0.25) * (i < 4 ? 1.8 : 1)); const lordo = q * prezzi[i], sc = Math.round(lordo * (0.02 + r() * 0.08) * 100) / 100;
          return { nome: n, codice: String(10 + i), qta: q, euro: Math.round((lordo - sc) * 100) / 100, sconti: sc, sere: sere };
        }).sort(function (a, b) { return b.euro - a.euro; });
        const incasso = gg.reduce(function (s, x) { return s + x.incasso; }, 0);
        return { sere: sere, conDettaglio: sere, sconti: Math.round(incasso * 0.07), coperto: Math.round(coperti * 2.5), abbuono: -Math.round(sere * 1.3),
          giorni: gg.map(function (x) { return { g: x.g, sconti: Math.round(x.incasso * 0.07), pezzi: Math.round(x.coperti * 3.6) }; }), articoli: articoli };
      });
    },
  };

  window.Dati = Object.assign({ DEMO: DEMO, oggiRoma: oggiRoma, piu: piu, giorni: giorni }, DEMO ? finto : vero);
})();
