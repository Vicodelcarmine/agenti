/* Dati dell'app agenti.

   Di norma parla con Supabase (database del Vico del Carmine, tabelle pr_*):
   i conti li fa il server (premio estratto, buono unico, provvigione) e nessun
   telefono può barare. Funzioni SQL: supabase/01-agenti.sql.

   DEMO: aggiungendo ?demo=1 all'indirizzo (vale per tutta la scheda del browser,
   ?demo=0 per uscire) si usa un server finto nella memoria del browser, con dati
   di prova. Utile per far vedere il sistema senza toccare i dati veri.
   VETRINA (?vetrina=1): come la demo, ma con dati "belli" e senza marchio, per le
   riprese del video; lì orari di chiusura e pause non bloccano mai il gioco. */

const Store = (function () {
  const DEMO = (function () {
    try {
      if (/[?&]demo=1/.test(location.search)) sessionStorage.setItem("vdcpr_demo", "1");
      if (/[?&]demo=0/.test(location.search)) sessionStorage.removeItem("vdcpr_demo");
      return sessionStorage.getItem("vdcpr_demo") === "1" || Comune.VETRINA;
    } catch (e) { return false; }
  })();
  const C = Comune;
  const CHIAVE = C.VETRINA ? "vdcpr_vetrina_v1" : "vdcpr_demo_v1";

  // Progetto Supabase del Vico del Carmine (la chiave "publishable" è pubblica: va bene nel sito)
  const SUPABASE_URL = "https://agbvmhpktilpaoabjkre.supabase.co";
  const SUPABASE_KEY = "sb_publishable_2O5l8ZbQqGnwDXwxZnsZ2Q_0Mt1V8T7";

  /* ---------- il "database" finto ---------- */
  function premiIniziali() {
    return [
      { id: "DOLCE", emoji: "🍰", peso: 15, attivo: true,
        nome: { it: "DOLCE OMAGGIO!", en: "FREE DESSERT!" },
        desc: { it: "Un dolce della casa offerto da noi!", en: "A homemade dessert on the house!" } },
      { id: "VENTI", emoji: "🔥", peso: 8, attivo: true,
        nome: { it: "-20% SUL CONTO!", en: "20% OFF!" },
        desc: { it: "Sconto del 20% sul conto totale di stasera!", en: "20% off your total bill tonight!" } },
      { id: "DIECI", emoji: "🍕", peso: 25, attivo: true,
        nome: { it: "-10% SUL CONTO!", en: "10% OFF!" },
        desc: { it: "Sconto del 10% sul conto totale di stasera!", en: "10% off your total bill tonight!" } },
      { id: "BOLLE", emoji: "🥂", peso: 15, attivo: true,
        nome: { it: "PROSECCO OMAGGIO!", en: "FREE PROSECCO!" },
        desc: { it: "Un calice di prosecco offerto dalla casa!", en: "A glass of prosecco on the house!" } },
      { id: "SPRITZ", emoji: "🍹", peso: 10, attivo: true,
        nome: { it: "SPRITZ OMAGGIO!", en: "FREE SPRITZ!" },
        desc: { it: "Uno Spritz Aperol o Hugo offerto da noi!", en: "A free Aperol or Hugo Spritz!" } },
      { id: "CAFFE", emoji: "🧁", peso: 20, attivo: true,
        nome: { it: "CAFFÈ + DOLCETTO!", en: "COFFEE + SWEET!" },
        desc: { it: "Caffè e un dolcetto della casa offerti!", en: "Coffee and a sweet treat on the house!" } },
      { id: "QUINDICI", emoji: "⭐", peso: 7, attivo: true,
        nome: { it: "-15% SUL CONTO!", en: "15% OFF!" },
        desc: { it: "Sconto del 15% sul conto totale di stasera!", en: "15% off your total bill tonight!" } },
    ];
  }

  function nuovoAgente(id, codice, chiave, nome, attivo, giorniFa) {
    return { id: id, codice: codice, chiave: chiave || C.casuale(16), nome: nome, telefono: "", attivo: attivo,
      bonus: true, validita: 1,
      fasce: C.FASCE_STANDARD.map(function (f) { return Object.assign({}, f); }), creato: Date.now() - giorniFa * 864e5 };
  }

  // qualche serata finta, così le pagine non sono vuote.
  // storia: [giorni fa, agente, tavoli (persone) arrivati, giocate senza arrivo]
  function costruisci(agenti, storia, pagamenti) {
    const db = {
      impostazioni: { chiusura: "23:30", pin: "1234", fasce: C.FASCE_STANDARD.map(function (f) { return Object.assign({}, f); }),
        bonusGiorni: 7, bonusPer: 2, giorniPausa: [6] },
      agenti: agenti,
      premi: premiIniziali(),
      buoni: [],
      pagamenti: [],
    };
    const adesso = Date.now();
    storia.forEach(function (r) {
      const oggi = r[0] === 0;
      const laSera = C.sera(adesso - r[0] * 864e5);
      const ag = db.agenti.find(function (a) { return a.id === r[1]; });
      const fasce = fasceSera(db, ag, laSera);
      let gia = 0, minuti = 0;
      const crea = function (persone) {
        const p = db.premi[Math.floor(Math.random() * db.premi.length)];
        minuti += 9 + Math.floor(Math.random() * 25);
        const creato = oggi ? adesso - (200 - minuti) * 60e3 : C.scadenza(laSera, "20:00").getTime() + minuti * 60e3;
        const b = {
          codice: C.casuale(6), agente: ag.id, premio: istantanea(p), creato: creato, sera: laSera,
          scade: C.scadenza(laSera, db.impostazioni.chiusura).getTime(), dispositivo: C.casuale(12), stato: "attivo",
        };
        if (persone) {
          const pr = C.provvigione(fasce, gia, persone);
          gia += persone;
          const riscattato = oggi ? Math.min(creato + 25 * 60e3, adesso - 60e3) : creato + 25 * 60e3;
          Object.assign(b, { stato: "riscattato", riscattato: riscattato, seraRiscatto: laSera, persone: persone, euro: pr.euro });
        }
        db.buoni.push(b);
      };
      r[2].forEach(crea);
      for (let i = 0; i < r[3]; i++) crea(0);
    });
    pagamenti.forEach(function (p) {
      db.pagamenti.push({ id: C.casuale(8), agente: p[0], importo: p[1], data: adesso - p[2] * 864e5, nota: p[3] });
    });
    return db;
  }

  function datiIniziali() {
    if (C.VETRINA) {
      // per le riprese: Marco è nella sua settimana di benvenuto (tariffe doppie)
      return costruisci(
        [nuovoAgente("a1", "MRC7K", "VETRINAMARCO", "Marco", true, 3),
         nuovoAgente("a2", "GLA4R", "VETRINAGIULIA", "Giulia", true, 24),
         nuovoAgente("a3", "LCA3P", "VETRINALUCA", "Luca", false, 15)],
        [[2, "a1", [4, 2, 5], 4], [1, "a1", [3, 6, 2, 4], 5], [0, "a1", [4, 3], 3],
         [9, "a2", [6, 4, 2, 3], 6], [6, "a2", [5, 3, 4, 2, 6], 7], [3, "a2", [2, 4, 3], 3], [0, "a2", [5, 2], 2],
         [12, "a3", [3, 2], 3]],
        [["a2", 80, 5, "contanti"], ["a3", 10, 10, "contanti"]]);
    }
    return costruisci(
      [nuovoAgente("a1", "MRC7K", null, "Marco (prova)", true, 20),
       nuovoAgente("a2", "LCA3P", null, "Luca (prova)", false, 9)],
      [[12, "a1", [4, 2, 6, 3], 5], [9, "a1", [2, 2, 5], 4], [8, "a2", [3, 2], 3],
       [5, "a1", [6, 4, 3, 2, 5], 6], [3, "a1", [2, 3], 2], [2, "a2", [4], 2], [0, "a1", [4, 3], 3]],
      [["a1", 40, 6, "contanti"]]);
  }

  /* ---------- settimana di benvenuto e giorni di pausa ---------- */
  function impostazioniDi(db) {
    return Object.assign({ bonusGiorni: 7, bonusPer: 2, giorniPausa: [6] }, db.impostazioni);
  }
  // la n-esima sera di servizio a partire da laSera compresa, SALTANDO i giorni di pausa (il sabato non si conta mai)
  function piuSere(db, laSera, n) {
    const pausa = impostazioniDi(db).giorniPausa;
    let d = laSera, contate = 0;
    for (let i = 0; i < n + 60; i++) {
      if (pausa.indexOf(C.giornoSettimana(d)) < 0 && ++contate === n) return d;
      d = C.piuGiorni(d, 1);
    }
    return C.piuGiorni(laSera, n - 1);
  }
  // ultima sera della settimana di benvenuto, contata da quando l'agente è stato creato
  function bonusPeriodo(db, a) {
    const i = impostazioniDi(db);
    if (!(i.bonusGiorni > 0 && i.bonusPer > 1)) return null;
    return piuSere(db, C.sera(a.creato), i.bonusGiorni);
  }
  // come sopra, ma solo se per quell'agente il bonus è acceso (null = niente bonus)
  function bonusUltima(db, a) {
    return a.bonus === false ? null : bonusPeriodo(db, a);
  }
  function bonusFino(db, a) {
    const u = bonusUltima(db, a);
    return u && u >= C.sera() ? u : null;
  }
  function fasceSera(db, a, laSera) {
    const u = bonusUltima(db, a);
    if (!u || laSera > u) return a.fasce;
    const k = impostazioniDi(db).bonusPer;
    return a.fasce.map(function (f) { return { fino: f.fino, euro: Math.round(f.euro * k * 100) / 100 }; });
  }
  function inPausa(db, laSera) {
    return !C.VETRINA && impostazioniDi(db).giorniPausa.indexOf(C.giornoSettimana(laSera)) >= 0;
  }

  function istantanea(p) {
    return { id: p.id, emoji: p.emoji, nome: Object.assign({}, p.nome), desc: Object.assign({}, p.desc) };
  }

  function leggi() {
    let db = null;
    try { db = JSON.parse(localStorage.getItem(CHIAVE)); } catch (e) {}
    if (!db) { db = datiIniziali(); scrivi(db); }
    return db;
  }
  function scrivi(db) { try { localStorage.setItem(CHIAVE, JSON.stringify(db)); } catch (e) {} }
  // finta attesa di rete, per vedere come si comporta l'interfaccia
  function rete(fn) {
    return new Promise(function (ok, ko) {
      setTimeout(function () { try { ok(fn()); } catch (e) { ko(e); } }, 140);
    });
  }
  function errore(codice, msg) { const e = new Error(msg); e.codice = codice; return e; }
  function controllaPin(db, pin) { if (String(pin) !== String(db.impostazioni.pin)) throw errore("pin", "PIN sbagliato"); }
  function agenteDa(db, id) {
    const a = db.agenti.find(function (x) { return x.id === id; });
    if (!a) throw errore("agente", "Agente non trovato");
    return a;
  }

  /* ---------- numeri ---------- */
  // la sera in cui il tavolo si è seduto: conta per scaglioni e guadagni (può essere dopo quella del gioco)
  function seraRiscatto(b) { return b.seraRiscatto || b.sera; }
  function riepilogo(db, agenteId) {
    const stasera = C.sera(), mese = stasera.slice(0, 7);
    const suoi = db.buoni.filter(function (b) { return b.agente === agenteId; });
    const ok = suoi.filter(function (b) { return b.stato === "riscattato"; });
    const somma = function (l, k) { return l.reduce(function (s, b) { return s + (b[k] || 0); }, 0); };
    const dis = ok.filter(function (b) { return seraRiscatto(b) === stasera; });
    const delMese = ok.filter(function (b) { return seraRiscatto(b).slice(0, 7) === mese; });
    const pagato = db.pagamenti.filter(function (p) { return p.agente === agenteId; })
      .reduce(function (s, p) { return s + p.importo; }, 0);
    const maturato = somma(ok, "euro");
    return {
      stasera: { giocate: suoi.filter(function (b) { return b.sera === stasera; }).length,
        tavoli: dis.length, persone: somma(dis, "persone"), euro: somma(dis, "euro") },
      mese: { nome: C.nomeMese(stasera), tavoli: delMese.length, persone: somma(delMese, "persone"), euro: somma(delMese, "euro") },
      maturato: maturato, pagato: pagato, daPagare: Math.round((maturato - pagato) * 100) / 100,
    };
  }
  function serate(db, agenteId) {
    const per = {};
    const di = function (sera) { return per[sera] || (per[sera] = { sera: sera, giocate: 0, tavoli: 0, persone: 0, euro: 0 }); };
    db.buoni.filter(function (b) { return b.agente === agenteId; }).forEach(function (b) {
      di(b.sera).giocate++;
      if (b.stato === "riscattato") {
        const r = di(seraRiscatto(b));
        r.tavoli++; r.persone += b.persone; r.euro += b.euro;
      }
    });
    return Object.values(per).sort(function (a, b) { return a.sera < b.sera ? 1 : -1; });
  }
  function vistaBuono(db, b) {
    let stato = b.stato;
    if (stato === "attivo" && Date.now() >= b.scade && !C.VETRINA) stato = "scaduto";
    return { codice: b.codice, premio: b.premio, creato: b.creato, scade: b.scade, stato: stato,
      persone: b.persone, euro: b.euro, riscattato: b.riscattato };
  }

  /* ================= CLIENTE (pagina del gioco) ================= */

  function agentePubblico(codice) {
    return rete(function () {
      const db = leggi();
      const a = db.agenti.find(function (x) { return x.codice === codice; });
      if (!a) throw errore("agente", "QR non valido");
      return { attivo: a.attivo, pausa: inPausa(db, C.sera()) };
    });
  }

  // gira la slot: il premio lo sceglie il "server", non il telefono
  function gioca(codiceAgente, dispositivo) {
    return rete(function () {
      const db = leggi();
      const a = db.agenti.find(function (x) { return x.codice === codiceAgente; });
      if (!a || !a.attivo) throw errore("agente", "QR non attivo");
      const adesso = Date.now(), laSera = C.sera(adesso);
      if (inPausa(db, laSera)) throw errore("pausa", "Stasera siamo al completo");
      // il buono vale fino alla chiusura dell'ultima sera di validità di quell'agente (il sabato non si conta)
      const scade = C.scadenza(piuSere(db, laSera, a.validita || 1), db.impostazioni.chiusura).getTime();
      if (adesso >= scade && !C.VETRINA) throw errore("chiuso", "Per stasera abbiamo chiuso");
      const gia = db.buoni.filter(function (b) {
        return b.dispositivo === dispositivo && (b.sera === laSera || (b.stato === "attivo" && b.scade > adesso));
      }).sort(function (x, y) { return y.creato - x.creato; })[0];
      if (gia) return Object.assign(vistaBuono(db, gia), { gia: true });
      const premi = db.premi.filter(function (p) { return p.attivo && p.peso > 0; });
      if (!premi.length) throw errore("premi", "Nessun premio disponibile");
      const tot = premi.reduce(function (s, p) { return s + p.peso; }, 0);
      let r = Math.random() * tot, scelto = premi[0];
      for (const p of premi) { r -= p.peso; if (r <= 0) { scelto = p; break; } }
      let codice;
      do { codice = C.casuale(6); } while (db.buoni.some(function (b) { return b.codice === codice; }));
      const b = { codice: codice, agente: a.id, premio: istantanea(scelto), creato: adesso, sera: laSera,
        scade: scade, dispositivo: dispositivo, stato: "attivo" };
      db.buoni.push(b);
      scrivi(db);
      return vistaBuono(db, b);
    });
  }

  function buono(codice) {
    return rete(function () {
      const db = leggi();
      const b = db.buoni.find(function (x) { return x.codice === codice; });
      if (!b) throw errore("buono", "Buono non trovato");
      return vistaBuono(db, b);
    });
  }

  /* ================= AGENTE ================= */

  function agente(chiave) {
    return rete(function () {
      const db = leggi();
      const a = db.agenti.find(function (x) { return x.chiave === chiave; });
      if (!a) throw errore("chiave", "Link non valido");
      const ultimi = db.buoni.filter(function (b) { return b.agente === a.id && b.stato === "riscattato"; })
        .sort(function (x, y) { return y.riscattato - x.riscattato; }).slice(0, 12)
        .map(function (b) { return { quando: b.riscattato, sera: seraRiscatto(b), persone: b.persone, euro: b.euro }; });
      return Object.assign({ nome: a.nome, codice: a.codice, attivo: a.attivo,
        fasce: fasceSera(db, a, C.sera()), fasceBase: a.fasce, bonusFino: bonusFino(db, a),
        bonusPer: impostazioniDi(db).bonusPer, pausa: inPausa(db, C.sera()), validita: a.validita || 1,
        ultimi: ultimi }, riepilogo(db, a.id));
    });
  }

  /* ================= TITOLARE ================= */

  function entra(pin) { return rete(function () { controllaPin(leggi(), pin); return true; }); }

  function leggiBuono(pin, codice) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      const b = db.buoni.find(function (x) { return x.codice === codice; });
      if (!b) throw errore("buono", "Nessun buono con questo codice");
      const a = agenteDa(db, b.agente);
      const stasera = C.sera();
      const giaStasera = db.buoni.filter(function (x) {
        return x.agente === a.id && seraRiscatto(x) === stasera && x.stato === "riscattato" && x.codice !== b.codice;
      }).reduce(function (s, x) { return s + x.persone; }, 0);
      return Object.assign(vistaBuono(db, b), {
        agente: { id: a.id, nome: a.nome, attivo: a.attivo }, fasce: fasceSera(db, a, stasera), giaStasera: giaStasera,
        bonus: !!(bonusUltima(db, a) && stasera <= bonusUltima(db, a)), seraGioco: b.sera,
        annullabile: b.stato === "riscattato" && ultimoDellaSera(db, b),
      });
    });
  }
  function ultimoDellaSera(db, b) {
    const dopo = db.buoni.some(function (x) {
      return x.agente === b.agente && seraRiscatto(x) === seraRiscatto(b) && x.stato === "riscattato" && x.riscattato > b.riscattato;
    });
    return !dopo;
  }

  function riscatta(pin, codice, persone) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      persone = parseInt(persone, 10);
      if (!(persone >= 1 && persone <= 60)) throw errore("persone", "Numero di persone non valido");
      const b = db.buoni.find(function (x) { return x.codice === codice; });
      if (!b) throw errore("buono", "Nessun buono con questo codice");
      if (b.stato === "riscattato") throw errore("usato", "Buono già usato");
      if (Date.now() >= b.scade && !C.VETRINA) throw errore("scaduto", "Buono scaduto");
      const a = agenteDa(db, b.agente);
      const stasera = C.sera();
      const gia = db.buoni.filter(function (x) {
        return x.agente === a.id && seraRiscatto(x) === stasera && x.stato === "riscattato";
      }).reduce(function (s, x) { return s + x.persone; }, 0);
      const fasce = fasceSera(db, a, stasera);
      const pr = C.provvigione(fasce, gia, persone);
      Object.assign(b, { stato: "riscattato", riscattato: Date.now(), seraRiscatto: stasera, persone: persone, euro: pr.euro });
      scrivi(db);
      return { euro: pr.euro, righe: pr.righe, agente: a.nome, premio: b.premio };
    });
  }

  // solo l'ultimo tavolo della sera di quell'agente, così i conti restano giusti
  function annulla(pin, codice) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      const b = db.buoni.find(function (x) { return x.codice === codice; });
      if (!b || b.stato !== "riscattato") throw errore("buono", "Niente da annullare");
      if (!ultimoDellaSera(db, b)) throw errore("ordine", "Si può annullare solo l'ultimo tavolo di quell'agente");
      b.stato = "attivo";
      delete b.riscattato; delete b.seraRiscatto; delete b.persone; delete b.euro;
      scrivi(db);
      return true;
    });
  }

  function panoramica(pin) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      const stasera = C.sera();
      const agenti = db.agenti.map(function (a) {
        return Object.assign({ id: a.id, nome: a.nome, telefono: a.telefono, attivo: a.attivo, codice: a.codice,
          validita: a.validita || 1, bonusFino: bonusFino(db, a) }, riepilogo(db, a.id));
      });
      const nome = {};
      db.agenti.forEach(function (a) { nome[a.id] = a.nome; });
      const tavoli = db.buoni.filter(function (b) { return seraRiscatto(b) === stasera && b.stato === "riscattato"; })
        .sort(function (x, y) { return y.riscattato - x.riscattato; })
        .map(function (b) {
          return { codice: b.codice, agente: nome[b.agente], quando: b.riscattato, persone: b.persone,
            euro: b.euro, premio: b.premio, annullabile: ultimoDellaSera(db, b) };
        });
      const inAttesa = db.buoni.filter(function (b) { return b.stato === "attivo" && Date.now() < b.scade; }).length;
      return { agenti: agenti, tavoli: tavoli, inAttesa: inAttesa,
        giocate: db.buoni.filter(function (b) { return b.sera === stasera; }).length,
        chiusura: db.impostazioni.chiusura, richieste: (db.candidature || []).length };
    });
  }

  function dettaglioAgente(pin, id) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      const a = agenteDa(db, id);
      const periodo = bonusPeriodo(db, a);
      return Object.assign({}, a, riepilogo(db, id), {
        bonus: a.bonus !== false, validita: a.validita || 1, bonusFino: bonusFino(db, a), bonusPer: impostazioniDi(db).bonusPer,
        bonusPeriodo: periodo && periodo >= C.sera() ? periodo : null,
        serate: serate(db, id),
        pagamenti: db.pagamenti.filter(function (p) { return p.agente === id; })
          .sort(function (x, y) { return y.data - x.data; }),
      });
    });
  }

  function salvaAgente(pin, dati) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      let a;
      if (dati.id) a = agenteDa(db, dati.id);
      else {
        let codice;
        do { codice = C.casuale(5); } while (db.agenti.some(function (x) { return x.codice === codice; }));
        a = { id: "a" + C.casuale(6), codice: codice, chiave: C.casuale(16), attivo: true, creato: Date.now(),
          fasce: db.impostazioni.fasce.map(function (f) { return Object.assign({}, f); }) };
        db.agenti.push(a);
      }
      if (dati.nome != null) a.nome = String(dati.nome).trim() || "Agente";
      if (dati.telefono != null) a.telefono = String(dati.telefono).trim();
      if (dati.attivo != null) a.attivo = !!dati.attivo;
      if (dati.bonus != null) a.bonus = !!dati.bonus;
      if (dati.validita != null) {
        const v = String(dati.validita);
        if (!/^[1-7]$/.test(v)) throw errore("validita", "Validità non valida (da 1 a 7 giorni)");
        a.validita = +v;
      }
      if (dati.fasce) a.fasce = controllaFasce(dati.fasce);
      scrivi(db);
      return a;
    });
  }
  function controllaFasce(fasce) {
    let prima = 0;
    const out = fasce.map(function (f, i) {
      const ultima = i === fasce.length - 1;
      const fino = ultima ? null : parseInt(f.fino, 10);
      const e = Math.round(parseFloat(String(f.euro).replace(",", ".")) * 100) / 100;
      if (!ultima && !(fino > prima)) throw errore("fasce", "Le fasce devono salire (es. 10, poi 20)");
      if (!(e >= 0)) throw errore("fasce", "Importo non valido");
      if (!ultima) prima = fino;
      return { fino: fino, euro: e };
    });
    return out;
  }

  function nuovaChiave(pin, id) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      const a = agenteDa(db, id);
      a.chiave = C.casuale(16);
      scrivi(db);
      return a.chiave;
    });
  }

  function eliminaAgente(pin, id) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      const a = agenteDa(db, id);
      const tavoli = db.buoni.filter(function (b) { return b.agente === id && b.stato === "riscattato"; }).length;
      db.buoni = db.buoni.filter(function (b) { return b.agente !== id; });
      db.pagamenti = db.pagamenti.filter(function (p) { return p.agente !== id; });
      db.agenti = db.agenti.filter(function (x) { return x.id !== id; });
      scrivi(db);
      return { nome: a.nome, tavoli: tavoli };
    });
  }

  function pagamento(pin, agenteId, importo, nota) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      agenteDa(db, agenteId);
      importo = Math.round(parseFloat(String(importo).replace(",", ".")) * 100) / 100;
      if (!(importo > 0)) throw errore("importo", "Importo non valido");
      db.pagamenti.push({ id: C.casuale(8), agente: agenteId, importo: importo, data: Date.now(), nota: nota || "" });
      scrivi(db);
      return true;
    });
  }

  function premi(pin) {
    return rete(function () { const db = leggi(); controllaPin(db, pin); return db.premi; });
  }
  function salvaPremi(pin, lista) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      if (!lista.some(function (p) { return p.attivo && p.peso > 0; })) {
        throw errore("premi", "Serve almeno un premio attivo");
      }
      db.premi = lista.map(function (p) {
        return { id: p.id || C.casuale(6), emoji: p.emoji || "🎁", peso: Math.max(0, parseInt(p.peso, 10) || 0),
          attivo: !!p.attivo, nome: { it: p.nome.it || "", en: p.nome.en || "" }, desc: { it: p.desc.it || "", en: p.desc.en || "" } };
      });
      scrivi(db);
      return db.premi;
    });
  }

  function impostazioni(pin) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      const i = impostazioniDi(db);
      return { chiusura: i.chiusura, fasce: i.fasce, bonusGiorni: i.bonusGiorni, bonusPer: i.bonusPer, giorniPausa: i.giorniPausa };
    });
  }
  function salvaImpostazioni(pin, dati) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      if (dati.chiusura) {
        if (!/^\d{2}:\d{2}$/.test(dati.chiusura)) throw errore("ora", "Orario non valido");
        db.impostazioni.chiusura = dati.chiusura;
        // i buoni ancora da usare seguono il nuovo orario (ognuno nella sua ultima sera di validità)
        const adesso = Date.now();
        db.buoni.forEach(function (b) {
          if (b.stato === "attivo" && b.scade > adesso) b.scade = C.scadenza(C.sera(b.scade), dati.chiusura).getTime();
        });
      }
      if (dati.fasce) db.impostazioni.fasce = controllaFasce(dati.fasce);
      if (dati.bonusGiorni != null) {
        const g = String(dati.bonusGiorni).trim();
        if (!/^\d{1,2}$/.test(g) || +g > 60) throw errore("bonus", "Giorni di benvenuto non validi (da 0 a 60)");
        db.impostazioni.bonusGiorni = +g;
      }
      if (dati.bonusPer != null) {
        const k = String(dati.bonusPer).trim().replace(",", ".");
        if (!/^\d(\.\d{1,2})?$/.test(k) || +k < 1 || +k > 5) throw errore("bonus", "Moltiplicatore non valido (da 1 a 5)");
        db.impostazioni.bonusPer = +k;
      }
      if (dati.giorniPausa) {
        db.impostazioni.giorniPausa = dati.giorniPausa.map(Number).filter(function (g) { return g >= 0 && g <= 6; })
          .filter(function (g, i, l) { return l.indexOf(g) === i; }).sort();
      }
      scrivi(db);
      return true;
    });
  }

  /* ================= DIVENTA AGENTE ================= */

  function candidatura(nome, telefono, ruolo, note) {
    return rete(function () {
      const db = leggi();
      nome = String(nome || "").trim().slice(0, 80);
      const tel = String(telefono || "").replace(/[^0-9+]/g, "");
      if (nome.length < 2) throw errore("nome", "Scrivi il tuo nome");
      if (tel.replace(/\D/g, "").length < 8 || tel.length > 16) throw errore("telefono", "Numero di telefono non valido");
      db.candidature = db.candidature || [];
      db.candidature.push({ id: C.casuale(10), creato: Date.now(), nome: nome, telefono: tel,
        ruolo: String(ruolo || "").slice(0, 40), note: String(note || "").trim().slice(0, 500) });
      scrivi(db);
      return true;
    });
  }
  function candidature(pin) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      return (db.candidature || []).slice().sort(function (x, y) { return y.creato - x.creato; });
    });
  }
  function scartaCandidatura(pin, id) {
    return rete(function () {
      const db = leggi();
      controllaPin(db, pin);
      const prima = (db.candidature || []).length;
      db.candidature = (db.candidature || []).filter(function (c) { return c.id !== id; });
      if (db.candidature.length === prima) throw errore("candidatura", "Richiesta non trovata");
      scrivi(db);
      return true;
    });
  }
  async function approvaCandidatura(pin, id, bonus) {
    const lista = await candidature(pin);
    const c = lista.find(function (x) { return x.id === id; });
    if (!c) throw errore("candidatura", "Richiesta non trovata");
    const a = await salvaAgente(pin, { nome: c.nome, telefono: c.telefono, bonus: bonus !== false });
    await scartaCandidatura(pin, id);
    return a;
  }

  /* ================= CLUB DEL VICO (demo) =================
     La stessa memoria la usa il menu in prova (menu/?demo=1): in anteprima
     un cliente si iscrive nel menu e il suo premio si riscatta qui. */
  const CLUB = "vdcclub_demo_v1";
  function clubImpostazioniBase() {
    return { emoji: "🍹", nome: { it: "Spritz o dolce offerto", en: "Free spritz or dessert" },
      persone: 2, sere: 14, giorniNo: [6], giorniChiusura: [] };
  }
  // la n-esima sera a partire da s compresa, saltando i giorni esclusi (il sabato non si conta mai)
  function clubPiuSere(s, n, giorni) {
    let d = s, contate = 0;
    for (let i = 0; i < n * 7 + 7; i++) {
      if (giorni.indexOf(C.giornoSettimana(d)) < 0 && ++contate === n) return d;
      d = C.piuGiorni(d, 1);
    }
    return C.piuGiorni(s, n - 1);
  }
  function clubPremioNuovo(db, iscritto, tipo, dal) {
    const imp = db.impostazioni, g = imp.giorniNo.concat(imp.giorniChiusura);
    const d1 = clubPiuSere(dal, 1, g);
    let codice;
    do { codice = C.casuale(7); } while (db.premi.some(function (p) { return p.codice === codice; }));
    const p = { codice: codice, iscritto: iscritto, tipo: tipo, emoji: imp.emoji, nome: Object.assign({}, imp.nome),
      persone: imp.persone, dal: d1, al: clubPiuSere(d1, imp.sere, g), giorniNo: g, creato: Date.now(), usato: null, seraUso: null };
    db.premi.push(p);
    return p;
  }
  function clubDatiIniziali() {
    // qualche iscritto finto, così la scheda Club non è vuota
    const db = { impostazioni: clubImpostazioniBase(), iscritti: [], premi: [] };
    const oggi = C.sera();
    const persona = function (nome, email, tel, nascita, giorniFa, promo) {
      const i = { id: "c" + C.casuale(8), chiave: C.casuale(24), nome: nome, email: email, telefono: tel, nascita: nascita,
        promo: promo, promoQuando: promo ? Date.now() - giorniFa * 864e5 : null, lingua: "it", creato: Date.now() - giorniFa * 864e5 };
      db.iscritti.push(i);
      return i;
    };
    // compleanno fra 3 giorni (stesso mese e giorno, anno di nascita 1994)
    const fra3 = C.piuGiorni(oggi, 3);
    const a = persona("Giulia Rossi", "giulia.rossi@example.com", "+393331112233", "1994" + fra3.slice(4), 5, true);
    clubPremioNuovo(db, a.id, "benvenuto", C.piuGiorni(oggi, -4));
    const b = persona("Marco Bianchi", "marco.b@example.com", "+393474455667", "1988-03-12", 0, false);
    clubPremioNuovo(db, b.id, "benvenuto", C.piuGiorni(oggi, 1));
    const c = persona("Sara Verdi", "sara.verdi@example.com", "+393201234567", "2000-11-02", 20, true);
    const pc = clubPremioNuovo(db, c.id, "benvenuto", C.piuGiorni(oggi, -19));
    pc.usato = Date.now() - 12 * 864e5; pc.seraUso = C.sera(pc.usato);
    return db;
  }
  function clubLeggi() {
    let db = null;
    try { db = JSON.parse(localStorage.getItem(CLUB)); } catch (e) {}
    if (!db) { db = clubDatiIniziali(); clubScrivi(db); }
    db.impostazioni = Object.assign(clubImpostazioniBase(), db.impostazioni);
    return db;
  }
  function clubScrivi(db) { try { localStorage.setItem(CLUB, JSON.stringify(db)); } catch (e) {} }
  function clubScade(p) { return C.scadenza(p.al, leggi().impostazioni.chiusura).getTime(); }
  function clubStato(p) {
    const s = C.sera();
    if (p.usato) return "usato";
    if (Date.now() >= clubScade(p)) return "scaduto";
    if (s < p.dal) return "presto";
    if (p.giorniNo.indexOf(C.giornoSettimana(s)) >= 0) return "oggi_no";
    return "valido";
  }
  function clubVista(p) {
    return { codice: p.codice, tipo: p.tipo, emoji: p.emoji, nome: p.nome, persone: p.persone, dal: p.dal, al: p.al,
      scade: clubScade(p), giorniNo: p.giorniNo, creato: p.creato, usato: p.usato, stato: clubStato(p) };
  }
  function clubAperto(p) { const st = clubStato(p); return st === "valido" || st === "presto" || st === "oggi_no"; }
  function prossimoCompleanno(nascita, s) {
    for (let k = 0; k <= 1; k++) {
      const y = +s.slice(0, 4) + k;
      let d = y + nascita.slice(4);
      if (nascita.slice(5) === "02-29" && !(y % 4 === 0 && (y % 100 !== 0 || y % 400 === 0))) d = y + "-02-28";
      if (d >= s) return d;
    }
    return s;
  }
  function clubPremioDa(db, codice) {
    const p = db.premi.find(function (x) { return x.codice === codice; });
    if (!p) throw errore("premio", "Nessun premio del Club con questo codice");
    return p;
  }
  function clubLettura(db, p) {
    const i = db.iscritti.find(function (x) { return x.id === p.iscritto; }) || {};
    return Object.assign(clubVista(p), {
      iscritto: { id: i.id, nome: i.nome, telefono: i.telefono, nascita: i.nascita },
      annullabile: !!p.usato && p.seraUso === C.sera() });
  }

  function clubPanoramica(pin) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = clubLeggi(), s = C.sera();
      const nome = {};
      db.iscritti.forEach(function (i) { nome[i.id] = i.nome; });
      return {
        iscritti: db.iscritti.length,
        nuovi: db.iscritti.filter(function (i) { return i.creato > Date.now() - 7 * 864e5; }).length,
        promo: db.iscritti.filter(function (i) { return i.promo; }).length,
        attivi: db.premi.filter(clubAperto).length,
        usatiMese: db.premi.filter(function (p) { return p.seraUso && p.seraUso.slice(0, 7) === s.slice(0, 7); }).length,
        stasera: db.premi.filter(function (p) { return p.seraUso === s; })
          .sort(function (x, y) { return y.usato - x.usato; })
          .map(function (p) { return { codice: p.codice, nome: nome[p.iscritto], emoji: p.emoji, premio: p.nome, persone: p.persone, tipo: p.tipo, quando: p.usato }; }),
        compleanni: db.iscritti.map(function (i) { return { id: i.id, nome: i.nome, telefono: i.telefono, nascita: i.nascita, giorno: prossimoCompleanno(i.nascita, s) }; })
          .filter(function (x) { return x.giorno <= C.piuGiorni(s, 7); })
          .sort(function (x, y) { return x.giorno < y.giorno ? -1 : x.giorno > y.giorno ? 1 : 0; }),
      };
    });
  }
  function clubElenco(pin, cerca) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = clubLeggi();
      const q = String(cerca || "").trim().toLowerCase(), cifre = String(cerca || "").replace(/\D/g, "");
      return db.iscritti.filter(function (i) {
        return !q || i.nome.toLowerCase().indexOf(q) >= 0 || i.email.indexOf(q) >= 0 || (cifre.length >= 3 && i.telefono.indexOf(cifre) >= 0);
      }).sort(function (x, y) { return y.creato - x.creato; }).map(function (i) {
        return { id: i.id, nome: i.nome, telefono: i.telefono, email: i.email, nascita: i.nascita, creato: i.creato, promo: i.promo,
          premi: db.premi.filter(function (p) { return p.iscritto === i.id && clubAperto(p); }).length };
      });
    });
  }
  function clubDettaglio(pin, id) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = clubLeggi();
      const i = db.iscritti.find(function (x) { return x.id === id; });
      if (!i) throw errore("iscritto", "Iscritto non trovato");
      return Object.assign({}, i, { premi: db.premi.filter(function (p) { return p.iscritto === id; })
        .sort(function (x, y) { return y.creato - x.creato; }).map(clubVista) });
    });
  }
  function clubLeggiPremio(pin, codice) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = clubLeggi();
      return clubLettura(db, clubPremioDa(db, codice));
    });
  }
  function clubUsa(pin, codice, forza) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = clubLeggi();
      const p = clubPremioDa(db, codice);
      const st = clubStato(p);
      if (st === "usato") throw errore("usato", "Premio già usato");
      if (st !== "valido" && !forza) throw errore(st, "Stasera questo premio non vale");
      p.usato = Date.now(); p.seraUso = C.sera();
      clubScrivi(db);
      return clubLettura(db, p);
    });
  }
  function clubAnnulla(pin, codice) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = clubLeggi();
      const p = clubPremioDa(db, codice);
      if (!p.usato) throw errore("premio", "Niente da annullare");
      if (p.seraUso !== C.sera()) throw errore("tardi", "Si può annullare solo la sera stessa");
      p.usato = null; p.seraUso = null;
      clubScrivi(db);
      return true;
    });
  }
  function clubImpostazioni(pin) {
    return rete(function () { controllaPin(leggi(), pin); return clubLeggi().impostazioni; });
  }
  function clubSalvaImpostazioni(pin, dati) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = clubLeggi(), imp = db.impostazioni;
      const giorni = function (l) {
        return (l || []).map(Number).filter(function (g, i, a) { return g >= 0 && g <= 6 && a.indexOf(g) === i; }).sort();
      };
      if (dati.emoji != null) imp.emoji = String(dati.emoji).trim() || "🎁";
      if (dati.nome) {
        if (!String(dati.nome.it || "").trim()) throw errore("nome", "Scrivi il nome del premio");
        imp.nome = { it: String(dati.nome.it).trim(), en: String(dati.nome.en || "").trim() };
      }
      if (dati.persone != null) {
        const n = String(dati.persone).trim();
        if (!/^\d{1,2}$/.test(n) || +n < 1 || +n > 20) throw errore("persone", "Persone non valide (da 1 a 20)");
        imp.persone = +n;
      }
      if (dati.sere != null) {
        const n = String(dati.sere).trim();
        if (!/^\d{1,2}$/.test(n) || +n < 1 || +n > 90) throw errore("sere", "Durata non valida (da 1 a 90 sere)");
        imp.sere = +n;
      }
      if (dati.giorniNo) imp.giorniNo = giorni(dati.giorniNo);
      if (dati.giorniChiusura) imp.giorniChiusura = giorni(dati.giorniChiusura);
      if (giorni(imp.giorniNo.concat(imp.giorniChiusura)).length >= 7) throw errore("giorni", "Almeno una sera della settimana deve restare valida");
      clubScrivi(db);
      return imp;
    });
  }
  function clubElimina(pin, id) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = clubLeggi();
      if (!db.iscritti.some(function (i) { return i.id === id; })) throw errore("iscritto", "Iscritto non trovato");
      db.iscritti = db.iscritti.filter(function (i) { return i.id !== id; });
      db.premi = db.premi.filter(function (p) { return p.iscritto !== id; });
      clubScrivi(db);
      return true;
    });
  }

  /* solo per la demo */
  function demoAgenti() {
    return leggi().agenti.map(function (a) { return { nome: a.nome, chiave: a.chiave, codice: a.codice, attivo: a.attivo }; });
  }
  function demoAzzera() { scrivi(datiIniziali()); clubScrivi(clubDatiIniziali()); }

  const demo = {
    agentePubblico, gioca, buono,
    agente,
    chiavePush: function () { return Promise.reject(errore("demo", "Nella demo le notifiche non partono")); },
    salvaPush: function () { return Promise.resolve(true); },
    notifica: function () { return Promise.resolve({ inviate: 0 }); },
    entra, leggiBuono, riscatta, annulla, panoramica, dettaglioAgente, salvaAgente, nuovaChiave, eliminaAgente,
    pagamento, premi, salvaPremi, impostazioni, salvaImpostazioni,
    candidatura, candidature, approvaCandidatura, scartaCandidatura,
    clubPanoramica, clubElenco, clubDettaglio, clubLeggiPremio, clubUsa, clubAnnulla,
    clubImpostazioni, clubSalvaImpostazioni, clubElimina,
    demoAgenti, demoAzzera,
  };

  /* ================= SUPABASE ================= */

  async function rpc(funzione, corpo) {
    let r;
    try {
      r = await fetch(SUPABASE_URL + "/rest/v1/rpc/" + funzione, {
        method: "POST",
        headers: { apikey: SUPABASE_KEY, "Content-Type": "application/json" },
        body: JSON.stringify(corpo || {}),
      });
    } catch (e) { throw errore("rete", "Connessione assente"); }
    const testo = await r.text();
    let dati = null;
    try { dati = testo ? JSON.parse(testo) : null; } catch (e) {}
    // gli errori delle funzioni pr_* portano il loro codice nel campo "hint"
    if (!r.ok) throw errore((dati && dati.hint) || "server", (dati && dati.message) || "Errore del server (" + r.status + ")");
    return dati;
  }
  async function funzione(corpo) {
    let r;
    try {
      r = await fetch(SUPABASE_URL + "/functions/v1/pr-notifica", {
        method: "POST",
        headers: { apikey: SUPABASE_KEY, "Content-Type": "application/json" },
        body: JSON.stringify(corpo),
      });
    } catch (e) { throw errore("rete", "Connessione assente"); }
    const dati = await r.json().catch(function () { return {}; });
    if (!r.ok) throw errore("server", dati.errore || "Notifiche non disponibili");
    return dati;
  }

  const reale = {
    agentePubblico: function (codice) { return rpc("pr_agente_pubblico", { p_codice: codice }); },
    gioca: function (codice, dispositivo) { return rpc("pr_gioca", { p_codice: codice, p_dispositivo: dispositivo }); },
    buono: function (codice) { return rpc("pr_buono", { p_codice: codice }); },

    agente: function (chiave) { return rpc("pr_agente", { p_chiave: chiave }); },
    chiavePush: async function () { return (await funzione({ azione: "chiave" })).chiave; },
    salvaPush: function (chiave, sub) { return rpc("pr_salva_push", { p_chiave: chiave, p_sub: sub }); },
    notifica: function (codice) { return funzione({ codice: codice }); },

    entra: function (pin) { return rpc("pr_entra", { p_pin: pin }); },
    leggiBuono: function (pin, codice) { return rpc("pr_leggi_buono", { p_pin: pin, p_codice: codice }); },
    riscatta: async function (pin, codice, persone) {
      const r = await rpc("pr_riscatta", { p_pin: pin, p_codice: codice, p_persone: persone });
      r.righe = C.provvigione(r.fasce, r.gia, persone).righe;
      return r;
    },
    annulla: function (pin, codice) { return rpc("pr_annulla", { p_pin: pin, p_codice: codice }); },
    panoramica: function (pin) { return rpc("pr_panoramica", { p_pin: pin }); },
    dettaglioAgente: function (pin, id) { return rpc("pr_dettaglio_agente", { p_pin: pin, p_id: id }); },
    salvaAgente: function (pin, dati) { return rpc("pr_salva_agente", { p_pin: pin, p_dati: dati }); },
    nuovaChiave: function (pin, id) { return rpc("pr_nuova_chiave", { p_pin: pin, p_id: id }); },
    eliminaAgente: function (pin, id) { return rpc("pr_elimina_agente", { p_pin: pin, p_id: id }); },
    pagamento: function (pin, agenteId, importo, nota) {
      return rpc("pr_pagamento", { p_pin: pin, p_agente: agenteId, p_importo: String(importo), p_nota: nota || "" });
    },
    premi: function (pin) { return rpc("pr_premi", { p_pin: pin }); },
    salvaPremi: function (pin, lista) { return rpc("pr_salva_premi", { p_pin: pin, p_lista: lista }); },
    impostazioni: function (pin) { return rpc("pr_impostazioni", { p_pin: pin }); },
    salvaImpostazioni: function (pin, dati) { return rpc("pr_salva_impostazioni", { p_pin: pin, p_dati: dati }); },

    candidatura: function (nome, telefono, ruolo, note) {
      return rpc("pr_candidatura", { p_nome: nome, p_telefono: telefono, p_ruolo: ruolo || "", p_note: note || "" });
    },
    candidature: function (pin) { return rpc("pr_candidature", { p_pin: pin }); },
    approvaCandidatura: function (pin, id, bonus) {
      return rpc("pr_approva_candidatura", { p_pin: pin, p_id: id, p_bonus: bonus !== false });
    },
    scartaCandidatura: function (pin, id) { return rpc("pr_scarta_candidatura", { p_pin: pin, p_id: id }); },

    // Club del Vico (funzioni SQL: supabase/07-club.sql)
    clubPanoramica: function (pin) { return rpc("club_panoramica", { p_pin: pin }); },
    clubElenco: function (pin, cerca) { return rpc("club_elenco", { p_pin: pin, p_cerca: cerca || "" }); },
    clubDettaglio: function (pin, id) { return rpc("club_dettaglio", { p_pin: pin, p_id: id }); },
    clubLeggiPremio: function (pin, codice) { return rpc("club_leggi_premio", { p_pin: pin, p_codice: codice }); },
    clubUsa: function (pin, codice, forza) { return rpc("club_usa", { p_pin: pin, p_codice: codice, p_forza: !!forza }); },
    clubAnnulla: function (pin, codice) { return rpc("club_annulla", { p_pin: pin, p_codice: codice }); },
    clubImpostazioni: function (pin) { return rpc("club_impostazioni", { p_pin: pin }); },
    clubSalvaImpostazioni: function (pin, dati) { return rpc("club_salva_impostazioni", { p_pin: pin, p_dati: dati }); },
    clubElimina: function (pin, id) { return rpc("club_elimina_iscritto", { p_pin: pin, p_id: id }); },
  };

  return Object.assign({ DEMO: DEMO }, DEMO ? demo : reale);
})();
