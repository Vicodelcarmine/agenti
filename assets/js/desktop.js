/* Vico del Carmine · Dashboard da computer.
   Si sceglie un periodo (e un periodo di confronto): in alto i numeri principali con la
   differenza in %, sotto l'andamento giorno per giorno e i riquadri di ogni area. Un clic su un
   riquadro apre il dettaglio; i riquadri aperti più spesso si possono mettere per primi.
   I dati arrivano già aggregati dal database (desktop-dati.js → funzioni dash_*). */
(function () {
  "use strict";
  const D = window.Dati;
  const $ = function (s, el) { return (el || document).querySelector(s); };
  const $$ = function (s, el) { return Array.prototype.slice.call((el || document).querySelectorAll(s)); };

  /* ---------- memoria di questo computer ---------- */
  function leggi(k, d) { try { const v = JSON.parse(localStorage.getItem(k)); return v == null ? d : v; } catch (e) { return d; } }
  function scrivi(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }
  // lo stesso PIN della dashboard di tutti i giorni (titolare/): si entra una volta sola per tutte e due
  const K_PIN = "vdcpr_pin";
  let PIN = (function () { try { return sessionStorage.getItem(K_PIN) || localStorage.getItem(K_PIN) || ""; } catch (e) { return ""; } })();

  /* ---------- formati ---------- */
  const fEuro = new Intl.NumberFormat("it-IT", { style: "currency", currency: "EUR", maximumFractionDigits: 0 });
  const fNum = new Intl.NumberFormat("it-IT", { maximumFractionDigits: 1 });
  function euro(n) { return n == null || isNaN(n) ? "—" : fEuro.format(n); }
  function num(n) { return n == null || isNaN(n) ? "—" : fNum.format(n); }
  function pct(a, b) { return b ? Math.round(100 * a / b) + "%" : "—"; }
  function esc(s) { return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]; }); }
  const GIORNI = ["dom", "lun", "mar", "mer", "gio", "ven", "sab"];
  const GIORNI_ISO = ["", "lun", "mar", "mer", "gio", "ven", "sab", "dom"];
  const MESI = ["gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic"];
  function parti(s) { return String(s).slice(0, 10).split("-").map(Number); }
  function dow(s) { const p = parti(s); return new Date(Date.UTC(p[0], p[1] - 1, p[2])).getUTCDay(); }
  function dataBreve(s) { if (!s) return "—"; const p = parti(s); return GIORNI[dow(s)] + " " + p[2] + " " + MESI[p[1] - 1]; }
  function dataLunga(s) { if (!s) return "—"; const p = parti(s); return dataBreve(s) + " " + p[0]; }
  function quando(t) {
    if (!t) return "—";
    return new Intl.DateTimeFormat("it-IT", { timeZone: "Europe/Rome", day: "numeric", month: "short", hour: "2-digit", minute: "2-digit" }).format(new Date(t));
  }
  function giorniTra(a, b) { const x = parti(a), y = parti(b); return Math.round((Date.UTC(y[0], y[1] - 1, y[2]) - Date.UTC(x[0], x[1] - 1, x[2])) / 864e5); }
  const piu = D.piu;

  const NOMI_CANALE = {
    google: "Google", "google-maps": "Google Maps", instagram: "Instagram", facebook: "Facebook", tiktok: "TikTok",
    thefork: "TheFork", tripadvisor: "Tripadvisor", telefono: "Telefono", sito: "Sito (origine sconosciuta)",
    "manuale:telefono": "Telefono", "manuale:thefork": "TheFork", "manuale:google": "Google (segnata a mano)", "manuale:altro": "Altro (segnata a mano)",
    diretto: "Diretto", "campagna:regalo": "Campagna regalo", "campagna:regalo-thefork": "Campagna regalo", menu: "Menu",
    whatsapp: "WhatsApp", ricerca: "Altri motori di ricerca", "altro-sito": "Altri siti", prenotazione: "Prenotando dal sito",
    asporto: "Ordinando l'asporto", fortuna: "Gioco Fortuna", "menu-qr": "Menu o QR in sala", altro: "Altro", volantino: "Volantino",
  };
  function nomeCanale(c) { return NOMI_CANALE[c] || c; }
  const NOMI_PREMIO = { benvenuto: "Benvenuto", compleanno: "Compleanno", promo: "Offerte", fortuna: "Fortuna", regalo: "Regalo campagna" };
  const NOMI_WA = { prosecco: "Prosecco (regalo attivato)", club: "Invito al Club", voto: "Richiesta del voto", grazie: "Grazie + recensioni",
    basso: "Voto basso: cosa non è andato", stop: "Conferma STOP", start: "Conferma START", risposta: "Risposte tue", campagna: "Richiamo campagna regalo" };

  /* ---------- confronto ---------- */
  // differenza in % tra adesso e prima (meno è meglio per annullate, non presentati…)
  function delta(ora, prima, menoMeglio) {
    if (!STATO.cmp || ora == null || prima == null) return "";
    ora = Number(ora) || 0; prima = Number(prima) || 0;
    if (ora === prima) return '<span class="delta pari">= uguale</span>';
    if (prima === 0) return '<span class="delta ' + (menoMeglio ? "giu" : "su") + '">nuovo (prima 0)</span>';
    const d = Math.round(100 * (ora - prima) / Math.abs(prima));
    const buono = menoMeglio ? d < 0 : d > 0;
    return '<span class="delta ' + (buono ? "su" : "giu") + '">' + (d > 0 ? "▲ +" : "▼ ") + d + "%</span>";
  }

  /* ---------- stato ---------- */
  const STATO = {
    preset: leggi("vdc_desk_preset", "30"), dal: null, al: null, modoCmp: leggi("vdc_desk_cmp", "prec"),
    cmpDal: null, cmpAl: null, cur: null, cmp: null, cli: null, cliCmp: null, imp: null, salute: null, campagne: null,
    bordi: [],   // i giorni appena fuori dal periodo che servono ai grafici (settimana prima, mesi interi)
    metrica: leggi("vdc_desk_metrica", "incasso"), aperto: null,
  };
  const grafici = {};

  function periodoDa(chiave) {
    const oggi = D.oggiRoma(), p = parti(oggi);
    const primo = function (y, m) { return y + "-" + String(m).padStart(2, "0") + "-01"; };
    switch (chiave) {
      case "ieri": return [piu(oggi, -1), piu(oggi, -1)];
      case "7": return [piu(oggi, -6), oggi];
      case "30": return [piu(oggi, -29), oggi];
      case "90": return [piu(oggi, -89), oggi];
      case "mese": return [primo(p[0], p[1]), oggi];
      case "mesePrec": {
        const y = p[1] === 1 ? p[0] - 1 : p[0], m = p[1] === 1 ? 12 : p[1] - 1;
        return [primo(y, m), piu(primo(p[0], p[1]), -1)];
      }
      case "anno": return [p[0] + "-01-01", oggi];
      default: return [piu(oggi, -29), oggi];
    }
  }
  function confrontoDi(dal, al, modo) {
    if (!modo) return [null, null];
    const n = giorniTra(dal, al) + 1;
    const indietro = modo === "sett" ? Math.ceil(n / 7) * 7 : n;
    return [piu(dal, -indietro), piu(al, -indietro)];
  }

  // per i grafici servono anche i giorni appena fuori dal periodo: la settimana prima del primo giorno
  // e i mesi interi ai due bordi (per la media del mese). Qui i due pezzi da chiedere in più.
  function fineMese(s) {
    const p = parti(s), y = p[1] === 12 ? p[0] + 1 : p[0], m = p[1] === 12 ? 1 : p[1] + 1;
    return piu(y + "-" + String(m).padStart(2, "0") + "-01", -1);
  }
  function bordiDi(dal, al) {
    const oggi = D.oggiRoma(), primoMese = dal.slice(0, 8) + "01", unaSettimana = piu(dal, -7);
    const fine = fineMese(al) < oggi ? fineMese(al) : oggi;
    return [[unaSettimana < primoMese ? unaSettimana : primoMese, piu(dal, -1)], al < fine ? [piu(al, 1), fine] : null];
  }

  /* ---------- grafici (Chart.js) ---------- */
  if (window.Chart) {
    Chart.defaults.color = "#cbb49c";
    Chart.defaults.font.family = "Poppins, system-ui, sans-serif";
    Chart.defaults.font.size = 12;
    Chart.defaults.borderColor = "rgba(230,178,74,.10)";
    Chart.defaults.plugins.legend.labels.boxWidth = 12;
  }
  const ORO = "#e6b24a", ORO_T = "rgba(230,178,74,.55)", GRIGIO = "#8d7a68", BASILICO = "#86b64a", FIAMMA = "#c8102e", CREMA = "#f7efe2";
  const PALETTE = [ORO, BASILICO, "#d97a4a", "#7fb2c9", "#c98fd1", FIAMMA, "#e8d28a", "#6f9e7f", "#b9886a", "#9aa0c9"];
  function disegna(id, canvas, config) {
    if (grafici[id]) { grafici[id].destroy(); delete grafici[id]; }
    if (!window.Chart || !canvas) return;
    grafici[id] = new Chart(canvas, config);
  }
  function pulisciGrafici(prefisso) { Object.keys(grafici).forEach(function (k) { if (!prefisso || k.indexOf(prefisso) === 0) { grafici[k].destroy(); delete grafici[k]; } }); }

  // una serie giorno per giorno (le barre) con due linee per orientarsi: lo stesso giorno della settimana
  // prima (sabato con sabato) e la media del mese (per ogni giorno, la media dei giorni con un valore in
  // quel mese, anche fuori dal periodo). Le percentuali ▲▼ invece usano il confronto scelto in alto.
  function serieConfronto(id, canvas, chiave, opz) {
    opz = opz || {};
    const cur = STATO.cur.giorni;
    const valore = typeof chiave === "function" ? chiave : function (x) { return x[chiave]; };
    const perGiorno = {};
    (STATO.bordi || []).concat(cur).forEach(function (x) { perGiorno[x.g] = x; });
    const val = function (g) {
      const x = perGiorno[g], v = x ? valore(x) : null;
      return v == null || isNaN(v) ? null : Number(v);
    };
    const mesi = {};
    Object.keys(perGiorno).forEach(function (g) {
      const v = val(g);
      if (v == null) return;
      const m = mesi[g.slice(0, 7)] = mesi[g.slice(0, 7)] || { s: 0, n: 0 };
      m.s += v; m.n++;
    });
    const media = function (g) { const m = mesi[g.slice(0, 7)]; return m && m.n ? m.s / m.n : null; };
    const fmt = function (v) { return opz.euro ? euro(v) : num(v); };
    const ds = [{
      label: opz.etichetta || "Periodo scelto", data: cur.map(valore), type: opz.tipo || "bar",
      backgroundColor: ORO_T, borderColor: ORO, borderWidth: opz.tipo === "line" ? 2 : 0, borderRadius: 4, tension: .3, spanGaps: true,
      pointRadius: opz.tipo === "line" ? 2 : 0, order: 3,
    }, {
      label: "Settimana prima", data: cur.map(function (x) { return val(piu(x.g, -7)); }), type: "line",
      borderColor: GRIGIO, borderDash: [5, 4], borderWidth: 2, pointRadius: 0, tension: .3, spanGaps: true, order: 2,
      hidden: cur.length > 100,   // su un anno intero è solo un doppione delle barre: si accende dalla legenda
    }, {
      label: "Media del mese", data: cur.map(function (x) { return media(x.g); }), type: "line",
      borderColor: BASILICO, borderWidth: 2, pointRadius: 0, stepped: "middle", spanGaps: true, order: 1,
    }];
    disegna(id, canvas, {
      type: "bar", data: { labels: cur.map(function (x) { return dataBreve(x.g); }), datasets: ds },
      options: { responsive: true, maintainAspectRatio: false, interaction: { mode: "index", intersect: false },
        plugins: { legend: { labels: { sort: function (a, b) { return a.datasetIndex - b.datasetIndex; } } },
          tooltip: { callbacks: {
          title: function (it) { return dataLunga(cur[it[0].dataIndex].g); },
          label: function (c) {
            const g = cur[c.dataIndex].g;
            if (c.datasetIndex === 1) return "Settimana prima (" + dataBreve(piu(g, -7)) + "): " + fmt(c.parsed.y);
            if (c.datasetIndex === 2) return "Media di " + nomeMese(g.slice(0, 7)).toLowerCase() + ": " + fmt(c.parsed.y);
            return c.dataset.label + ": " + fmt(c.parsed.y);
          } } } },
        scales: { x: { grid: { display: false }, ticks: { maxTicksLimit: 16 } },
          y: { beginAtZero: true, ticks: { callback: function (v) { return fmt(v); } } } } },
    });
  }
  function barre(id, canvas, etichette, serie, opz) {
    opz = opz || {};
    disegna(id, canvas, {
      type: "bar",
      data: { labels: etichette, datasets: serie.map(function (s, i) {
        return { label: s.label, data: s.data, backgroundColor: s.colore || (i === 0 ? ORO_T : "rgba(141,122,104,.55)"), borderRadius: 4 };
      }) },
      options: { responsive: true, maintainAspectRatio: false, indexAxis: opz.orizzontale ? "y" : "x",
        plugins: { legend: { display: serie.length > 1 } },
        scales: { x: { grid: { display: !!opz.orizzontale }, beginAtZero: true }, y: { beginAtZero: true, grid: { display: !opz.orizzontale } } } },
    });
  }
  function ciambella(id, canvas, etichette, valori) {
    disegna(id, canvas, {
      type: "doughnut",
      data: { labels: etichette, datasets: [{ data: valori, backgroundColor: PALETTE, borderColor: "#2a1d18", borderWidth: 2 }] },
      options: { responsive: true, maintainAspectRatio: false, cutout: "58%", plugins: { legend: { position: "right" } } },
    });
  }
  function scintilla(id, canvas, valori) {
    disegna(id, canvas, {
      type: "line",
      data: { labels: valori.map(function (_, i) { return i; }), datasets: [{ data: valori, borderColor: ORO, backgroundColor: "rgba(230,178,74,.12)",
        fill: true, borderWidth: 1.6, pointRadius: 0, tension: .35, spanGaps: true }] },
      options: { responsive: true, maintainAspectRatio: false, animation: false,
        plugins: { legend: { display: false }, tooltip: { enabled: false } }, scales: { x: { display: false }, y: { display: false, beginAtZero: true } } },
    });
  }

  /* ---------- finestra ---------- */
  function apriFinestra(html) { $("#finestra-corpo").innerHTML = html; $("#velo").hidden = false; }
  function chiudiFinestra() { $("#velo").hidden = true; $("#finestra-corpo").innerHTML = ""; pulisciGrafici("f-"); }
  $("#b-chiudi").addEventListener("click", chiudiFinestra);
  $("#velo").addEventListener("click", function (e) { if (e.target.id === "velo") chiudiFinestra(); });
  document.addEventListener("keydown", function (e) { if (e.key === "Escape" && !$("#velo").hidden) chiudiFinestra(); });

  function problema(e) {
    if (e && e.codice === "pin") { esci(); $("#login-errore").textContent = "PIN cambiato o sbagliato: rientra."; return; }
    alert((e && e.message) || "Qualcosa non ha funzionato");
  }

  /* ================= accesso ================= */
  function mostraLogin() { $("#app").hidden = true; $("#login").hidden = false; setTimeout(function () { $("#pin").focus(); }, 50); }
  function esci() {
    PIN = "";
    try { sessionStorage.removeItem(K_PIN); localStorage.removeItem(K_PIN); } catch (e) {}
    pulisciGrafici();
    mostraLogin();
  }
  $("#f-login").addEventListener("submit", async function (e) {
    e.preventDefault();
    const pin = $("#pin").value.trim();
    $("#login-errore").textContent = "";
    if (!pin) return;
    try {
      await D.entra(pin);
      PIN = pin;
      try { (($("#ricorda").checked) ? localStorage : sessionStorage).setItem(K_PIN, pin); } catch (er) {}
      $("#pin").value = "";
      avvia();
    } catch (er) { $("#login-errore").textContent = er.codice === "pin" ? "PIN sbagliato" : er.message; }
  });
  $("#b-esci").addEventListener("click", esci);

  /* ================= periodo ================= */
  function impostaPeriodo(dal, al, preset) {
    STATO.dal = dal; STATO.al = al; STATO.preset = preset || "";
    if (preset) scrivi("vdc_desk_preset", preset);
    const c = confrontoDi(dal, al, STATO.modoCmp);
    STATO.cmpDal = c[0]; STATO.cmpAl = c[1];
    $("#dal").value = dal; $("#al").value = al;
    $$("#periodi button").forEach(function (b) { b.classList.toggle("on", b.dataset.p === preset); });
    carica();
  }
  $$("#periodi button").forEach(function (b) {
    b.addEventListener("click", function () { const p = periodoDa(b.dataset.p); $("#periodi-salvati").value = ""; impostaPeriodo(p[0], p[1], b.dataset.p); });
  });
  ["#dal", "#al"].forEach(function (s) {
    $(s).addEventListener("change", function () {
      const dal = $("#dal").value, al = $("#al").value;
      if (!dal || !al || al < dal) return;
      if (giorniTra(dal, al) > 400) { alert("Al massimo 400 giorni alla volta."); return; }
      $("#periodi-salvati").value = "";
      impostaPeriodo(dal, al, "");
    });
  });
  $("#confronto").addEventListener("change", function () {
    STATO.modoCmp = this.value; scrivi("vdc_desk_cmp", this.value);
    impostaPeriodo(STATO.dal, STATO.al, STATO.preset);
  });
  $("#periodi-salvati").addEventListener("change", function () {
    const p = (STATO.imp.periodi || []).find(function (x) { return String(x.id) === this.value; }, this);
    if (!p) return;
    const al = p.al && p.al < D.oggiRoma() ? p.al : D.oggiRoma();
    impostaPeriodo(p.dal, al < p.dal ? p.dal : al, "");
  });
  $("#metrica").addEventListener("change", function () { STATO.metrica = this.value; scrivi("vdc_desk_metrica", this.value); disegnaAndamento(); });
  $("#b-aggiorna").addEventListener("click", function () { carica(); });
  $("#piu-usati").addEventListener("change", function () { scrivi("vdc_desk_piu_usati", this.checked); disegnaRiquadri(); });

  function riempiPeriodiSalvati() {
    const s = $("#periodi-salvati"), v = s.value;
    s.innerHTML = '<option value="">Periodi salvati…</option>' + (STATO.imp.periodi || []).map(function (p) {
      return '<option value="' + p.id + '">' + esc(p.nome) + " · " + dataBreve(p.dal) + (p.al ? " → " + dataBreve(p.al) : " → in corso") + "</option>";
    }).join("");
    s.value = v;
  }

  /* ================= caricamento ================= */
  let caricando = 0;
  async function carica() {
    const mio = ++caricando;
    $("#riga-periodo").innerHTML = "Carico…";
    try {
      const b = bordiDi(STATO.dal, STATO.al), niente = function () { return null; };
      const v = await Promise.all([
        D.riepilogo(PIN, STATO.dal, STATO.al),
        STATO.cmpDal ? D.riepilogo(PIN, STATO.cmpDal, STATO.cmpAl) : null,
        D.clienti(PIN, STATO.dal, STATO.al),
        STATO.cmpDal ? D.clienti(PIN, STATO.cmpDal, STATO.cmpAl) : null,
        D.salute(PIN),
        D.campagne(PIN).catch(function () { return []; }),
        D.riepilogo(PIN, b[0][0], b[0][1]).catch(niente),
        b[1] ? D.riepilogo(PIN, b[1][0], b[1][1]).catch(niente) : null,
      ]);
      if (mio !== caricando) return;
      STATO.cur = v[0]; STATO.cmp = v[1]; STATO.cli = v[2]; STATO.cliCmp = v[3]; STATO.salute = v[4]; STATO.campagne = v[5] || [];
      STATO.bordi = [].concat(v[6] ? v[6].giorni : [], v[7] ? v[7].giorni : []);
      disegnaTutto();
    } catch (e) { if (mio === caricando) { $("#riga-periodo").textContent = ""; problema(e); } }
  }

  function disegnaTutto() {
    const n = giorniTra(STATO.dal, STATO.al) + 1;
    $("#riga-periodo").innerHTML = "Periodo <b>" + dataLunga(STATO.dal) + " → " + dataLunga(STATO.al) + "</b> (" + n + (n === 1 ? " giorno" : " giorni") + ")" +
      (STATO.cmp ? " · le % ▲▼ confrontano con <b>" + dataLunga(STATO.cmpDal) + " → " + dataLunga(STATO.cmpAl) + "</b>" : " · senza %") +
      (STATO.al >= D.oggiRoma() ? ' · <span class="dim">oggi è ancora in corso: l\'incasso di stasera arriva stanotte</span>' : "");
    disegnaAvvisi();
    disegnaKpi();
    disegnaAndamento();
    disegnaRiquadri();
    if (STATO.aperto) apriDettaglio(STATO.aperto, true);
  }

  function disegnaAvvisi() {
    const s = STATO.salute, out = [];
    if (s) {
      if (s.waCoda) out.push("💬 " + s.waCoda + " messaggi WhatsApp fermi in coda da più di mezz'ora.");
      if (s.waErrori24h) out.push("💬 " + s.waErrori24h + " WhatsApp non partiti nelle ultime 24 ore" + (s.waUltimoErrore ? " (" + esc(s.waUltimoErrore) + ")" : "") + ".");
      if (s.avvisiFermi) out.push("🔔 " + s.avvisiFermi + " avvisi delle prenotazioni non partiti.");
      if (s.clubCoda) out.push("💳 " + s.clubCoda + " messaggi del Club fermi in coda.");
      if (s.erp && s.erp.collegato && s.ultimaSeraCassa && giorniTra(s.ultimaSeraCassa, s.oggi) > 2)
        out.push("💶 Il collegamento della cassa non manda l'incasso dal " + dataBreve(s.ultimaSeraCassa) + ".");
    }
    const inizio = STATO.imp && STATO.imp.inizio;
    let info = "";
    if (STATO.cmp && inizio) {
      const primo = [inizio.prenotazioni, inizio.club, inizio.agenti].filter(Boolean).sort()[0];
      if (primo && STATO.cmpDal < primo) info = "ℹ️ Il periodo di confronto comincia prima che il sistema raccogliesse i dati (" + dataBreve(primo) + "): le differenze in % vanno prese con le pinze.";
    }
    $("#avvisi").innerHTML = out.map(function (t) { return '<div class="avviso">' + t + "</div>"; }).join("") +
      (info ? '<div class="avviso info">' + info + "</div>" : "");
  }

  /* ================= numeri in alto ================= */
  function totale(r, k) { return r ? r.giorni.reduce(function (s, x) { return s + (Number(x[k]) || 0); }, 0) : null; }
  function disegnaKpi() {
    const c = STATO.cur, p = STATO.cmp, cl = STATO.cli, cp = STATO.cliCmp;
    const perCop = function (r) { return r && r.cassa.coperti ? r.cassa.incasso / r.cassa.coperti : null; };
    const k = [
      { l: "Incasso (cassa)", v: euro(c.cassa.incasso), d: delta(c.cassa.incasso, p && p.cassa.incasso), n: c.cassa.sere ? c.cassa.sere + " sere registrate" : "nessuna sera registrata" },
      { l: "Coperti (cassa)", v: num(c.cassa.coperti), d: delta(c.cassa.coperti, p && p.cassa.coperti), n: "€ a coperto: " + euro(perCop(c)) },
      { l: "Persone prenotate", v: num(c.prenotazioni.persone), d: delta(c.prenotazioni.persone, p && p.prenotazioni.persone), n: num(c.prenotazioni.totale) + " prenotazioni" },
      { l: "Clienti nuovi", v: num(cl.nuovi), d: delta(cl.nuovi, cp && cp.nuovi), n: num(cl.tornati) + " clienti tornati" },
      { l: "Nuovi nel Club", v: num(c.club.nuovi), d: delta(c.club.nuovi, p && p.club.nuovi), n: num(c.club.totale) + " iscritti in tutto" },
      { l: "Asporto", v: euro(c.asporto.euro), d: delta(c.asporto.euro, p && p.asporto.euro), n: num(c.asporto.ordini) + " ordini" },
      { l: "Portati dagli agenti", v: num(totale(c, "prPersone")), d: delta(totale(c, "prPersone"), totale(p, "prPersone")), n: num(totale(c, "tavoli")) + " tavoli · " + euro(totale(c, "prEuro")) },
    ];
    $("#kpi").innerHTML = k.map(function (x) {
      return '<div class="k"><span>' + x.l + "</span><b>" + x.v + "</b>" + (x.d || "") + '<div class="dim">' + x.n + "</div></div>";
    }).join("");
  }

  function disegnaAndamento() {
    const m = STATO.metrica;
    $("#metrica").value = m;
    serieConfronto("andamento", $("#g-andamento"), m, { euro: m === "incasso" || m === "aspEuro", tipo: m === "incasso" || m === "coperti" ? "bar" : "bar" });
  }

  /* ================= i riquadri ================= */
  function g(r, k) { return totale(r, k); }
  const RIQUADRI = [
    { id: "incassi", ic: "💶", t: "Incassi", s: "incasso", n: function (c, p) {
        return [[euro(c.cassa.incasso), "incasso", delta(c.cassa.incasso, p && p.cassa.incasso)],
          [euro(c.cassa.coperti ? c.cassa.incasso / c.cassa.coperti : null), "a coperto", ""],
          [euro(c.cassa.scontrini ? c.cassa.incasso / c.cassa.scontrini : null), "scontrino medio", ""]]; },
      nota: function (c) { return c.cassa.sere ? c.cassa.daErp + " sere automatiche, " + (c.cassa.sere - c.cassa.daErp) + " a mano" : "Nessun incasso: collega la cassa o scrivilo a mano."; } },
    { id: "prenotazioni", ic: "📅", t: "Prenotazioni", s: "persone", n: function (c, p) {
        return [[num(c.prenotazioni.totale), "prenotazioni", delta(c.prenotazioni.totale, p && p.prenotazioni.totale)],
          [num(c.prenotazioni.persone), "persone", delta(c.prenotazioni.persone, p && p.prenotazioni.persone)],
          [num(c.prenotazioni.annullate + c.prenotazioni.noshow), "annullate o non venuti", delta(c.prenotazioni.annullate + c.prenotazioni.noshow, p && (p.prenotazioni.annullate + p.prenotazioni.noshow), true)]]; } },
    { id: "clienti", ic: "👥", t: "Clienti e frequenza", s: null, n: function () {
        const c = STATO.cli, p = STATO.cliCmp;
        return [[num(c.attivi), "clienti venuti", delta(c.attivi, p && p.attivi)], [num(c.nuovi), "nuovi", delta(c.nuovi, p && p.nuovi)],
          [num(c.tornati), "tornati", delta(c.tornati, p && p.tornati)]]; },
      nota: function () { return STATO.cli.intervalloMedio ? "Chi torna, torna in media ogni " + num(STATO.cli.intervalloMedio) + " giorni" : "Scheda di ogni cliente e chi riconquistare"; } },
    { id: "canali", ic: "🧭", t: "Canali", s: "visite", n: function (c) {
        const ch = Object.keys(c.prenotazioni.canali).map(function (k) { return [k, c.prenotazioni.canali[k].n]; }).sort(function (a, b) { return b[1] - a[1]; });
        return [[ch.length ? esc(nomeCanale(ch[0][0])) : "—", "primo canale", ""], [ch.length ? pct(ch[0][1], c.prenotazioni.totale) : "—", "delle prenotazioni", ""],
          [num(Object.keys(c.prenotazioni.canali).length), "canali usati", ""]]; } },
    { id: "campagne", ic: "🎯", t: "Campagne e periodi", s: null, n: function () {
        const k = (STATO.campagne || [])[0];
        return k ? [[num(k.scoperti), "regali scoperti", ""], [num(k.prenotati), "hanno prenotato", ""], [num(k.usati), "regali usati", ""]]
          : [["—", "", ""], ["—", "", ""], ["—", "", ""]]; },
      nota: function () { const n = (STATO.imp.periodi || []).length; return n + (n === 1 ? " periodo salvato" : " periodi salvati") + " da confrontare"; } },
    { id: "agenti", ic: "🕺", t: "Agenti PR", s: "tavoli", n: function (c, p) {
        return [[num(g(c, "tavoli")), "tavoli", delta(g(c, "tavoli"), g(p, "tavoli"))], [num(g(c, "prPersone")), "persone", delta(g(c, "prPersone"), g(p, "prPersone"))],
          [euro(g(c, "prEuro")), "provvigioni", ""]]; } },
    { id: "club", ic: "💳", t: "Club", s: "club", n: function (c, p) {
        const usati = Object.keys(c.club.premi).reduce(function (s, k) { return s + c.club.premi[k].usati; }, 0);
        return [[num(c.club.nuovi), "nuovi iscritti", delta(c.club.nuovi, p && p.club.nuovi)], [num(c.club.totale), "iscritti in tutto", ""], [num(usati), "premi usati", ""]]; } },
    { id: "asporto", ic: "🛍️", t: "Asporto", s: "aspEuro", n: function (c, p) {
        return [[num(c.asporto.ordini), "ordini", delta(c.asporto.ordini, p && p.asporto.ordini)], [euro(c.asporto.euro), "incasso", delta(c.asporto.euro, p && p.asporto.euro)],
          [euro(c.asporto.ordini ? c.asporto.euro / c.asporto.ordini : null), "a ordine", ""]]; } },
    { id: "ordini", ic: "🍽️", t: "Ordini al tavolo", s: "ordiniEuro", n: function (c, p) {
        return [[num(c.ordini.ordini), "ordini dal QR", delta(c.ordini.ordini, p && p.ordini.ordini)], [euro(c.ordini.euro), "valore", ""], [num(c.ordini.coperti), "coperti dichiarati", ""]]; } },
    { id: "whatsapp", ic: "💬", t: "WhatsApp", s: "waInviati", n: function (c) {
        const w = c.whatsapp, inv = w.conferme.inviate + Object.keys(w.messaggi).reduce(function (s, k) { return s + w.messaggi[k].inviati; }, 0);
        const lett = w.conferme.lette + Object.keys(w.messaggi).reduce(function (s, k) { return s + w.messaggi[k].letti; }, 0);
        return [[num(inv), "inviati", ""], [pct(lett, inv), "letti", ""], [num(w.ricevuti), "ricevuti", ""]]; } },
    { id: "voti", ic: "⭐", t: "Voti dei clienti", s: null, n: function (c, p) {
        const v = c.prenotazioni.voti, alti = (v.distribuzione["4"] || 0) + (v.distribuzione["5"] || 0);
        return [[v.media == null ? "—" : num(v.media), "voto medio", p && p.prenotazioni.voti.media != null && v.media != null ? delta(v.media, p.prenotazioni.voti.media) : ""],
          [num(v.n), "voti", ""], [pct(alti, v.n), "4 o 5 stelle", ""]]; } },
    { id: "fortuna", ic: "🎰", t: "Gioco Fortuna", s: "fortuna", n: function (c, p) {
        return [[num(c.fortuna.giocate), "giocate", delta(c.fortuna.giocate, p && p.fortuna.giocate)], [num(c.fortuna.riscattate), "premi riscattati", ""],
          [pct(c.fortuna.riscattate, c.fortuna.giocate), "riscattati", ""]]; } },
    { id: "sito", ic: "🌐", t: "Sito", s: "visite", n: function (c, p) {
        const ps = c.prenotazioni.canali, dalSito = Object.keys(ps).filter(function (k) { return k.indexOf("manuale:") !== 0; })
          .reduce(function (s, k) { return s + ps[k].n; }, 0);
        return [[num(c.sito.visite), "visite", delta(c.sito.visite, p && p.sito.visite)], [num(dalSito), "prenotazioni online", ""], [pct(dalSito, c.sito.visite), "visite → prenotazione", ""]]; } },
    { id: "salute", ic: "🩺", t: "Salute del sistema", s: null, n: function () {
        const s = STATO.salute, prob = (s.waCoda ? 1 : 0) + (s.waErrori24h ? 1 : 0) + (s.avvisiFermi ? 1 : 0) + (s.clubCoda ? 1 : 0);
        return [[prob ? prob : "✓", prob ? "cose da guardare" : "tutto a posto", ""], [s.erp && s.erp.collegato ? "sì" : "no", "gestionale collegato", ""],
          [s.waAcceso ? "acceso" : "spento", "WhatsApp", ""]]; } },
  ];
  function aperture() { return leggi("vdc_desk_aperture", {}); }
  function disegnaRiquadri() {
    const c = STATO.cur, p = STATO.cmp;
    $("#piu-usati").checked = !!leggi("vdc_desk_piu_usati", false);
    let lista = RIQUADRI.slice();
    if ($("#piu-usati").checked) { const a = aperture(); lista.sort(function (x, y) { return (a[y.id] || 0) - (a[x.id] || 0); }); }
    pulisciGrafici("mini-");
    $("#riquadri").innerHTML = lista.map(function (r) {
      let numeri = [];
      try { numeri = r.n(c, p); } catch (e) { numeri = [["—", "", ""], ["—", "", ""], ["—", "", ""]]; }
      const nota = r.nota ? r.nota(c, p) : "";
      return '<article class="riquadro" data-id="' + r.id + '"><div class="r-testa"><h3><span>' + r.ic + "</span>" + r.t + '</h3><span class="apri">Apri ›</span></div>' +
        '<div class="numeri">' + numeri.map(function (x) {
          const parola = /[a-z]{3,}/i.test(String(x[0]).replace(/<[^>]+>/g, "")) && !/€/.test(x[0]);   // un nome, non un numero
          return "<div><b" + (parola ? ' class="parola"' : "") + ">" + x[0] + "</b><span>" + x[1] + "</span>" + (x[2] || "") + "</div>"; }).join("") + "</div>" +
        (r.s ? '<div class="mini"><canvas></canvas></div>' : "") + (nota ? '<div class="nota">' + nota + "</div>" : "") + "</article>";
    }).join("");
    $$("#riquadri .riquadro").forEach(function (el) {
      const r = RIQUADRI.find(function (x) { return x.id === el.dataset.id; });
      if (r.s) scintilla("mini-" + r.id, $("canvas", el), c.giorni.map(function (x) { return x[r.s]; }));
      el.addEventListener("click", function () { apriDettaglio(r.id); });
    });
  }

  /* ================= il dettaglio ================= */
  function apriDettaglio(id, ridisegna) {
    const r = RIQUADRI.find(function (x) { return x.id === id; });
    if (!r) return;
    if (!ridisegna) { const a = aperture(); a[id] = (a[id] || 0) + 1; scrivi("vdc_desk_aperture", a); }
    STATO.aperto = id;
    $("#riquadri").hidden = true; $(".barra-riquadri").hidden = true;
    $("#dettaglio").hidden = false;
    $("#dettaglio-titolo").textContent = r.ic + " " + r.t;
    pulisciGrafici("d-");
    const corpo = $("#dettaglio-corpo");
    corpo.innerHTML = "";
    (DETTAGLI[id] || function () { corpo.innerHTML = '<p class="vuoto-dati">In arrivo.</p>'; })(corpo);
    if (!ridisegna) window.scrollTo({ top: $("#dettaglio").offsetTop - 90, behavior: "smooth" });
  }
  $("#b-indietro").addEventListener("click", function () {
    STATO.aperto = null; pulisciGrafici("d-");
    $("#dettaglio").hidden = true; $("#riquadri").hidden = false; $(".barra-riquadri").hidden = false;
    disegnaRiquadri();
  });

  function card(classe, titolo, dentro) { return '<section class="card ' + classe + '">' + (titolo ? '<div class="card-testa"><h3>' + titolo + "</h3></div>" : "") + dentro + "</section>"; }
  function kpiRiga(lista) {
    return '<section class="kpi">' + lista.map(function (x) {
      return '<div class="k"><span>' + x[0] + "</span><b>" + x[1] + "</b>" + (x[2] || "") + (x[3] ? '<div class="dim">' + x[3] + "</div>" : "") + "</div>";
    }).join("") + "</section>";
  }
  function tabella(intest, righe, opz) {
    opz = opz || {};
    if (!righe.length) return '<p class="vuoto-dati">' + (opz.vuoto || "Ancora nessun dato in questo periodo.") + "</p>";
    return '<div class="' + (opz.scorri ? "scorri" : "") + '"><table class="tab"><thead><tr>' + intest.map(function (h) {
      return '<th class="' + (h[1] ? "n" : "") + '">' + h[0] + "</th>"; }).join("") + "</tr></thead><tbody>" +
      righe.map(function (r) {
        return "<tr" + (r.attr || "") + ">" + r.c.map(function (v, i) { return '<td class="' + (intest[i] && intest[i][1] ? "n" : "") + '">' + v + "</td>"; }).join("") + "</tr>";
      }).join("") + "</tbody></table></div>";
  }
  // tabella a tendine: ogni gruppo ha una riga coi totali (si tocca per aprirla) e sotto le sue righe
  function tabellaGruppi(intest, gruppi, aperti, opz) {
    opz = opz || {};
    if (!gruppi.length) return '<p class="vuoto-dati">' + (opz.vuoto || "Ancora nessun dato in questo periodo.") + "</p>";
    const cella = function (v, i) { return '<td class="' + (intest[i] && intest[i][1] ? "n" : "") + '">' + v + "</td>"; };
    return '<div class="' + (opz.scorri ? "scorri" : "") + '"><table class="tab"><thead><tr>' + intest.map(function (h) {
      return '<th class="' + (h[1] ? "n" : "") + '">' + h[0] + "</th>"; }).join("") + "</tr></thead>" +
      gruppi.map(function (gr) {
        const aperto = aperti.has(gr.chiave);
        return '<tbody><tr class="gruppo-testa' + (aperto ? " aperto" : "") + '" data-gruppo="' + esc(gr.chiave) + '" tabindex="0" aria-expanded="' + aperto + '">' +
          gr.testa.map(function (v, i) { return cella(i === 0 ? '<span class="freccia" aria-hidden="true">▸</span>' + v : v, i); }).join("") + "</tr></tbody>" +
          '<tbody class="gruppo-righe"' + (aperto ? "" : " hidden") + ">" + gr.righe.map(function (r) {
            return "<tr" + (r.attr || "") + ">" + r.c.map(cella).join("") + "</tr>"; }).join("") + "</tbody>";
      }).join("") + "</table></div>";
  }
  // apre e chiude le tendine dentro box (una volta sola per box) e si ricorda quali sono aperte
  function tendine(box, aperti) {
    if (box.dataset.tendine) return;
    box.dataset.tendine = "1";
    const gira = function (tr) {
      const k = tr.dataset.gruppo, aperto = !aperti.has(k);
      if (aperto) aperti.add(k); else aperti.delete(k);
      tr.classList.toggle("aperto", aperto);
      tr.setAttribute("aria-expanded", String(aperto));
      tr.parentNode.nextElementSibling.hidden = !aperto;
    };
    box.addEventListener("click", function (e) {
      const tr = e.target.closest(".gruppo-testa");
      if (tr && box.contains(tr)) gira(tr);
    });
    box.addEventListener("keydown", function (e) {
      const tr = e.target.closest(".gruppo-testa");
      if (tr && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); gira(tr); }
    });
  }
  function nomeMese(k) {
    const t = new Date(k + "-15T12:00:00").toLocaleDateString("it-IT", { month: "long", year: "numeric" });
    return t.charAt(0).toUpperCase() + t.slice(1);
  }
  const canvas = function (id, classe) { return '<div class="grafico ' + (classe || "") + '"><canvas id="' + id + '"></canvas></div>'; };

  // il riquadro del collegamento automatico della cassa (la chiave) resta nascosto: scelta del titolare
  // (26/10/2026). Per riaprirlo: MOSTRA_COLLEGAMENTO = true
  const MOSTRA_COLLEGAMENTO = false;
  // le tendine aperte (categorie degli articoli, mesi delle sere): restano aperte finché non si chiude la pagina
  const APERTE_CAT = new Set(), APERTI_MESI = new Set();
  let modificaCategorie = false;

  const DETTAGLI = {
    /* ---------- incassi ---------- */
    incassi: function (corpo) {
      const c = STATO.cur, p = STATO.cmp, s = STATO.salute;
      const perCop = function (r) { return r && r.cassa.coperti ? r.cassa.incasso / r.cassa.coperti : null; };
      const perSc = function (r) { return r && r.cassa.scontrini ? r.cassa.incasso / r.cassa.scontrini : null; };
      const erp = s.erp || {};
      corpo.innerHTML = kpiRiga([
        ["Incasso", euro(c.cassa.incasso), delta(c.cassa.incasso, p && p.cassa.incasso), c.cassa.sere + " sere registrate"],
        ["Media per sera", euro(c.cassa.sere ? c.cassa.incasso / c.cassa.sere : null), p && p.cassa.sere ? delta(c.cassa.incasso / (c.cassa.sere || 1), p.cassa.incasso / p.cassa.sere) : ""],
        ["Coperti", num(c.cassa.coperti), delta(c.cassa.coperti, p && p.cassa.coperti)],
        ["€ a coperto", euro(perCop(c)), p ? delta(perCop(c), perCop(p)) : ""],
        ["Scontrino medio", euro(perSc(c)), p ? delta(perSc(c), perSc(p)) : ""],
        ["Persone dal sistema", pct(c.prenotazioni.persone + g(c, "prPersone"), c.cassa.coperti), "", "prenotate + portate dagli agenti, sui coperti"],
      ]) +
      '<div class="griglia">' + card(MOSTRA_COLLEGAMENTO ? "c8" : "c12", "Incasso sera per sera", canvas("d-inc", "alto")) +
      (MOSTRA_COLLEGAMENTO ? card("c4", "🔌 Collegamento automatico (cassa)",
        '<p>' + (erp.collegato ? '<span class="pill ok">collegato</span> chiave creata il ' + quando(erp.creata) : '<span class="pill no">non collegato</span>') + "</p>" +
        '<p class="dim" style="margin-top:8px">Ultimo invio: ' + quando(erp.ultimoInvio) + (erp.ultimoEsito ? " · " + esc(erp.ultimoEsito) : "") + "</p>" +
        '<p class="dim" style="margin-top:8px">Le chiusure di cassa arrivano da sole da Google Drive (account chiusurevico, ogni mattina tra le 7 e le 8) con una chiave. Istruzioni: <b>MENU/collegamento-cassa/LEGGIMI.md</b>. Più avanti la stessa chiave servirà al gestionale o al POS.</p>' +
        '<p style="margin-top:12px"><button class="btn ' + (erp.collegato ? "vuoto" : "oro") + '" id="b-chiave">' + (erp.collegato ? "Crea una chiave nuova" : "Crea la chiave del collegamento") + "</button></p>") : "") +
      "</div>" +
      '<div id="cassa-articoli"></div>' +
      card("c12", "Sera per sera · scrivi o correggi a mano", '<p class="dim aiuto-tendine">Tocca un mese per vedere le sue sere.</p><div id="tab-cassa"></div>');
      serieConfronto("d-inc", $("#d-inc"), "incasso", { euro: true });
      disegnaTabCassa();
      disegnaArticoliCassa();
      if (MOSTRA_COLLEGAMENTO) $("#b-chiave").addEventListener("click", async function () {
        if (erp.collegato && !confirm("Creo una chiave nuova? Quella vecchia smette subito di funzionare: andrà cambiata anche nello script di Google (Proprietà script → VICO_CHIAVE).")) return;
        try {
          const r = await D.erpChiave(PIN);
          apriFinestra("<h2>🔑 Chiave del collegamento</h2><p class=\"muted\" style=\"margin-top:6px\">Copiala adesso e incollala nello script di Google (Proprietà script → <b>VICO_CHIAVE</b>): <b>non si vedrà più</b>. Non mandarla per messaggio e non metterla nel codice.</p>" +
            '<div class="chiave" id="la-chiave">' + esc(r.chiave) + '</div><button class="btn oro" id="b-copia">Copia</button> <span class="dim" id="copiata"></span>');
          $("#b-copia").addEventListener("click", function () {
            navigator.clipboard.writeText(r.chiave).then(function () { $("#copiata").textContent = "Copiata ✓"; }, function () { $("#copiata").textContent = "Selezionala e copia a mano"; });
          });
          STATO.salute = await D.salute(PIN);
        } catch (e) { problema(e); }
      });
    },

    /* ---------- prenotazioni ---------- */
    prenotazioni: function (corpo) {
      const c = STATO.cur, p = STATO.cmp, pr = c.prenotazioni, pp = p && p.prenotazioni;
      corpo.innerHTML = kpiRiga([
        ["Prenotazioni", num(pr.totale), delta(pr.totale, pp && pp.totale)],
        ["Persone", num(pr.persone), delta(pr.persone, pp && pp.persone)],
        ["Persone a prenotazione", num(pr.totale ? pr.persone / pr.totale : null)],
        ["Annullate", num(pr.annullate), delta(pr.annullate, pp && pp.annullate, true), pct(pr.annullate, pr.totale + pr.annullate) + " del totale"],
        ["Non presentati", num(pr.noshow), delta(pr.noshow, pp && pp.noshow, true), "segnati a mano"],
        ["Anticipo medio", pr.anticipo == null ? "—" : num(pr.anticipo) + " gg", "", "tra prenotazione e serata (sito)"],
        ["Clienti nuovi dal sito", num(pr.benvenuto), delta(pr.benvenuto, pp && pp.benvenuto), "hanno avuto il prosecco"],
      ]) +
      '<div class="griglia">' + card("c8", "Persone prenotate sera per sera", canvas("d-pp", "alto")) + card("c4", "Da dove arrivano", canvas("d-can", "alto")) + "</div>" +
      '<div class="griglia">' + card("c6", "Giorni della settimana (persone)", canvas("d-sett")) + card("c6", "Ora di arrivo", canvas("d-ore")) + "</div>" +
      '<div class="griglia">' + card("c8", "Quando sono più pieni: giorno × ora (persone)", '<div id="mappa"></div>') + card("c4", "Grandezza dei tavoli", canvas("d-gruppi")) + "</div>";
      serieConfronto("d-pp", $("#d-pp"), "persone");
      const ch = Object.keys(pr.canali).sort(function (a, b) { return pr.canali[b].n - pr.canali[a].n; });
      ciambella("d-can", $("#d-can"), ch.map(nomeCanale), ch.map(function (k) { return pr.canali[k].n; }));
      const serieSett = [{ label: "Periodo scelto", data: pr.settimana.map(function (x) { return x.persone; }) }];
      if (pp) serieSett.push({ label: "Confronto", data: pp.settimana.map(function (x) { return x.persone; }) });
      barre("d-sett", $("#d-sett"), pr.settimana.map(function (x) { return GIORNI_ISO[x.d]; }), serieSett);
      barre("d-ore", $("#d-ore"), pr.orari.map(function (x) { return x.ora; }), [{ label: "Persone", data: pr.orari.map(function (x) { return x.persone; }) }]);
      const gk = ["1-2", "3-4", "5-6", "7+"];
      barre("d-gruppi", $("#d-gruppi"), gk.map(function (k) { return k + " persone"; }), [{ label: "Prenotazioni", data: gk.map(function (k) { return pr.gruppi[k] || 0; }) }]);
      const ore = Array.from(new Set(pr.mappa.map(function (x) { return x.ora; }))).sort();
      const max = Math.max.apply(null, [1].concat(pr.mappa.map(function (x) { return x.persone; })));
      $("#mappa").innerHTML = ore.length ? '<table class="mappa"><tr><th></th>' + ore.map(function (o) { return "<th>" + esc(o) + "</th>"; }).join("") + "</tr>" +
        [1, 2, 3, 4, 5, 6, 7].map(function (d) {
          return "<tr><th>" + GIORNI_ISO[d] + "</th>" + ore.map(function (o) {
            const x = pr.mappa.find(function (m) { return m.d === d && m.ora === o; }), v = x ? x.persone : 0;
            return '<td style="background:rgba(230,178,74,' + (v ? (0.12 + 0.78 * v / max).toFixed(2) : 0.04) + ')">' + (v || "") + "</td>";
          }).join("") + "</tr>";
        }).join("") + "</table>" : '<p class="vuoto-dati">Ancora nessuna prenotazione nel periodo.</p>';
    },

    /* ---------- clienti ---------- */
    clienti: function (corpo) {
      const c = STATO.cli, p = STATO.cliCmp;
      corpo.innerHTML = kpiRiga([
        ["Clienti venuti", num(c.attivi), delta(c.attivi, p && p.attivi), "almeno una sera nel periodo"],
        ["Nuovi", num(c.nuovi), delta(c.nuovi, p && p.nuovi), "prima volta in assoluto"],
        ["Tornati", num(c.tornati), delta(c.tornati, p && p.tornati), "erano già venuti prima"],
        ["% che tornano", pct(c.tornati, c.attivi), p ? delta(c.attivi ? c.tornati / c.attivi : 0, p.attivi ? p.tornati / p.attivi : 0) : ""],
        ["Ogni quanto tornano", c.intervalloMedio ? num(c.intervalloMedio) + " gg" : "—", "", "in media, chi è venuto più volte"],
        ["Clienti conosciuti", num(c.conosciuti), "", "con almeno una presenza"],
      ]) +
      '<div class="griglia">' + card("c5", "Quante volte sono venuti (clienti del periodo)", canvas("d-freq")) +
        card("c7", "🔎 Cerca un cliente", '<input id="cerca" placeholder="Nome o telefono…" style="width:100%"><div id="risultati" style="margin-top:10px"></div>' +
          '<p class="dim" style="margin-top:8px">Una "presenza" è una sera in cui il cliente è venuto: prenotazione non annullata o premio del Club usato. Il telefono tiene insieme tutto.</p>') + "</div>" +
      '<div class="griglia">' + card("c7", "I clienti più affezionati", '<div id="tab-top"></div>') +
        card("c5", "Da riconquistare · venuti almeno 2 volte, non da più di 45 giorni", '<div id="tab-persi"></div>') + "</div>";
      const fk = ["1", "2", "3", "4-5", "6+"];
      barre("d-freq", $("#d-freq"), fk.map(function (k) { return k === "1" ? "1 volta" : k + " volte"; }), [{ label: "Clienti", data: fk.map(function (k) { return c.frequenza[k] || 0; }) }]);
      $("#tab-top").innerHTML = tabella([["Cliente"], ["Presenze", 1], ["Nel periodo", 1], ["Ultima"], ["Ogni", 1], ["Club"]],
        c.top.map(function (x) {
          return { attr: ' class="cliccabile" data-tel="' + esc(x.telefono) + '"', c: [esc(x.nome), x.visite, x.nelPeriodo, dataBreve(x.ultima),
            x.intervallo ? num(x.intervallo) + " gg" : "—", x.club ? '<span class="pill ok">sì</span>' : '<span class="pill">no</span>'] };
        }), { scorri: true, vuoto: "Ancora nessun cliente con presenze." });
      $("#tab-persi").innerHTML = tabella([["Cliente"], ["Presenze", 1], ["Ultima volta"], ["Giorni", 1]],
        c.daRiconquistare.map(function (x) {
          return { attr: ' class="cliccabile" data-tel="' + esc(x.telefono) + '"', c: [esc(x.nome), x.visite, dataBreve(x.ultima), x.giorni] };
        }), { scorri: true, vuoto: "Nessuno da riconquistare: bene!" });
      $$("[data-tel]", corpo).forEach(function (tr) { tr.addEventListener("click", function () { schedaCliente(tr.dataset.tel); }); });
      let t = null;
      $("#cerca").addEventListener("input", function () {
        const q = this.value;
        clearTimeout(t);
        t = setTimeout(async function () {
          if (q.trim().length < 2) { $("#risultati").innerHTML = ""; return; }
          try {
            const r = await D.cerca(PIN, q);
            $("#risultati").innerHTML = r.length ? r.map(function (x) {
              return '<button class="btn vuoto piccolo" style="margin:0 6px 6px 0" data-tel="' + esc(x.telefono) + '">' + esc(x.nome) + " · " + esc(x.telefono) + "</button>";
            }).join("") : '<p class="dim">Nessuno trovato.</p>';
            $$("#risultati [data-tel]").forEach(function (b) { b.addEventListener("click", function () { schedaCliente(b.dataset.tel); }); });
          } catch (e) { problema(e); }
        }, 250);
      });
    },

    /* ---------- canali ---------- */
    canali: function (corpo) {
      const c = STATO.cur, pr = c.prenotazioni.canali, cl = c.club.canali, si = c.sito.canali;
      const chiavi = Array.from(new Set(Object.keys(pr).concat(Object.keys(cl), Object.keys(si))));
      const righe = chiavi.map(function (k) { return { k: k, v: si[k] || 0, p: pr[k] ? pr[k].n : 0, pe: pr[k] ? pr[k].persone : 0, c: cl[k] || 0 }; })
        .sort(function (a, b) { return (b.p + b.c) - (a.p + a.c) || b.v - a.v; });
      const base = "https://vicodelcarmine.it/?ref=";
      const link = [["Bio di Instagram", "instagram"], ["Pagina Facebook", "facebook"], ["Profilo Google (sito web)", "google-maps"], ["TikTok", "tiktok"],
        ["QR su volantini e sacchetti", "volantino"], ["Stato o messaggi WhatsApp", "whatsapp"]];
      corpo.innerHTML =
        '<div class="griglia">' + card("c7", "Ogni canale: visite, prenotazioni, iscritti al Club",
          tabella([["Canale"], ["Visite al sito", 1], ["Prenotazioni", 1], ["Persone", 1], ["Nuovi nel Club", 1], ["Visite → prenotazione", 1]],
            righe.map(function (r) { return { c: [esc(nomeCanale(r.k)), r.v || "—", r.p || "—", r.pe || "—", r.c || "—", r.v ? pct(r.p, r.v) : "—"] }; }))) +
        card("c5", "Prenotazioni per canale", canvas("d-canp", "alto")) + "</div>" +
        '<div class="griglia">' + card("c6", "Nuovi nel Club per canale", canvas("d-canc")) +
        card("c6", "🔗 Link da usare, così il canale si riconosce",
          '<p class="dim">Chi arriva da questi link viene contato col suo canale. Senza, il sito riconosce da solo solo Google, Instagram e Facebook quando il telefono lo dice.</p>' +
          tabella([["Dove"], ["Link"], [""]], link.map(function (l) {
            return { c: [l[0], '<code>' + esc(base + l[1]) + "</code>", '<button class="btn vuoto piccolo" data-copia="' + esc(base + l[1]) + '">Copia</button>'] };
          }))) + "</div>";
      const kp = Object.keys(pr).sort(function (a, b) { return pr[b].n - pr[a].n; });
      ciambella("d-canp", $("#d-canp"), kp.map(nomeCanale), kp.map(function (k) { return pr[k].n; }));
      const kc = Object.keys(cl).sort(function (a, b) { return cl[b] - cl[a]; });
      barre("d-canc", $("#d-canc"), kc.map(nomeCanale), [{ label: "Nuovi iscritti", data: kc.map(function (k) { return cl[k]; }) }], { orizzontale: true });
      $$("[data-copia]", corpo).forEach(function (b) {
        b.addEventListener("click", function () { navigator.clipboard.writeText(b.dataset.copia).then(function () { b.textContent = "Copiato ✓"; }); });
      });
    },

    /* ---------- campagne e periodi ---------- */
    campagne: function (corpo) {
      const periodi = STATO.imp.periodi || [];
      corpo.innerHTML =
        card("c12", "Confronta un periodo con quello prima",
          '<div class="modulo"><label>Periodo<select id="cfr-periodo">' + periodi.map(function (p) {
            return '<option value="' + p.id + '">' + esc(p.nome) + " · " + dataBreve(p.dal) + (p.al ? " → " + dataBreve(p.al) : " → in corso") + "</option>"; }).join("") +
          '</select></label><label>Confronta con<select id="cfr-modo"><option value="sett">le stesse settimane prima</option><option value="prec">i giorni subito prima</option></select></label></div>' +
          '<div id="cfr-esito" style="margin-top:14px"></div>') +
        '<div class="griglia" style="margin-top:14px">' + card("c7", "Periodi salvati", '<div id="tab-periodi"></div>') +
        card("c5", "➕ Nuovo periodo",
          '<form id="f-periodo" class="modulo"><input type="hidden" name="id"><label>Nome<input name="nome" required placeholder="Es. Campagna Instagram autunno"></label>' +
          '<label>Tipo<select name="tipo"><option value="campagna">campagna</option><option value="evento">evento</option><option value="chiusura">chiusura</option><option value="altro">altro</option></select></label>' +
          '<label>Dal<input type="date" name="dal" required></label><label>Al (vuoto = in corso)<input type="date" name="al"></label>' +
          '<label style="flex:1 1 100%">Note<input name="note" placeholder="Facoltative"></label><button class="btn oro" type="submit">Salva</button> <button class="btn vuoto" type="reset">Svuota</button></form>') +
        "</div>" + (STATO.campagne || []).map(function (k, i) { return card("c12", "🎁 " + esc(k.nome), '<div id="camp-' + i + '"></div>'); }).join("");
      disegnaPeriodi();
      (STATO.campagne || []).forEach(function (k, i) { $("#camp-" + i).innerHTML = imbutoCampagna(k); });
      $("#cfr-periodo").addEventListener("change", confrontaPeriodo);
      $("#cfr-modo").addEventListener("change", confrontaPeriodo);
      if (periodi.length) confrontaPeriodo();
      else $("#cfr-esito").innerHTML = '<p class="vuoto-dati">Salva un periodo qui sotto per confrontarlo.</p>';
      $("#f-periodo").addEventListener("submit", async function (e) {
        e.preventDefault();
        const f = e.target, v = { id: f.id.value ? Number(f.id.value) : null, nome: f.nome.value, tipo: f.tipo.value, dal: f.dal.value, al: f.al.value || null, note: f.note.value };
        try { STATO.imp.periodi = await D.periodoSalva(PIN, v); f.reset(); f.id.value = ""; riempiPeriodiSalvati(); apriDettaglio("campagne", true); }
        catch (er) { problema(er); }
      });
      $("#f-periodo").addEventListener("reset", function () { this.id.value = ""; });
    },

    /* ---------- agenti ---------- */
    agenti: function (corpo) {
      const c = STATO.cur, p = STATO.cmp;
      const tot = c.agenti.reduce(function (s, a) { return { g: s.g + a.giocate, t: s.t + a.tavoli, p: s.p + a.persone, e: s.e + Number(a.euro), pg: s.pg + Number(a.pagato) }; }, { g: 0, t: 0, p: 0, e: 0, pg: 0 });
      corpo.innerHTML = kpiRiga([
        ["Giocate", num(tot.g), delta(g(c, "giocate"), g(p, "giocate")), "QR inquadrati dai passanti"],
        ["Tavoli", num(tot.t), delta(g(c, "tavoli"), g(p, "tavoli")), pct(tot.t, tot.g) + " delle giocate"],
        ["Persone portate", num(tot.p), delta(g(c, "prPersone"), g(p, "prPersone"))],
        ["Provvigioni maturate", euro(tot.e), delta(g(c, "prEuro"), g(p, "prEuro")), euro(tot.p ? tot.e / tot.p : null) + " a persona"],
        ["Pagato nel periodo", euro(tot.pg)],
      ]) +
      '<div class="griglia">' + card("c7", "Persone portate sera per sera", canvas("d-ag", "alto")) +
      card("c5", "Agente per agente", tabella([["Agente"], ["Giocate", 1], ["Tavoli", 1], ["Conv.", 1], ["Persone", 1], ["Provvigioni", 1], ["Pagato", 1]],
        c.agenti.map(function (a) {
          return { c: [esc(a.nome) + (a.attivo ? "" : ' <span class="pill">in pausa</span>'), a.giocate, a.tavoli, pct(a.tavoli, a.giocate), a.persone, euro(a.euro), euro(a.pagato)] };
        }), { vuoto: "Nessun agente." })) + "</div>";
      serieConfronto("d-ag", $("#d-ag"), "prPersone");
    },

    /* ---------- club ---------- */
    club: function (corpo) {
      const c = STATO.cur, p = STATO.cmp, k = c.club;
      const tipi = Object.keys(k.premi);
      corpo.innerHTML = kpiRiga([
        ["Nuovi iscritti", num(k.nuovi), delta(k.nuovi, p && p.club.nuovi)],
        ["Iscritti in tutto", num(k.totale), "", "alla fine del periodo"],
        ["Accettano le offerte", pct(k.promo, k.nuovi), "", "tra i nuovi"],
        ["Premi usati", num(tipi.reduce(function (s, t) { return s + k.premi[t].usati; }, 0))],
      ]) +
      '<div class="griglia">' + card("c8", "Nuovi iscritti sera per sera", canvas("d-cl", "alto")) + card("c4", "Da dove arrivano", canvas("d-clc", "alto")) + "</div>" +
      card("c12", "Premi del Club nel periodo", tabella([["Premio"], ["Emessi", 1], ["Usati", 1], ["% usati", 1]],
        tipi.map(function (t) { return { c: [esc(NOMI_PREMIO[t] || t), k.premi[t].emessi, k.premi[t].usati, pct(k.premi[t].usati, k.premi[t].emessi)] }; })));
      serieConfronto("d-cl", $("#d-cl"), "club");
      const ck = Object.keys(k.canali).sort(function (a, b) { return k.canali[b] - k.canali[a]; });
      ciambella("d-clc", $("#d-clc"), ck.map(nomeCanale), ck.map(function (x) { return k.canali[x]; }));
    },

    /* ---------- asporto ---------- */
    asporto: function (corpo) {
      const a = STATO.cur.asporto, p = STATO.cmp && STATO.cmp.asporto;
      corpo.innerHTML = kpiRiga([
        ["Ordini", num(a.ordini), delta(a.ordini, p && p.ordini)],
        ["Incasso", euro(a.euro), delta(a.euro, p && p.euro)],
        ["A ordine", euro(a.ordini ? a.euro / a.ordini : null), p && p.ordini ? delta(a.euro / (a.ordini || 1), p.euro / p.ordini) : ""],
        ["Piatti", num(a.pezzi)],
        ["Clienti diversi", num(a.clienti)],
        ["Annullati", num(a.annullati), delta(a.annullati, p && p.annullati, true)],
        ["Tempo di preparazione", a.minuti == null ? "—" : a.minuti + " min", "", "dall'ordine a pronto"],
      ]) +
      '<div class="griglia">' + card("c8", "Incasso asporto sera per sera", canvas("d-asp", "alto")) + card("c4", "Ora di ritiro", canvas("d-rit", "alto")) + "</div>" +
      card("c12", "Piatti più ordinati", tabellaPiatti(a.piatti));
      serieConfronto("d-asp", $("#d-asp"), "aspEuro", { euro: true });
      barre("d-rit", $("#d-rit"), a.ritiri.map(function (x) { return x.ora; }), [{ label: "Ordini", data: a.ritiri.map(function (x) { return x.n; }) }]);
    },

    /* ---------- ordini al tavolo ---------- */
    ordini: function (corpo) {
      const o = STATO.cur.ordini, p = STATO.cmp && STATO.cmp.ordini;
      corpo.innerHTML = kpiRiga([
        ["Ordini dal QR", num(o.ordini), delta(o.ordini, p && p.ordini)],
        ["Valore", euro(o.euro), delta(o.euro, p && p.euro)],
        ["Tavoli", num(o.tavoli)],
        ["Coperti dichiarati", num(o.coperti)],
        ["Presa visione", o.minuti == null ? "—" : o.minuti + " min", "", "dall'ordine al banco che lo vede"],
      ]) +
      card("c12", "Valore degli ordini sera per sera", canvas("d-ord", "alto")) + '<div style="height:14px"></div>' +
      card("c12", "Piatti più ordinati al tavolo", tabellaPiatti(o.piatti));
      serieConfronto("d-ord", $("#d-ord"), "ordiniEuro", { euro: true });
    },

    /* ---------- whatsapp ---------- */
    whatsapp: function (corpo) {
      const w = STATO.cur.whatsapp, cf = w.conferme;
      corpo.innerHTML = kpiRiga([
        ["Conferme inviate", num(cf.inviate), "", "prenotazioni dal sito"],
        ["Conferme lette", pct(cf.lette, cf.inviate)],
        ["Regali attivati", num(cf.attivati), "", pct(cf.attivati, cf.inviate) + " hanno risposto"],
        ["Non partite", num(cf.errori)],
        ["Messaggi ricevuti", num(w.ricevuti)],
        ["Hanno scritto STOP", num(w.stop)],
      ]) +
      '<div class="griglia">' + card("c7", "Inviati e ricevuti sera per sera", canvas("d-wa", "alto")) +
      card("c5", "Messaggi automatici", tabella([["Messaggio"], ["Inviati", 1], ["Letti", 1], ["Saltati", 1], ["Errori", 1]],
        Object.keys(w.messaggi).map(function (t) { const m = w.messaggi[t]; return { c: [esc(NOMI_WA[t] || t), m.inviati, pct(m.letti, m.inviati), m.saltati, m.errori] }; }),
        { vuoto: "Nessun messaggio automatico nel periodo." })) + "</div>";
      const cur = STATO.cur.giorni;
      disegna("d-wa", $("#d-wa"), { type: "bar", data: { labels: cur.map(function (x) { return dataBreve(x.g); }), datasets: [
        { label: "Inviati", data: cur.map(function (x) { return x.waInviati; }), backgroundColor: ORO_T, borderRadius: 4 },
        { label: "Ricevuti", data: cur.map(function (x) { return x.waRicevuti; }), backgroundColor: "rgba(134,182,74,.6)", borderRadius: 4 }] },
        options: { responsive: true, maintainAspectRatio: false, scales: { x: { grid: { display: false } }, y: { beginAtZero: true } } } });
    },

    /* ---------- voti ---------- */
    voti: function (corpo) {
      const v = STATO.cur.prenotazioni.voti, pv = STATO.cmp && STATO.cmp.prenotazioni.voti;
      const d = v.distribuzione || {};
      corpo.innerHTML = kpiRiga([
        ["Voto medio", v.media == null ? "—" : num(v.media) + " ★", pv && pv.media != null && v.media != null ? delta(v.media, pv.media) : ""],
        ["Voti ricevuti", num(v.n), delta(v.n, pv && pv.n)],
        ["4 o 5 stelle", pct((d["4"] || 0) + (d["5"] || 0), v.n), "", "a loro arriva il link per la recensione Google"],
        ["1–3 stelle", num((d["1"] || 0) + (d["2"] || 0) + (d["3"] || 0)), "", "a loro chiediamo cosa non è andato"],
      ]) + card("c12", "Come votano (il giorno dopo, su WhatsApp)", canvas("d-voti", "alto"));
      barre("d-voti", $("#d-voti"), ["1 ★", "2 ★", "3 ★", "4 ★", "5 ★"], [{ label: "Voti", data: ["1", "2", "3", "4", "5"].map(function (k) { return d[k] || 0; }),
        colore: ["#c8102e", "#d97a4a", "#e8d28a", "#a8c96f", "#86b64a"] }]);
    },

    /* ---------- fortuna ---------- */
    fortuna: function (corpo) {
      const f = STATO.cur.fortuna, p = STATO.cmp && STATO.cmp.fortuna;
      const k = Object.keys(f.premi);
      corpo.innerHTML = kpiRiga([["Giocate", num(f.giocate), delta(f.giocate, p && p.giocate)], ["Premi riscattati", num(f.riscattate), delta(f.riscattate, p && p.riscattate)],
        ["Riscattati", pct(f.riscattate, f.giocate)]]) +
        '<div class="griglia">' + card("c8", "Giocate sera per sera", canvas("d-for", "alto")) + card("c4", "Premi usciti", canvas("d-forp", "alto")) + "</div>";
      serieConfronto("d-for", $("#d-for"), "fortuna");
      ciambella("d-forp", $("#d-forp"), k, k.map(function (x) { return f.premi[x]; }));
    },

    /* ---------- sito ---------- */
    sito: function (corpo) {
      const s = STATO.cur.sito, p = STATO.cmp && STATO.cmp.sito;
      const kc = Object.keys(s.canali).sort(function (a, b) { return s.canali[b] - s.canali[a]; });
      const kp = Object.keys(s.pagine).sort(function (a, b) { return s.pagine[b] - s.pagine[a]; });
      const NOMI_PAGINA = { home: "Home (italiano)", "home-en": "Home (inglese)", regalo: "Pagina del regalo" };
      corpo.innerHTML = kpiRiga([["Visite", num(s.visite), delta(s.visite, p && p.visite), "una per pagina per visita, senza cookie"],
        ["Al giorno", num(STATO.cur.giorni.length ? s.visite / STATO.cur.giorni.length : null)]]) +
        '<div class="griglia">' + card("c8", "Visite giorno per giorno", canvas("d-vis", "alto")) + card("c4", "Da dove arrivano", canvas("d-visc", "alto")) + "</div>" +
        card("c12", "Pagine", tabella([["Pagina"], ["Visite", 1]], kp.map(function (k) { return { c: [esc(NOMI_PAGINA[k] || k), s.pagine[k]] }; })));
      serieConfronto("d-vis", $("#d-vis"), "visite");
      ciambella("d-visc", $("#d-visc"), kc.map(nomeCanale), kc.map(function (k) { return s.canali[k]; }));
    },

    /* ---------- salute ---------- */
    salute: function (corpo) {
      const s = STATO.salute, erp = s.erp || {};
      const riga = function (ok, testo, dett) { return { c: [ok ? '<span class="pill ok">ok</span>' : '<span class="pill no">da guardare</span>', testo, dett || ""] }; };
      corpo.innerHTML = card("c12", "Controlli (aggiornati " + quando(s.adesso) + ")", tabella([["Stato"], ["Cosa"], ["Dettaglio"]], [
        riga(!s.waCoda, "WhatsApp in coda", s.waCoda ? s.waCoda + " fermi da più di 30 minuti" : "nessuno fermo"),
        riga(!s.waErrori24h, "WhatsApp non partiti (24 ore)", s.waErrori24h ? s.waErrori24h + (s.waUltimoErrore ? " · ultimo: " + esc(s.waUltimoErrore) : "") : "nessuno"),
        riga(true, "Ultimo WhatsApp partito", quando(s.waUltimoInvio) + (s.waAcceso ? " · conferme accese" : " · conferme spente")),
        riga(!s.avvisiFermi, "Avvisi delle prenotazioni al titolare", s.avvisiFermi ? s.avvisiFermi + " non partiti" : "tutti partiti"),
        riga(!s.clubCoda, "Messaggi del Club", s.clubCoda ? s.clubCoda + " fermi in coda" : "nessuno fermo"),
        riga(!!erp.collegato, "Collegamento cassa (incassi)", erp.collegato ? "ultimo invio " + quando(erp.ultimoInvio) + (erp.ultimoEsito ? " · " + esc(erp.ultimoEsito) : "") : "non collegato"),
        riga(true, "Ultima sera con l'incasso", dataLunga(s.ultimaSeraCassa)),
      ])) + '<div style="height:14px"></div>' +
      card("c12", "Orologi automatici", tabella([["Lavoro"], ["Ultimo giro"], ["Esito"]], (s.orologio || []).map(function (o) {
        return { c: [esc(o.lavoro), quando(o.ultimo), o.esito === "succeeded" ? '<span class="pill ok">riuscito</span>' : '<span class="pill no">' + esc(o.esito || "—") + "</span>"] };
      })));
    },
  };

  function tabellaPiatti(lista) {
    return tabella([["Piatto"], ["Quantità", 1], ["Valore", 1]], (lista || []).map(function (x) { return { c: [esc(x.nome), x.qta, euro(x.euro)] }; }),
      { vuoto: "Nessun piatto ordinato nel periodo." });
  }

  // gli articoli divisi per categoria: chiusa la categoria mostra i suoi totali, aperta i suoi articoli.
  // Le categorie vanno dalla più alla meno incassata; "Da sistemare" (articoli nuovi) sta in cima.
  function tabellaArticoli(a, incasso) {
    const per = {}, elenco = a.categorie || [];
    a.articoli.forEach(function (x) { const k = x.categoria || "Da sistemare"; (per[k] = per[k] || []).push(x); });
    const somma = function (lista, f) { return lista.reduce(function (s, x) { return s + (Number(x[f]) || 0); }, 0); };
    const chiavi = Object.keys(per).sort(function (x, y) {
      if (x === "Da sistemare" || y === "Da sistemare") return x === "Da sistemare" ? -1 : 1;
      return somma(per[y], "euro") - somma(per[x], "euro");
    });
    const scegli = function (x) {
      return '<select class="sposta" data-articolo="' + esc(x.nome) + '" aria-label="Categoria di ' + esc(x.nome) + '">' +
        elenco.map(function (k) { return "<option" + (k === x.categoria ? " selected" : "") + ">" + esc(k) + "</option>"; }).join("") +
        (elenco.indexOf(x.categoria) < 0 ? "<option selected disabled>" + esc(x.categoria || "Da sistemare") + "</option>" : "") + "</select>";
    };
    return tabellaGruppi([["Articolo"], ["Quantità", 1], ["Incasso", 1], ["Sconti", 1], ["% incasso", 1], ["Sere", 1]],
      chiavi.map(function (k) {
        const lista = per[k], sc = somma(lista, "sconti");
        return { chiave: k,
          testa: [esc(k) + (k === "Da sistemare" ? ' <span class="pill oro">nuovi</span>' : "") + ' <span class="dim">· ' + lista.length +
              (lista.length === 1 ? " articolo" : " articoli") + "</span>",
            num(somma(lista, "qta")), euro(somma(lista, "euro")), sc ? euro(sc) : "—", pct(somma(lista, "euro"), incasso), ""],
          righe: lista.map(function (x) {
            return { c: [esc(x.nome) + (modificaCategorie ? scegli(x) : ""), num(x.qta), euro(x.euro), x.sconti ? euro(x.sconti) : "—", pct(x.euro, incasso), x.sere] };
          }) };
      }), modificaCategorie ? new Set(chiavi) : APERTE_CAT, { scorri: true });
  }

  // sconti e articoli venduti in sala, dal dettaglio delle chiusure di cassa
  async function disegnaArticoliCassa() {
    const box = $("#cassa-articoli");
    if (!box) return;
    let a;
    try { a = await D.cassaArticoli(PIN, STATO.dal, STATO.al); } catch (e) { box.innerHTML = ""; return; }   // non ancora installata
    if (!$("#cassa-articoli")) return;
    if (!a.conDettaglio) { box.innerHTML = '<p class="dim" style="margin:0 0 14px">Gli articoli venduti compariranno qui quando arrivano le chiusure dalla cassa.</p>'; return; }
    const c = STATO.cur.cassa, lordo = c.incasso + a.sconti;
    box.innerHTML = kpiRiga([
      ["Sconti fatti", euro(a.sconti), "", pct(a.sconti, lordo) + " del lordo"],
      ["Coperto", euro(a.coperto), "", pct(a.coperto, c.incasso) + " dell'incasso"],
      ["Abbuoni", euro(a.abbuono), "", "arrotondamenti alla cassa"],
      ["Sere con il dettaglio", num(a.conDettaglio) + " / " + num(a.sere)],
    ]) +
    '<div class="griglia">' + card("c5", "I 15 articoli che incassano di più", canvas("d-art", "alto")) +
      card("c7", "Tutti gli articoli venduti in sala",
        '<div class="riga-strumenti"><span class="dim">Tocca una categoria per vedere i suoi articoli.</span>' +
        '<button class="btn vuoto piccolo" id="b-categorie">' + (modificaCategorie ? "✓ Fatto" : "✏️ Cambia le categorie") + "</button></div>" +
        '<div id="tab-articoli">' + tabellaArticoli(a, c.incasso) + "</div>") + "</div>";
    tendine($("#tab-articoli"), APERTE_CAT);
    $("#b-categorie").addEventListener("click", function () { modificaCategorie = !modificaCategorie; disegnaArticoliCassa(); });
    $("#tab-articoli").addEventListener("change", async function (e) {
      const sel = e.target.closest("select[data-articolo]");
      if (!sel) return;
      sel.disabled = true;
      try { await D.cassaCategoria(PIN, sel.dataset.articolo, sel.value); APERTE_CAT.add(sel.value); disegnaArticoliCassa(); }
      catch (err) { sel.disabled = false; problema(err); }
    });
    const primi = a.articoli.slice(0, 15);
    barre("d-art", $("#d-art"), primi.map(function (x) { return x.nome; }), [{ label: "Incasso €", data: primi.map(function (x) { return x.euro; }) }], { orizzontale: true });
  }

  // la tabella degli incassi sera per sera, a tendine mese per mese (chiuso: il totale del mese), con la modifica a mano
  function disegnaTabCassa() {
    const mesi = {};
    STATO.cur.giorni.forEach(function (x) { const k = x.g.slice(0, 7); (mesi[k] = mesi[k] || []).push(x); });
    const gruppi = Object.keys(mesi).sort().reverse().map(function (k) {
      const sere = mesi[k].filter(function (x) { return x.incasso != null; });
      const somma = function (lista, f) {
        const v = lista.filter(function (x) { return x[f] != null; });
        return v.length ? v.reduce(function (s, x) { return s + x[f]; }, 0) : null;
      };
      const conCoperti = sere.filter(function (x) { return x.coperti; }), coperti = somma(conCoperti, "coperti");
      return { chiave: k,
        testa: [nomeMese(k) + ' <span class="dim">· ' + (sere.length ? sere.length + (sere.length === 1 ? " sera" : " sere") : "nessuna sera") + "</span>",
          euro(somma(sere, "incasso")), num(somma(sere, "coperti")), num(somma(sere, "scontrini")),
          euro(coperti ? somma(conCoperti, "incasso") / coperti : null), "", ""],
        righe: mesi[k].slice().reverse().map(function (x) {
          return { attr: ' data-sera="' + x.g + '"', c: [dataLunga(x.g), euro(x.incasso), num(x.coperti), num(x.scontrini),
            euro(x.incasso != null && x.coperti ? x.incasso / x.coperti : null),
            x.incasso == null ? "" : x.cassaFonte === "manuale" ? '<span class="pill oro">a mano</span>' : '<span class="pill ok">automatico</span>',
            x.g <= D.oggiRoma() ? '<button class="btn vuoto piccolo" data-modifica="' + x.g + '">' + (x.incasso == null ? "＋ scrivi" : "✎") + "</button>" : ""] };
        }) };
    });
    $("#tab-cassa").innerHTML = tabellaGruppi([["Sera"], ["Incasso", 1], ["Coperti", 1], ["Scontrini", 1], ["€ a coperto", 1], ["Da"], [""]],
      gruppi, APERTI_MESI, { scorri: true });
    tendine($("#tab-cassa"), APERTI_MESI);
    $$("[data-modifica]").forEach(function (b) {
      b.addEventListener("click", function () {
        const sera = b.dataset.modifica, x = STATO.cur.giorni.find(function (y) { return y.g === sera; });
        const tr = b.closest("tr");
        tr.innerHTML = "<td>" + dataLunga(sera) + '</td><td colspan="6"><form class="modulo" data-salva="' + sera + '">' +
          '<label>Incasso €<input name="incasso" type="number" step="0.01" min="0" value="' + (x.incasso == null ? "" : x.incasso) + '" style="width:120px"></label>' +
          '<label>Coperti<input name="coperti" type="number" min="0" value="' + (x.coperti == null ? "" : x.coperti) + '" style="width:90px"></label>' +
          '<label>Scontrini<input name="scontrini" type="number" min="0" value="' + (x.scontrini == null ? "" : x.scontrini) + '" style="width:90px"></label>' +
          '<button class="btn oro piccolo" type="submit">Salva</button> <button class="btn vuoto piccolo" type="button" data-annulla>Annulla</button>' +
          (x.incasso != null ? ' <button class="btn vuoto piccolo" type="button" data-togli>Togli la sera</button>' : "") + "</form></td>";
        const f = $("form", tr);
        $("[data-annulla]", f).addEventListener("click", disegnaTabCassa);
        const salva = async function (togli) {
          const v = function (n) { const s = f.elements[n].value.trim(); return s === "" ? null : Number(s); };
          if (!togli && v("incasso") == null) { alert("Scrivi l'incasso (oppure usa Togli la sera)."); return; }
          try { await D.cassaSalva(PIN, sera, togli ? null : v("incasso"), togli ? null : v("coperti"), togli ? null : v("scontrini")); carica(); }
          catch (e) { problema(e); }
        };
        f.addEventListener("submit", function (e) { e.preventDefault(); salva(false); });
        const tb = $("[data-togli]", f);
        if (tb) tb.addEventListener("click", function () { if (confirm("Tolgo l'incasso di " + dataLunga(sera) + "?")) salva(true); });
      });
    });
  }

  // i periodi salvati, con modifica ed eliminazione
  function disegnaPeriodi() {
    const periodi = STATO.imp.periodi || [];
    $("#tab-periodi").innerHTML = tabella([["Nome"], ["Tipo"], ["Dal"], ["Al"], ["Note"], [""]], periodi.map(function (p) {
      return { c: [esc(p.nome), esc(p.tipo), dataBreve(p.dal), p.al ? dataBreve(p.al) : '<span class="pill oro">in corso</span>', esc(p.note || ""),
        '<button class="btn vuoto piccolo" data-mod="' + p.id + '">✎</button> <button class="btn vuoto piccolo" data-del="' + p.id + '">🗑</button>'] };
    }), { vuoto: "Nessun periodo salvato." });
    $$("[data-mod]").forEach(function (b) {
      b.addEventListener("click", function () {
        const p = periodi.find(function (x) { return String(x.id) === b.dataset.mod; }), f = $("#f-periodo");
        f.id.value = p.id; f.nome.value = p.nome; f.tipo.value = p.tipo; f.dal.value = p.dal; f.al.value = p.al || ""; f.note.value = p.note || "";
        f.nome.focus();
      });
    });
    $$("[data-del]").forEach(function (b) {
      b.addEventListener("click", async function () {
        const p = periodi.find(function (x) { return String(x.id) === b.dataset.del; });
        if (!confirm("Elimino il periodo «" + p.nome + "»? I dati veri non cambiano: si toglie solo il segnaposto.")) return;
        try { STATO.imp.periodi = await D.periodoElimina(PIN, p.id); riempiPeriodiSalvati(); apriDettaglio("campagne", true); } catch (e) { problema(e); }
      });
    });
  }

  // il confronto di un periodo con quello prima: tutte le aree insieme
  async function confrontaPeriodo() {
    const id = $("#cfr-periodo").value, modo = $("#cfr-modo").value;
    const p = (STATO.imp.periodi || []).find(function (x) { return String(x.id) === id; });
    if (!p) return;
    // la sera di oggi non è finita (l'incasso arriva stanotte): si confronta fino a ieri
    const oggi = D.oggiRoma(), dal = p.dal;
    let al = p.al && p.al < oggi ? p.al : piu(oggi, -1), nota = "";
    if (dal > oggi) { $("#cfr-esito").innerHTML = '<p class="vuoto-dati">Questo periodo non è ancora cominciato.</p>'; return; }
    if (al < dal) { al = oggi; nota = "È cominciato oggi: la serata non è finita, il confronto diventa utile fra qualche giorno."; }
    else if (!p.al || p.al >= oggi) nota = "Oggi è escluso: la serata non è ancora finita.";
    const c = confrontoDi(dal, al, modo);
    $("#cfr-esito").innerHTML = '<p class="dim">Carico…</p>';
    try {
      const v = await Promise.all([D.riepilogo(PIN, dal, al), D.riepilogo(PIN, c[0], c[1]), D.clienti(PIN, dal, al), D.clienti(PIN, c[0], c[1])]);
      const a = v[0], b = v[1], ca = v[2], cb = v[3], n = giorniTra(dal, al) + 1;
      const tot = function (r, k) { return r.giorni.reduce(function (s, x) { return s + (Number(x[k]) || 0); }, 0); };
      const voci = [
        ["Prenotazioni", a.prenotazioni.totale, b.prenotazioni.totale], ["Persone prenotate", a.prenotazioni.persone, b.prenotazioni.persone],
        ["Incasso", a.cassa.incasso, b.cassa.incasso, true], ["Coperti (cassa)", a.cassa.coperti, b.cassa.coperti],
        ["Clienti venuti", ca.attivi, cb.attivi], ["Clienti nuovi", ca.nuovi, cb.nuovi], ["Clienti tornati", ca.tornati, cb.tornati],
        ["Nuovi nel Club", a.club.nuovi, b.club.nuovi], ["Asporto", a.asporto.euro, b.asporto.euro, true],
        ["Persone portate dagli agenti", tot(a, "prPersone"), tot(b, "prPersone")], ["Visite al sito", a.sito.visite, b.sito.visite],
        ["Voto medio", a.prenotazioni.voti.media, b.prenotazioni.voti.media],
      ];
      const salva = STATO.cmp; STATO.cmp = true;            // delta() mostra la differenza solo se c'è un confronto
      $("#cfr-esito").innerHTML = '<p class="dim">' + esc(p.nome) + ": <b>" + dataLunga(dal) + " → " + dataLunga(al) + "</b> (" + n + " giorni) contro <b>" +
        dataLunga(c[0]) + " → " + dataLunga(c[1]) + "</b>" + (nota ? " · " + nota : "") + "</p>" +
        '<div class="griglia" style="margin-top:10px"><div class="c6"><table class="cfr"><tr><th></th><th class="n">Durante</th><th class="n">Prima</th><th class="n">Differenza</th></tr>' +
        voci.map(function (x) {
          const f = x[3] ? euro : num;
          return "<tr><td>" + x[0] + '</td><td class="n"><b>' + f(x[1]) + '</b></td><td class="n">' + f(x[2]) + '</td><td class="n">' + delta(x[1], x[2]) + "</td></tr>";
        }).join("") + '</table></div><div class="c6"><div class="grafico alto"><canvas id="d-cfr"></canvas></div></div></div>';
      STATO.cmp = salva;
      disegna("d-cfr", $("#d-cfr"), { type: "line", data: { labels: a.giorni.map(function (x, i) { return "giorno " + (i + 1); }), datasets: [
        { label: "Durante (persone prenotate)", data: a.giorni.map(function (x) { return x.persone; }), borderColor: ORO, backgroundColor: ORO_T, tension: .3, pointRadius: 2 },
        { label: "Prima", data: b.giorni.map(function (x) { return x.persone; }), borderColor: GRIGIO, borderDash: [5, 4], tension: .3, pointRadius: 0 }] },
        options: { responsive: true, maintainAspectRatio: false, interaction: { mode: "index", intersect: false }, scales: { y: { beginAtZero: true } } } });
    } catch (e) { $("#cfr-esito").innerHTML = ""; problema(e); }
  }

  // il percorso di una campagna regalo: dal contatto al regalo usato
  function imbutoCampagna(k) {
    const passi = [["Contatti", k.contatti], ["Hanno aperto il link", k.aperti], ["Hanno scoperto il regalo", k.scoperti], ["Hanno prenotato", k.prenotati], ["Regalo usato", k.usati]];
    const max = Math.max(1, k.contatti);
    return '<div class="griglia"><div class="c6"><div class="imbuto">' + passi.map(function (x) {
      return '<div class="gradino"><span>' + x[0] + '</span><div class="barra" style="width:' + Math.max(0.5, 100 * x[1] / max).toFixed(1) + '%"></div><b>' + num(x[1]) + " · " + pct(x[1], k.contatti) + "</b></div>";
    }).join("") + '</div><p class="dim" style="margin-top:10px">Disiscritti dalle email: ' + num(k.disiscritti) +
      (k.wa ? " · WhatsApp di richiamo " + (k.wa.attivo ? "acceso" : "spento") + ": " + num(k.wa.inviati) + " inviati, " + num(k.wa.scopertiDopo) + " regali scoperti dopo" : "") + "</p></div>" +
      '<div class="c6">' + tabella([["Gruppo"], ["Contatti", 1], ["Scoperti", 1], ["WhatsApp", 1]], (k.gruppi || []).map(function (x) {
        return { c: ["Gruppo " + x.gruppo, x.contatti, x.scoperti, x.whatsapp] };
      }), { vuoto: "Nessun gruppo programmato." }) +
      tabella([["Premio"], ["Usciti", 1], ["Limite", 1]], (k.premi || []).map(function (x) { return { c: [esc(x.emoji + " " + x.nome), x.usciti, x.limite == null ? "—" : x.limite] }; })) +
      "</div></div>";
  }

  /* ================= la scheda di un cliente ================= */
  async function schedaCliente(tel) {
    apriFinestra('<p class="dim">Carico…</p>');
    try {
      const c = await D.cliente(PIN, tel);
      const k = c.club, wa = c.whatsapp || {};
      const telLink = String(c.telefono).replace(/[^0-9+]/g, "");
      apriFinestra('<h2>👤 ' + esc(c.nome) + "</h2>" +
        '<p class="muted" style="margin:4px 0 12px"><a href="tel:' + esc(telLink) + '">' + esc(c.telefono) + "</a>" +
        (k && k.email ? " · " + esc(k.email) : "") + " · " + num(c.presenze) + (c.presenze === 1 ? " presenza" : " presenze") +
        (wa.stop ? ' · <span class="pill no">ha scritto STOP</span>' : "") + "</p>" +
        kpiRiga([
          ["Club", k ? "dal " + dataBreve(k.dal) : "no", "", k ? "arrivato da: " + esc(nomeCanale(k.canale)) : ""],
          ["Compleanno", k && k.nascita ? dataBreve(k.nascita).replace(/^\S+ /, "") : "—"],
          ["Offerte", k ? (k.promo ? "sì" : "no") : "—"],
          ["WhatsApp", num(wa.inviati) + " inviati", "", num(wa.ricevuti) + " ricevuti"],
        ]) +
        "<h3>Prenotazioni</h3>" + tabella([["Sera"], ["Ora"], ["Persone", 1], ["Da"], ["Stato"], ["Voto", 1], ["Nota"]], c.prenotazioni.map(function (p) {
          return { c: [dataLunga(p.sera), esc(p.turno), p.persone, esc(nomeCanale(p.canale)), esc(p.stato) + (p.benvenuto ? " 🥂" : ""), p.voto ? p.voto + " ★" : "", esc(p.nota || "")] };
        }), { vuoto: "Nessuna prenotazione." }) +
        '<h3 style="margin-top:14px">Asporto</h3>' + tabella([["Sera"], ["Ritiro"], ["Piatti"], ["Totale", 1], ["Stato"]], c.asporto.map(function (a) {
          return { c: [dataLunga(a.sera), esc(a.ritiro), esc((a.righe || []).map(function (r) { return r.qta + "× " + r.nome; }).join(", ")), euro(a.totale), esc(a.stato)] };
        }), { vuoto: "Nessun ordine d'asporto." }) +
        '<h3 style="margin-top:14px">Premi del Club</h3>' + tabella([["Premio"], ["Tipo"], ["Valido"], ["Usato"]], c.premi.map(function (r) {
          return { c: [esc(r.emoji + " " + r.nome), esc(NOMI_PREMIO[r.tipo] || r.tipo), dataBreve(r.dal) + " → " + dataBreve(r.al), r.usato ? dataBreve(r.usato) : '<span class="pill">non ancora</span>'] };
        }), { vuoto: "Nessun premio." }) +
        (c.campagne.length ? '<h3 style="margin-top:14px">Campagne</h3>' + tabella([["Campagna"], ["Gruppo", 1], ["Link aperto"], ["Regalo"], ["WhatsApp"]], c.campagne.map(function (x) {
          return { c: [esc(x.campagna), x.gruppo || "—", quando(x.aperto), x.premio ? esc(x.premio) + " · " + quando(x.scoperto) : "—",
            x.disiscritto ? '<span class="pill no">disiscritto</span>' : quando(x.whatsapp)] };
        })) : ""));
    } catch (e) { chiudiFinestra(); problema(e); }
  }

  /* ================= esporta (Excel) ================= */
  $("#b-esporta").addEventListener("click", function () {
    if (!STATO.cur) return;
    const col = [["g", "Sera"], ["incasso", "Incasso €"], ["coperti", "Coperti cassa"], ["scontrini", "Scontrini"], ["pren", "Prenotazioni"],
      ["persone", "Persone prenotate"], ["annullate", "Annullate"], ["noshow", "Non presentati"], ["asp", "Ordini asporto"], ["aspEuro", "Asporto €"],
      ["ordini", "Ordini al tavolo"], ["ordiniEuro", "Ordini tavolo €"], ["club", "Nuovi Club"], ["premiUsati", "Premi Club usati"],
      ["giocate", "Giocate agenti"], ["tavoli", "Tavoli agenti"], ["prPersone", "Persone agenti"], ["prEuro", "Provvigioni €"],
      ["fortuna", "Giocate Fortuna"], ["visite", "Visite sito"], ["waInviati", "WhatsApp inviati"], ["waRicevuti", "WhatsApp ricevuti"]];
    const cella = function (v) { if (v == null) return ""; if (typeof v === "number") return String(v).replace(".", ","); return '"' + String(v).replace(/"/g, '""') + '"'; };
    const righe = [col.map(function (c) { return c[1]; }).join(";")].concat(STATO.cur.giorni.map(function (x) {
      return col.map(function (c) { return cella(c[0] === "g" ? x.g : (x[c[0]] == null ? null : Number(x[c[0]]))); }).join(";");
    }));
    const blob = new Blob(["﻿" + righe.join("\r\n")], { type: "text/csv;charset=utf-8" });
    const a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "vico-dashboard-" + STATO.dal + "-" + STATO.al + ".csv";
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 2000);
  });

  /* ================= avvio ================= */
  async function avvia() {
    $("#login").hidden = true; $("#app").hidden = false;
    try { STATO.imp = await D.impostazioni(PIN); }
    catch (e) { if (e.codice === "pin") { esci(); return; } problema(e); return; }
    $("#confronto").value = STATO.modoCmp;
    riempiPeriodiSalvati();
    const p = periodoDa(STATO.preset || "30");
    impostaPeriodo(p[0], p[1], STATO.preset || "30");
  }
  // ogni 5 minuti, se il periodo arriva a oggi, i numeri si aggiornano da soli
  setInterval(function () { if (PIN && STATO.al && STATO.al >= D.oggiRoma() && !document.hidden && $("#velo").hidden) carica(); }, 5 * 60 * 1000);

  if (D.DEMO) $("#demo-bar").hidden = false;
  $("#b-cruscotto").href = "../titolare/" + (D.DEMO ? "?demo=1" : "?demo=0");
  if (PIN) avvia(); else mostraLogin();
})();
