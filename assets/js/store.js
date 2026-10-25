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
      persone: 2, sere: 14, giorniNo: [6], giorniChiusura: [],
      compleannoPer: 2, compleannoGiorni: 3, offerteAttive: true, offerteSettimane: 3, offertePersone: 2,
      offerteSere: 2, offertePausa: 15, emailAttive: false };
  }
  function clubOfferteBase() {
    return [{ id: "DOLCE", emoji: "🍰", nome: { it: "Dolce offerto", en: "Free dessert" }, attivo: true }];
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
    a.notifiche = 1;
    clubPremioNuovo(db, a.id, "benvenuto", C.piuGiorni(oggi, -4));
    const b = persona("Marco Bianchi", "marco.b@example.com", "+393474455667", "1988-03-12", 0, false);
    clubPremioNuovo(db, b.id, "benvenuto", C.piuGiorni(oggi, 1));
    const c = persona("Sara Verdi", "sara.verdi@example.com", "+393201234567", "2000-11-02", 40, true);
    c.notifiche = 1;
    const pc = clubPremioNuovo(db, c.id, "benvenuto", C.piuGiorni(oggi, -39));
    pc.usato = Date.now() - 25 * 864e5; pc.seraUso = C.sera(pc.usato);
    return db;
  }
  function clubLeggi() {
    let db = null;
    try { db = JSON.parse(localStorage.getItem(CLUB)); } catch (e) {}
    if (!db) { db = clubDatiIniziali(); clubScrivi(db); }
    db.impostazioni = Object.assign(clubImpostazioniBase(), db.impostazioni);
    db.offerte = db.offerte || clubOfferteBase();
    db.messaggi = db.messaggi || [];
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
        conNotifiche: db.iscritti.filter(function (i) { return i.notifiche > 0; }).length,
        inCoda: 0, ultimoGiro: db.ultimoGiro || null, ultimoEsito: db.ultimoEsito || null,
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
      return Object.assign({}, i, { emailConfermata: false, notifiche: i.notifiche || 0, ultimoContatto: i.ultimoContatto || null,
        premi: db.premi.filter(function (p) { return p.iscritto === id; })
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
  // la campagna "regalo a sorpresa" della demo: numeri finti, per vedere il riquadro
  function campPanoramica(pin) {
    return rete(function () {
      controllaPin(leggi(), pin);
      return [{ id: "regalo-thefork", nome: "Regalo a sorpresa · clienti TheFork", attiva: true, sere: 14, scopriEntro: C.piuGiorni(C.sera(), 30),
        contatti: 384, aperti: 96, scoperti: 41, prenotati: 23, usati: 9, disiscritti: 6,
        premi: [
          { id: "CINQUANTA", emoji: "🎉", nome: "50% di sconto sul conto", peso: 8, limite: 15, usciti: 3 },
          { id: "TRENTA", emoji: "🔥", nome: "30% di sconto sul conto", peso: 15, limite: 30, usciti: 7 },
          { id: "VENTI", emoji: "⭐", nome: "20% di sconto sul conto", peso: 25, limite: null, usciti: 10 },
          { id: "DIECI", emoji: "🍕", nome: "10% di sconto sul conto", peso: 12, limite: null, usciti: 5 },
          { id: "PROSECCO", emoji: "🥂", nome: "Prosecco di benvenuto per il tavolo", peso: 15, limite: null, usciti: 7 },
          { id: "DOLCE", emoji: "🍰", nome: "Dolce della casa offerto", peso: 15, limite: null, usciti: 6 },
          { id: "SPRITZ", emoji: "🍹", nome: "Spritz offerto", peso: 10, limite: null, usciti: 3 },
        ] }];
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
      // compleanno e offerte: numero intero fra min e max
      const intero = function (k, min, max, msg) {
        if (dati[k] == null) return;
        const n = String(dati[k]).trim();
        if (!/^\d{1,2}$/.test(n) || +n < min || +n > max) throw errore(k, msg);
        imp[k] = +n;
      };
      intero("compleannoPer", 1, 5, "Moltiplicatore non valido (da 1 a 5)");
      intero("compleannoGiorni", 0, 7, "Giorni non validi (da 0 a 7)");
      intero("offerteSettimane", 1, 12, "Settimane non valide (da 1 a 12)");
      intero("offertePersone", 1, 20, "Persone non valide (da 1 a 20)");
      intero("offerteSere", 1, 14, "Sere non valide (da 1 a 14)");
      intero("offertePausa", 7, 90, "Giorni fra due offerte non validi (da 7 a 90)");
      if (dati.offerteAttive != null) imp.offerteAttive = !!dati.offerteAttive;
      if (dati.emailAttive != null) imp.emailAttive = !!dati.emailAttive;
      clubScrivi(db);
      return imp;
    });
  }
  function clubOfferte(pin) {
    return rete(function () { controllaPin(leggi(), pin); return clubLeggi().offerte; });
  }
  function clubSalvaOfferte(pin, lista) {
    return rete(function () {
      controllaPin(leggi(), pin);
      if (lista.some(function (o) { return o.attivo && !String(o.nome.it || "").trim(); })) {
        throw errore("offerte", "Ogni offerta attiva ha bisogno di un nome");
      }
      const db = clubLeggi();
      db.offerte = lista.map(function (o) {
        return { id: o.id || C.casuale(6), emoji: String(o.emoji || "").trim() || "🎁", attivo: o.attivo !== false,
          nome: { it: String(o.nome.it || "").trim(), en: String(o.nome.en || "").trim() } };
      });
      clubScrivi(db);
      return db.offerte;
    });
  }
  function clubMessaggi(pin) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = clubLeggi();
      const nome = {};
      db.iscritti.forEach(function (i) { nome[i.id] = i.nome; });
      return db.messaggi.slice().sort(function (x, y) { return y.creato - x.creato; }).slice(0, 40)
        .map(function (m) { return Object.assign({ nome: nome[m.iscritto] || "?" }, m); });
    });
  }
  // nella prova l'avviso "parte" subito: le notifiche vere le manda solo il server
  function clubMessaggio(db, i, tipo, titolo, testo, premio) {
    db.messaggi.push({ id: C.casuale(10), iscritto: i.id, tipo: tipo, titolo: titolo, testo: testo, premio: premio,
      creato: Date.now(), inviato: Date.now(), esito: { push: i.notifiche || 0, email: db.impostazioni.emailAttive ? "ok" : "spente" } });
  }
  function clubPremioDemo(db, i, tipo, emoji, nome, persone, dal, al, giorniNo) {
    let codice;
    do { codice = C.casuale(7); } while (db.premi.some(function (p) { return p.codice === codice; }));
    const p = { codice: codice, iscritto: i.id, tipo: tipo, emoji: emoji, nome: Object.assign({}, nome), persone: persone,
      dal: dal, al: al, giorniNo: giorniNo, creato: Date.now(), usato: null, seraUso: null };
    db.premi.push(p);
    return p;
  }
  // lo stesso giro del database (club_giro in 08-club-avvisi.sql), nella memoria del browser
  function clubGiroOra(pin) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = clubLeggi(), imp = db.impostazioni, s = C.sera();
      let nc = 0, nof = 0;
      db.iscritti.forEach(function (i) {
        const g = imp.compleannoGiorni;
        const b = prossimoCompleanno(i.nascita, C.piuGiorni(s, -g));
        if (s < C.piuGiorni(b, -g) || s > C.piuGiorni(b, g)) return;
        if (db.premi.some(function (p) { return p.iscritto === i.id && p.tipo === "compleanno" && p.creato > Date.now() - 300 * 864e5; })) return;
        const p = clubPremioDemo(db, i, "compleanno", "🎂", imp.nome, imp.persone * imp.compleannoPer, s, C.piuGiorni(b, g), imp.giorniChiusura);
        nc++;
        if (i.promo) {
          clubMessaggio(db, i, "compleanno", "🎂 Buon compleanno, " + i.nome.split(" ")[0] + "!",
            "Per festeggiare ti offriamo " + imp.nome.it + " per " + p.persone + " persone.", p.codice);
          i.ultimoContatto = Date.now();
        }
      });
      const attive = db.offerte.filter(function (o) { return o.attivo; });
      if (imp.offerteAttive && attive.length) {
        const g = imp.giorniNo.concat(imp.giorniChiusura);
        db.iscritti.forEach(function (i) {
          const usati = db.premi.filter(function (p) { return p.iscritto === i.id && p.usato; }).map(function (p) { return p.usato; });
          const ultimaVolta = Math.max.apply(null, [i.creato].concat(usati));
          if (!i.promo || !(i.notifiche > 0)) return;
          if ((i.ultimoContatto || 0) > Date.now() - imp.offertePausa * 864e5) return;
          if (ultimaVolta > Date.now() - imp.offerteSettimane * 7 * 864e5) return;
          if (db.premi.some(function (p) { return p.iscritto === i.id && clubAperto(p); })) return;
          const giaAvute = db.premi.filter(function (p) { return p.iscritto === i.id && p.tipo === "promo"; }).length;
          const o = attive[giaAvute % attive.length];
          const d1 = clubPiuSere(s, 1, g);
          const p = clubPremioDemo(db, i, "promo", o.emoji, o.nome, imp.offertePersone, d1, clubPiuSere(d1, imp.offerteSere, g), g);
          clubMessaggio(db, i, "promo", "💌 Ci manchi, " + i.nome.split(" ")[0] + "!",
            "Per te " + o.emoji + " " + o.nome.it + " per " + imp.offertePersone + " persone.", p.codice);
          i.ultimoContatto = Date.now();
          nof++;
        });
      }
      db.ultimoGiro = Date.now();
      db.ultimoEsito = { compleanni: nc, offerte: nof };
      clubScrivi(db);
      return db.ultimoEsito;
    });
  }
  function clubProvaAvviso(pin, id) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = clubLeggi();
      const i = db.iscritti.find(function (x) { return x.id === id; });
      if (!i) throw errore("iscritto", "Iscritto non trovato");
      clubMessaggio(db, i, "prova", "🔔 Prova del Club del Vico", "Se leggi questo messaggio, gli avvisi del Club arrivano su questo telefono.", null);
      clubScrivi(db);
      return { notifiche: i.notifiche || 0 };
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

  /* ---------- prenotazioni (demo) ---------- */
  const PREN = "vdcpren_demo_v4";
  // per le prenotazioni conta il giorno di calendario a Firenze, non la "sera" degli agenti
  function prenOggi() { return C.sera(Date.now() + 6 * 3600e3); }
  function prenImpostazioniBase() {
    return { attive: true, fasce: [{ dalle: "19:00", alle: "20:30" }, { dalle: "21:00", alle: "22:30" }], passo: 30,
      coperti: 40, maxPersone: 8, giorniAvanti: 30, anticipoMin: 120, dateChiuse: [] };
  }
  function prenDatiIniziali() {
    // qualche prenotazione finta, così la scheda non è vuota
    const oggi = prenOggi(), db = { impostazioni: prenImpostazioniBase(), prenotazioni: [] };
    const p = function (giorni, turno, persone, nome, telefono, fonte, nota, stato, oreFa, extra) {
      db.prenotazioni.push(Object.assign({ id: "p" + C.casuale(8), codice: C.casuale(6), sera: C.piuGiorni(oggi, giorni), turno: turno,
        persone: persone, nome: nome, telefono: telefono, nota: nota, fonte: fonte, stato: stato, socio: fonte === "sito",
        creato: Date.now() - oreFa * 3600e3, annullata: stato === "annullata" ? Date.now() - 3600e3 : null,
        annullataDa: stato === "annullata" ? "cliente" : null, benvenuto: 0, whatsapp: null }, extra || {}));
    };
    p(0, "19:30", 4, "Giulia Rossi", "+393331112233", "sito", "Un seggiolone, grazie", "confermata", 26);
    p(0, "19:00", 2, "Luca Neri", "+393409876543", "telefono", "", "confermata", 30);
    p(0, "20:30", 6, "Famiglia Conti", "+393385551212", "thefork", "Compleanno della nonna", "confermata", 50);
    p(0, "21:30", 3, "Marco Bianchi", "+393474455667", "sito", "", "confermata", 3, { socio: false, benvenuto: 3, whatsapp: "letto", waAttivato: Date.now() - 2 * 3600e3 });
    p(0, "22:00", 2, "Anna Galli", "+393299988776", "google", "", "annullata", 8);
    p(1, "20:00", 5, "Sara Verdi", "+393201234567", "sito", "Allergia alle noci", "confermata", 12);
    p(1, "21:00", 8, "Gruppo Ferretti", "+393331234000", "telefono", "Tavolo lungo", "confermata", 40);
    p(3, "21:30", 2, "Paolo Riva", "+393381112222", "sito", "", "confermata", 2,
      { socio: false, benvenuto: 2, whatsapp: "errore", waErrore: "Il numero non ha WhatsApp" });
    return db;
  }
  function prenLeggi() {
    let db = null;
    try { db = JSON.parse(localStorage.getItem(PREN)); } catch (e) {}
    if (!db) { db = prenDatiIniziali(); prenScrivi(db); }
    db.impostazioni = Object.assign(prenImpostazioniBase(), db.impostazioni);
    return db;
  }
  function prenScrivi(db) { try { localStorage.setItem(PREN, JSON.stringify(db)); } catch (e) {} }
  function prenChiusa(db, s) {
    return clubLeggi().impostazioni.giorniChiusura.indexOf(C.giornoSettimana(s)) >= 0 || db.impostazioni.dateChiuse.indexOf(s) >= 0;
  }
  function prenConta(l) { return l.filter(function (x) { return x.stato === "confermata" || x.stato === "arrivati"; }); }
  // il turno (fascia di orari di arrivo) di un'ora; -1 = fuori dai turni
  function prenFascia(db, t) {
    return db.impostazioni.fasce.findIndex(function (f) { return t >= f.dalle && t <= f.alle; });
  }
  function prenOccupati(db, s, k) {
    return prenConta(db.prenotazioni.filter(function (x) { return x.sera === s && prenFascia(db, x.turno) === k; }))
      .reduce(function (n, x) { return n + x.persone; }, 0);
  }
  // gli orari che il cliente può scegliere (come pren_orari nel database)
  function prenOrari(imp) {
    const min = function (t) { const p = t.split(":"); return +p[0] * 60 + +p[1]; };
    const hhmm = function (m) { return String(Math.floor(m / 60)).padStart(2, "0") + ":" + String(m % 60).padStart(2, "0"); };
    const l = [];
    imp.fasce.forEach(function (f) { for (let m = min(f.dalle); m <= min(f.alle); m += imp.passo) l.push(hhmm(m)); });
    return l;
  }
  function prenVista(x) { return Object.assign({}, x); }
  const ORARIO = /^([01]\d|2[0-3]):[0-5]\d$/;

  function prenGiorno(pin, sera) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = prenLeggi(), oggi = prenOggi(), s = /^\d{4}-\d\d-\d\d$/.test(sera || "") ? sera : oggi;
      const dellaSera = db.prenotazioni.filter(function (x) { return x.sera === s; });
      const ordina = function (a, b) {
        return (a.stato === "annullata") - (b.stato === "annullata") || (a.turno < b.turno ? -1 : a.turno > b.turno ? 1 : a.creato - b.creato);
      };
      const prossimi = [];
      for (let k = 0; k < 14; k++) {
        const d = C.piuGiorni(oggi, k), l = prenConta(db.prenotazioni.filter(function (x) { return x.sera === d; }));
        prossimi.push({ sera: d, chiuso: prenChiusa(db, d), prenotazioni: l.length,
          persone: l.reduce(function (n, x) { return n + x.persone; }, 0) });
      }
      return {
        sera: s, oggi: oggi, coperti: db.impostazioni.coperti, chiuso: prenChiusa(db, s), prossimi: prossimi,
        turni: db.impostazioni.fasce.map(function (f, k) {
          return { ora: f.dalle + " – " + f.alle, dalle: f.dalle, alle: f.alle, numero: k + 1, previsto: true,
            prenotati: prenOccupati(db, s, k),
            lista: dellaSera.filter(function (x) { return prenFascia(db, x.turno) === k; }).sort(ordina).map(prenVista) };
        }).concat(dellaSera.some(function (x) { return prenFascia(db, x.turno) < 0; }) ? [{
          ora: "Altri orari", previsto: false, prenotati: prenOccupati(db, s, -1),
          lista: dellaSera.filter(function (x) { return prenFascia(db, x.turno) < 0; }).sort(ordina).map(prenVista) }] : []),
      };
    });
  }
  function prenAggiungi(pin, dati) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = prenLeggi(), n = parseInt(dati.persone, 10), nome = String(dati.nome || "").trim();
      if (!/^\d{4}-\d\d-\d\d$/.test(dati.sera || "") || dati.sera < C.piuGiorni(prenOggi(), -1)) throw errore("sera", "Sera non valida");
      if (!ORARIO.test(dati.turno || "")) throw errore("turno", "Orario non valido");
      if (!(n >= 1 && n <= 200)) throw errore("persone", "Numero di persone non valido");
      if (nome.length < 2) throw errore("nome", "Scrivi il nome");
      const x = { id: "p" + C.casuale(8), codice: C.casuale(6), sera: dati.sera, turno: dati.turno, persone: n, nome: nome.slice(0, 60),
        telefono: String(dati.telefono || "").trim(), nota: String(dati.nota || "").trim().slice(0, 300),
        fonte: dati.fonte || "telefono", stato: "confermata", socio: false, creato: Date.now(), annullata: null, annullataDa: null };
      db.prenotazioni.push(x);
      prenScrivi(db);
      return prenVista(x);
    });
  }
  function prenModifica(pin, id, dati) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = prenLeggi(), x = db.prenotazioni.find(function (p) { return p.id === id; });
      if (!x) throw errore("nonc", "Prenotazione non trovata");
      if (dati.stato) {
        if (dati.stato === "annullata" && x.stato !== "annullata") { x.annullata = Date.now(); x.annullataDa = "titolare"; }
        if (dati.stato !== "annullata") { x.annullata = null; x.annullataDa = null; }
        x.stato = dati.stato;
      }
      if (dati.persone != null) {
        const n = parseInt(dati.persone, 10);
        if (!(n >= 1 && n <= 200)) throw errore("persone", "Numero di persone non valido");
        x.persone = n;
      }
      if (dati.turno != null) {
        if (!ORARIO.test(dati.turno)) throw errore("turno", "Orario non valido");
        x.turno = dati.turno;
      }
      if (dati.sera != null) x.sera = dati.sera;
      if (dati.nota != null) x.nota = String(dati.nota).trim().slice(0, 300);
      prenScrivi(db);
      return prenVista(x);
    });
  }
  function prenImpostazioniVista(db) {
    const oggi = prenOggi();
    return Object.assign({}, db.impostazioni, { orari: prenOrari(db.impostazioni),
      dateChiuse: db.impostazioni.dateChiuse.filter(function (d) { return d >= oggi; }).sort(),
      giorniChiusura: clubLeggi().impostazioni.giorniChiusura, telefoni: 0 });
  }
  function prenImpostazioni(pin) {
    return rete(function () { controllaPin(leggi(), pin); return prenImpostazioniVista(prenLeggi()); });
  }
  function prenSalvaImpostazioni(pin, dati) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const db = prenLeggi(), imp = db.impostazioni;
      const intero = function (k, min, max) {
        if (dati[k] == null) return;
        const n = Number(dati[k]);
        if (!Number.isInteger(n) || n < min || n > max) throw errore("numeri", "Numeri non validi");
        imp[k] = n;
      };
      if (dati.fasce) {
        const f = dati.fasce.slice().sort(function (a, b) { return a.dalle < b.dalle ? -1 : 1; });
        const male = !f.length || f.length > 4 || f.some(function (x, i) {
          return !ORARIO.test(x.dalle || "") || !ORARIO.test(x.alle || "") || x.dalle > x.alle || (i && f[i - 1].alle >= x.dalle);
        });
        if (male) throw errore("turni", "Turni non validi: da 1 a 4, con l'ora di inizio prima della fine e senza sovrapporsi");
        imp.fasce = f.map(function (x) { return { dalle: x.dalle, alle: x.alle }; });
      }
      if (dati.passo != null) {
        if ([15, 30, 60].indexOf(Number(dati.passo)) < 0) throw errore("numeri", "Numeri non validi");
        imp.passo = Number(dati.passo);
      }
      if (dati.attive != null) imp.attive = !!dati.attive;
      intero("coperti", 1, 500);
      intero("maxPersone", 1, 60);
      intero("giorniAvanti", 1, 180);
      intero("anticipoMin", 0, 2880);
      if (dati.dateChiuse) imp.dateChiuse = dati.dateChiuse.filter(function (d, i, a) { return a.indexOf(d) === i; }).sort();
      prenScrivi(db);
      return prenImpostazioniVista(db);
    });
  }

  /* ---------- asporto (demo): le regole e uno storico finto (gli ordini veri stanno nel Banco del menu) ---------- */
  const ASP = "vdcasp_demo_v1";
  function aspBase() {
    return { attive: true, dalle: "19:00", alle: "22:30", passo: 15, piatti: 15, anticipoMin: 30, giorniNo: [6],
      nonContano: ["dolci", "birre", "cocktail", "bevande", "vini"] };
  }
  function aspLeggi() {
    let a = null;
    try { a = JSON.parse(localStorage.getItem(ASP)); } catch (e) {}
    return Object.assign(aspBase(), a || {});
  }
  // ordini finti di una sera: sempre gli stessi per la stessa data, niente il sabato
  function aspDemoSera(s) {
    if (C.giornoSettimana(s) === 6 || s > prenOggi()) return [];
    let seme = Number(s.replace(/-/g, "")) % 89;
    const caso = function (n) { seme = (seme * 37 + 11) % 97; return Math.floor(seme / 97 * n); };
    const nomi = ["Giulia Rossi", "Marco Bianchi", "Sara Conti", "Luca Ferri", "Anna Galli", "Paolo Neri"];
    const piatti = [["Margherita", 8, "pizze"], ["Pizza Vico", 12, "pizze"], ["Diavola", 9, "pizze"],
      ["Spaghetti allo scoglio", 18, "primi"], ["Coca-Cola", 3, "bevande"], ["Tiramisù", 6, "dolci"]];
    const orari = ["19:30", "20:00", "20:15", "20:45", "21:00", "21:30", "22:00"];
    const quanti = 1 + caso(4), oggi = s === prenOggi(), lista = [];
    for (let i = 0; i < quanti; i++) {
      const righe = [];
      for (let k = 0, n = 1 + caso(3); k < n; k++) {
        const p = piatti[caso(piatti.length)];
        righe.push({ nome: p[0], prezzo: p[1], qta: 1 + caso(2), nota: "", slug: p[2] });
      }
      const stato = oggi ? ["ricevuto", "preparazione", "pronto", "ritirato"][i % 4] : (caso(8) === 0 ? "annullato" : "ritirato");
      lista.push({
        id: s + "-" + i, codice: "ABCDEFGHJKLMNPQRSTUVWXYZ"[caso(24)] + "K" + (2 + caso(8)) + "Q", sera: s, ritiro: orari[caso(orari.length)],
        righe: righe, totale: righe.reduce(function (t, r) { return t + r.prezzo * r.qta; }, 0),
        nota: caso(3) === 0 ? "Senza cipolla" : "", nome: nomi[caso(nomi.length)], telefono: "+39347" + (1000000 + caso(8999999)),
        stato: stato, socio: true, pezzi: righe.reduce(function (t, r) { return t + (r.slug === "pizze" || r.slug === "primi" ? r.qta : 0); }, 0),
      });
    }
    return lista.sort(function (a, b) { return a.ritiro < b.ritiro ? -1 : 1; });
  }
  function aspDemoConti(lista) {
    const vivi = lista.filter(function (o) { return o.stato !== "annullato"; });
    return { ordini: vivi.length, annullati: lista.length - vivi.length,
      piatti: vivi.reduce(function (t, o) { return t + o.pezzi; }, 0),
      incasso: vivi.reduce(function (t, o) { return t + o.totale; }, 0) };
  }
  function aspStorico(pin, sera) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const oggi = prenOggi(), s = sera && sera < oggi ? sera : oggi, sere = [];
      for (let k = 0; k < 30; k++) {
        const g = C.piuGiorni(oggi, -k), c = aspDemoConti(aspDemoSera(g));
        if (c.ordini || c.annullati) sere.push(Object.assign({ sera: g }, c));
      }
      const mese = sere.filter(function (x) { return x.sera.slice(0, 7) === oggi.slice(0, 7); });
      return { oggi: oggi, sera: s, ordini: aspDemoSera(s), sere: sere,
        mese: { ordini: mese.reduce(function (t, x) { return t + x.ordini; }, 0),
                incasso: mese.reduce(function (t, x) { return t + x.incasso; }, 0) } };
    });
  }
  function aspVista(a) {
    const g = C.giornoSettimana(prenOggi());
    const stasera = aspDemoSera(prenOggi()), c = aspDemoConti(stasera);
    return Object.assign({}, a, { stasera: { ordini: c.ordini, piatti: c.piatti, incasso: c.incasso,
        aperti: stasera.filter(function (o) { return ["ricevuto", "preparazione", "pronto"].indexOf(o.stato) >= 0; }).length },
      apertoStasera: a.attive && a.giorniNo.indexOf(g) < 0 && clubLeggi().impostazioni.giorniChiusura.indexOf(g) < 0 });
  }
  function aspImpostazioni(pin) {
    return rete(function () { controllaPin(leggi(), pin); return aspVista(aspLeggi()); });
  }
  function aspSalvaImpostazioni(pin, dati) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const a = aspLeggi();
      if (dati.attive != null) a.attive = !!dati.attive;
      if (dati.dalle != null || dati.alle != null) {
        const d = dati.dalle != null ? dati.dalle : a.dalle, al = dati.alle != null ? dati.alle : a.alle;
        if (!ORARIO.test(d) || !ORARIO.test(al) || d > al) throw errore("orari", "Orari non validi: il primo ritiro deve venire prima dell'ultimo");
        a.dalle = d; a.alle = al;
      }
      [["piatti", 1, 200], ["anticipoMin", 0, 240]].forEach(function (x) {
        if (dati[x[0]] == null) return;
        const n = Number(dati[x[0]]);
        if (!Number.isInteger(n) || n < x[1] || n > x[2]) throw errore("numeri", "Numeri non validi");
        a[x[0]] = n;
      });
      if (dati.passo != null) {
        if ([10, 15, 20, 30].indexOf(Number(dati.passo)) < 0) throw errore("numeri", "Numeri non validi");
        a.passo = Number(dati.passo);
      }
      if (dati.giorniNo) a.giorniNo = dati.giorniNo.map(Number).filter(function (g, i, l) { return g >= 0 && g <= 6 && l.indexOf(g) === i; }).sort();
      try { localStorage.setItem(ASP, JSON.stringify(a)); } catch (e) {}
      return aspVista(a);
    });
  }

  /* ---------- WhatsApp di conferma (demo) ---------- */
  const WAD = "vdcwa_demo_v1";
  function waLeggi() {
    let w = null;
    try { w = JSON.parse(localStorage.getItem(WAD)); } catch (e) {}
    return Object.assign({ attivo: false, numeroId: "", modelloNuovo: "prenotazione_benvenuto", modello: "prenotazione_confermata",
      modelloVoto: "voto_serata", benvenutoMax: 4, linkRecensioni: "", clubDopoOre: 3, votoOra: "12:30", inglese: false }, w || {});
  }
  function waVista(w) {
    return Object.assign({}, w, { configurato: !!w.numeroId, ultimoInvio: null, ultimoErrore: null, nonLetti: 2,
      settimana: { inviati: w.attivo ? 12 : 0, verificati: w.attivo ? 11 : 0, errori: w.attivo ? 1 : 0,
                   attivati: w.attivo ? 7 : 0, voti: w.attivo ? 5 : 0, media: 4.4 } });
  }
  function waMessaggi(pin) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const ora = Date.now();
      return [
        { id: 1, telefono: "+393474455667", nome: "Marco Bianchi", testo: "Ciao!", tipo: "attiva", quando: ora - 3600e3, letto: false, aperta: true },
        { id: 2, telefono: "+393381112222", nome: "Paolo Riva", testo: "Il servizio è stato lento, abbiamo aspettato 40 minuti la pizza.", tipo: "testo",
          quando: ora - 5 * 3600e3, letto: false, voto: 2, aperta: true },
        { id: 3, telefono: "+393331112233", nome: "Giulia Rossi", testo: "5", tipo: "voto", quando: ora - 26 * 3600e3, letto: true, voto: 5, aperta: false },
      ];
    });
  }
  function waRispondi(pin, telefono, testo) {
    return rete(function () {
      controllaPin(leggi(), pin);
      if (!String(testo || "").trim()) throw errore("vuoto", "Scrivi il messaggio");
      return { ok: true };
    });
  }
  function waImpostazioni(pin) { return rete(function () { controllaPin(leggi(), pin); return waVista(waLeggi()); }); }
  function waSalva(pin, dati) {
    return rete(function () {
      controllaPin(leggi(), pin);
      const w = waLeggi();
      if (dati.numeroId != null) {
        if (!/^\d{0,30}$/.test(dati.numeroId)) throw errore("numero", "Il Phone number ID è fatto solo di cifre");
        w.numeroId = dati.numeroId;
      }
      if (dati.attivo && !w.numeroId) throw errore("numero", "Prima collega il numero WhatsApp");
      if (dati.attivo != null) w.attivo = !!dati.attivo;
      if (dati.modelloNuovo) w.modelloNuovo = dati.modelloNuovo;
      if (dati.modello) w.modello = dati.modello;
      if (dati.modelloVoto) w.modelloVoto = dati.modelloVoto;
      if (dati.linkRecensioni != null) {
        if (dati.linkRecensioni && !/^https:\/\/\S{5,250}$/.test(dati.linkRecensioni)) throw errore("link", "Il link deve cominciare con https://");
        w.linkRecensioni = dati.linkRecensioni;
      }
      if (dati.clubDopoOre != null) w.clubDopoOre = Number(dati.clubDopoOre);
      if (dati.votoOra) w.votoOra = dati.votoOra;
      if (dati.inglese != null) w.inglese = !!dati.inglese;
      if (dati.benvenutoMax != null) {
        const n = Number(dati.benvenutoMax);
        if (!Number.isInteger(n) || n < 0 || n > 20) throw errore("numeri", "Numeri non validi");
        w.benvenutoMax = n;
      }
      try { localStorage.setItem(WAD, JSON.stringify(w)); } catch (e) {}
      return waVista(w);
    });
  }

  /* solo per la demo */
  function demoAgenti() {
    return leggi().agenti.map(function (a) { return { nome: a.nome, chiave: a.chiave, codice: a.codice, attivo: a.attivo }; });
  }
  function demoAzzera() { scrivi(datiIniziali()); clubScrivi(clubDatiIniziali()); prenScrivi(prenDatiIniziali()); }

  const demo = {
    agentePubblico, gioca, buono,
    agente,
    chiavePush: function () { return Promise.reject(errore("demo", "Nella demo le notifiche non partono")); },
    salvaPush: function () { return Promise.resolve(true); },
    notifica: function () { return Promise.resolve({ inviate: 0 }); },
    entra, leggiBuono, riscatta, annulla, panoramica, dettaglioAgente, salvaAgente, nuovaChiave, eliminaAgente,
    pagamento, premi, salvaPremi, impostazioni, salvaImpostazioni,
    candidatura, candidature, approvaCandidatura, scartaCandidatura,
    clubPanoramica, clubElenco, clubDettaglio, clubLeggiPremio, clubUsa, clubAnnulla, campPanoramica,
    clubImpostazioni, clubSalvaImpostazioni, clubElimina,
    clubOfferte, clubSalvaOfferte, clubMessaggi, clubGiroOra, clubProvaAvviso,
    clubStatoInvii: function () { return Promise.resolve({ email: false }); },
    clubInvia: function () { return Promise.resolve({ inviati: 0 }); },
    prenGiorno, prenAggiungi, prenModifica, prenImpostazioni, prenSalvaImpostazioni,
    prenSalvaPush: function () { return Promise.reject(errore("demo", "Nella demo le notifiche non partono")); },
    prenProvaAvviso: function () { return Promise.reject(errore("demo", "Nella demo le notifiche non partono")); },
    aspImpostazioni, aspSalvaImpostazioni, aspStorico, waImpostazioni, waSalva, waMessaggi, waRispondi,
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

  // la funzione che manda gli avvisi del Club (notifiche ed email)
  async function funzioneClub(corpo) {
    let r;
    try {
      r = await fetch(SUPABASE_URL + "/functions/v1/club-invia", {
        method: "POST",
        headers: { apikey: SUPABASE_KEY, "Content-Type": "application/json" },
        body: JSON.stringify(corpo),
      });
    } catch (e) { throw errore("rete", "Connessione assente"); }
    const dati = await r.json().catch(function () { return {}; });
    if (!r.ok) throw errore("server", dati.errore || "Avvisi non disponibili");
    return dati;
  }

  // la funzione che avvisa il titolare delle prenotazioni nuove o annullate
  async function funzionePren(corpo) {
    let r;
    try {
      r = await fetch(SUPABASE_URL + "/functions/v1/pren-avvisa", {
        method: "POST",
        headers: { apikey: SUPABASE_KEY, "Content-Type": "application/json" },
        body: JSON.stringify(corpo),
      });
    } catch (e) { throw errore("rete", "Connessione assente"); }
    const dati = await r.json().catch(function () { return {}; });
    if (!r.ok) throw errore("server", dati.errore || "Avvisi non disponibili");
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
    // campagne "regalo a sorpresa" (supabase/18-campagna-regalo.sql)
    campPanoramica: function (pin) { return rpc("camp_panoramica", { p_pin: pin }); },
    clubImpostazioni: function (pin) { return rpc("club_impostazioni", { p_pin: pin }); },
    clubSalvaImpostazioni: function (pin, dati) { return rpc("club_salva_impostazioni", { p_pin: pin, p_dati: dati }); },
    clubElimina: function (pin, id) { return rpc("club_elimina_iscritto", { p_pin: pin, p_id: id }); },
    clubOfferte: function (pin) { return rpc("club_offerte", { p_pin: pin }); },
    clubSalvaOfferte: function (pin, lista) { return rpc("club_salva_offerte", { p_pin: pin, p_lista: lista }); },
    clubMessaggi: function (pin) { return rpc("club_messaggi", { p_pin: pin }); },
    clubGiroOra: function (pin) { return rpc("club_giro_ora", { p_pin: pin }); },
    clubProvaAvviso: function (pin, id) { return rpc("club_prova_avviso", { p_pin: pin, p_id: id }); },
    clubStatoInvii: function () { return funzioneClub({ azione: "stato" }); },
    // manda subito gli avvisi in coda (se non riesce, ci pensa il giro dei 10 minuti)
    clubInvia: function () { return funzioneClub({ azione: "invia" }).catch(function () { return null; }); },

    // Prenotazioni dal sito (funzioni SQL: supabase/10-prenotazioni.sql)
    prenGiorno: function (pin, sera) { return rpc("pren_giorno", { p_pin: pin, p_sera: sera || "" }); },
    prenAggiungi: function (pin, dati) { return rpc("pren_aggiungi", { p_pin: pin, p_dati: dati }); },
    prenModifica: function (pin, id, dati) { return rpc("pren_modifica", { p_pin: pin, p_id: id, p_dati: dati }); },
    prenImpostazioni: function (pin) { return rpc("pren_impostazioni", { p_pin: pin }); },
    prenSalvaImpostazioni: function (pin, dati) { return rpc("pren_salva_impostazioni", { p_pin: pin, p_dati: dati }); },
    prenSalvaPush: function (pin, sub) { return rpc("pren_salva_push", { p_pin: pin, p_sub: sub }); },
    // mette in coda un avviso di prova e lo manda subito; false = non c'è ancora nessuna prenotazione da usare
    prenProvaAvviso: async function (pin) {
      const pronta = await rpc("pren_prova_avviso", { p_pin: pin });
      if (pronta) await funzionePren({ azione: "invia" });
      return pronta;
    },

    // Asporto: le regole (supabase/12-asporto.sql) e lo storico (13-asporto-storico.sql).
    // Gli ordini di stasera li gestisce il Banco del menu.
    aspImpostazioni: function (pin) { return rpc("asp_impostazioni", { p_pin: pin }); },
    aspSalvaImpostazioni: function (pin, dati) { return rpc("asp_salva_impostazioni", { p_pin: pin, p_dati: dati }); },
    aspStorico: function (pin, sera) { return rpc("asp_storico", { p_pin: pin, p_sera: sera || null }); },
    // WhatsApp di conferma delle prenotazioni (supabase/16-whatsapp.sql)
    waImpostazioni: function (pin) { return rpc("wa_impostazioni", { p_pin: pin }); },
    waSalva: function (pin, dati) { return rpc("wa_salva", { p_pin: pin, p_dati: dati }); },
    waMessaggi: function (pin) { return rpc("wa_messaggi", { p_pin: pin }); },
    waRispondi: function (pin, telefono, testo) { return rpc("wa_rispondi", { p_pin: pin, p_telefono: telefono, p_testo: testo }); },
  };

  return Object.assign({ DEMO: DEMO }, DEMO ? demo : reale);
})();
