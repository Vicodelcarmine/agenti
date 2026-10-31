/* Dashboard del titolare: riscatto dei buoni, serata, Club, agenti, premi, impostazioni.
   Si entra col PIN; un buono inquadrato con la fotocamera apre titolare/?b=CODICE,
   un premio del Club apre titolare/?c=CODICE. */

(function () {
  const C = Comune;
  const S = Store;
  let pin = null;
  let schedaAttiva = "riscatta";
  let premiBozza = [];

  /* ---------- PIN ---------- */
  function pinSalvato() {
    try { return localStorage.getItem("vdcpr_pin") || sessionStorage.getItem("vdcpr_pin"); } catch (e) { return null; }
  }
  function ricordaPin(p, sempre) {
    try {
      if (sempre) localStorage.setItem("vdcpr_pin", p); else sessionStorage.setItem("vdcpr_pin", p);
    } catch (e) {}
  }
  function dimenticaPin() {
    try { localStorage.removeItem("vdcpr_pin"); sessionStorage.removeItem("vdcpr_pin"); } catch (e) {}
  }

  function mostraLogin() {
    $("#app").hidden = true;
    $("#login").hidden = false;
    setTimeout(function () { $("#pin").focus(); }, 50);
  }

  $("#f-login").addEventListener("submit", async function (e) {
    e.preventDefault();
    const p = $("#pin").value.trim();
    if (!p) return;
    try {
      await S.entra(p);
      pin = p;
      ricordaPin(p, $("#ricorda").checked);
      $("#pin").value = "";
      dentro();
    } catch (er) {
      C.toast(er.codice === "pin" ? "PIN sbagliato" : "Connessione assente", true);
      $("#pin").select();
    }
  });

  function dentro() {
    $("#login").hidden = true;
    $("#app").hidden = false;
    document.body.classList.add("con-tab");
    avviaNovita();
    const q = new URLSearchParams(location.search);
    const b = C.pulisciCodice(q.get("b")), c = C.pulisciCodice(q.get("c")), tab = q.get("tab");
    if (b || c) {
      history.replaceState(null, "", location.pathname);
      vai("riscatta");
      if (b) cerca(b); else cercaClub(c);
    } else if (tab && $('[data-tab="' + tab + '"]')) {
      // dalla notifica di una prenotazione: ?tab=prenota
      history.replaceState(null, "", location.pathname);
      vai(tab);
    } else {
      vai(schedaAttiva);
    }
  }

  // ogni chiamata col PIN: se il PIN non va più bene si torna al login
  async function conPin(fn) {
    try { return await fn(pin); }
    catch (e) {
      if (e.codice === "pin") { dimenticaPin(); pin = null; mostraLogin(); C.toast("Il PIN è cambiato: rientra", true); }
      throw e;
    }
  }
  function errore(e) { if (e.codice !== "pin") C.toast(e.message || "Qualcosa è andato storto", true); }

  /* ---------- schede ---------- */
  function vai(nome) {
    schedaAttiva = nome;
    $$("[data-tab]").forEach(function (s) { s.hidden = s.dataset.tab !== nome; });
    $$(".tabbar button").forEach(function (b) { b.classList.toggle("on", b.dataset.vai === nome); });
    window.scrollTo(0, 0);
    ({ riscatta: caricaRiscatta, stasera: caricaStasera, prenota: caricaPrenota, club: caricaClub, agenti: caricaAgenti,
       premi: caricaPremi, altro: caricaAltro })[nome]();
  }
  $$(".tabbar button").forEach(function (b) { b.addEventListener("click", function () { vai(b.dataset.vai); }); });

  /* ---------- foglio (finestra dal basso) ---------- */
  function apriFoglio(html) {
    $("#foglio-corpo").innerHTML = html;
    $("#foglio").hidden = false;
    $("#foglio .dentro").scrollTop = 0;
    document.body.style.overflow = "hidden";
  }
  function chiudiFoglio() {
    $("#foglio").hidden = true;
    document.body.style.overflow = "";
  }
  $("#chiudi-foglio").addEventListener("click", chiudiFoglio);
  $("#foglio").addEventListener("click", function (e) { if (e.target.id === "foglio") chiudiFoglio(); });

  // numerino rosso sull'icona Agenti: richieste "Diventa agente" da vedere
  function segnaRichieste(n) {
    const b = $('.tabbar [data-vai="agenti"]');
    if (n > 0) b.dataset.badge = n; else delete b.dataset.badge;
  }

  /* ================= RISCATTA ================= */

  function caricaRiscatta() {
    if (!$("#r-esito").innerHTML) $("#r-inizio").hidden = false;
    riassuntoSera();
  }
  async function riassuntoSera() {
    try {
      const p = await conPin(S.panoramica);
      segnaRichieste(p.richieste || 0);
      const persone = p.tavoli.reduce(function (s, t) { return s + t.persone; }, 0);
      const euro = p.tavoli.reduce(function (s, t) { return s + t.euro; }, 0);
      $("#r-sera").innerHTML = "<h3>🌙 Stasera finora</h3>" +
        '<div class="kpi"><div><b>' + p.tavoli.length + "</b><span>tavoli</span></div>" +
        "<div><b>" + persone + "</b><span>persone</span></div>" +
        '<div class="euro"><b>' + C.euro(euro) + "</b><span>provvigioni</span></div></div>";
    } catch (e) { errore(e); }
  }

  $("#f-codice").addEventListener("submit", function (e) {
    e.preventDefault();
    const c = C.pulisciCodice($("#codice").value);
    if (c.length === 6) cerca(c);
    else if (c.length === 7) cercaClub(c);
    else C.toast("Il codice ha 6 caratteri (buono agente) o 7 (premio Club)", true);
  });

  async function cerca(codice) {
    $("#r-inizio").hidden = true;
    $("#r-esito").innerHTML = '<div class="card center muted">Cerco il buono ' + C.codiceBello(codice) + "…</div>";
    try {
      const b = await conPin(function (p) { return S.leggiBuono(p, codice); });
      mostraEsito(b);
    } catch (e) {
      if (e.codice === "pin") return;
      $("#r-esito").innerHTML = '<div class="card esito"><div class="emoji">🤔</div>' +
        '<div class="avviso no">' + C.esc(e.message) + "<br><small>Codice: " + C.codiceBello(codice) + "</small></div>" +
        '<button class="btn vuoto pieno" data-azione="altro">← Scansiona un altro</button></div>';
      legaAltro();
    }
  }

  // "alle 22:10" se è stasera, "lun 5 ott alle 22:10" se è un'altra sera
  function quando(t) {
    return (C.sera(t) === C.sera() ? "" : C.dataBreve(C.sera(t)) + " ") + "alle " + C.ora(t);
  }

  function intestazioneBuono(b) {
    return '<div class="emoji">' + b.premio.emoji + "</div>" +
      '<div class="nome">' + C.esc(b.premio.nome.it) + "</div>" +
      '<div class="muted small">' + C.esc(b.premio.desc.it) + "</div>" +
      '<p style="margin-top:10px">Mandato da <b>' + C.esc(b.agente.nome) + "</b>" +
      (b.agente.attivo ? "" : ' <span class="pill no">in pausa</span>') + "</p>" +
      '<p class="dim">Codice ' + C.codiceBello(b.codice) + " · giocato " + quando(b.creato) +
      (C.sera(b.scade) !== C.sera(b.creato) ? " · valido fino a " + C.dataBreve(C.sera(b.scade)) : "") + "</p>";
  }

  function mostraEsito(b) {
    const box = $("#r-esito");
    let corpo;
    if (b.stato === "riscattato") {
      corpo = '<div class="avviso no">⚠️ Già usato alle ' + C.ora(b.riscattato) + " · " + b.persone +
        (b.persone === 1 ? " persona" : " persone") + " · " + C.euro(b.euro) + " all'agente</div>" +
        (b.annullabile ? '<button class="btn vuoto pieno" data-azione="annulla">Annulla questo riscatto</button>' : "");
    } else if (b.stato === "scaduto") {
      corpo = '<div class="avviso no">⛔ Scaduto: valeva fino a ' + quando(b.scade) + ".</div>";
    } else {
      corpo =
        '<p style="margin-top:14px;font-weight:600">Quante persone al tavolo?</p>' +
        '<div class="stepper"><button type="button" data-d="-1" aria-label="Meno">−</button>' +
        '<output id="persone">2</output><button type="button" data-d="1" aria-label="Più">+</button></div>' +
        '<div class="provv" id="anteprima"></div>' +
        '<button class="btn verde pieno grande" data-azione="riscatta">✅ Riscatta il premio</button>';
    }
    box.innerHTML = '<div class="card oro esito">' + intestazioneBuono(b) + corpo +
      '<button class="btn vuoto pieno" style="margin-top:10px" data-azione="altro">← Scansiona un altro</button></div>';
    legaAltro();

    if (b.stato === "attivo") {
      let n = 2;
      const aggiornaAnteprima = function () {
        $("#persone").textContent = n;
        const pr = C.provvigione(b.fasce, b.giaStasera, n);
        $("#anteprima").innerHTML = "A " + C.esc(b.agente.nome) + ": <b>" + C.euro(pr.euro) + "</b>" +
          '<div class="dim">' + C.spiegaRighe(pr.righe) + "</div>" +
          (b.bonus ? '<div class="dim">🔥 Settimana di benvenuto: tariffe maggiorate</div>' : "") +
          '<div class="dim">Stasera finora: ' + b.giaStasera + (b.giaStasera === 1 ? " persona" : " persone") + "</div>";
      };
      aggiornaAnteprima();
      $$(".stepper button", box).forEach(function (btn) {
        btn.addEventListener("click", function () { n = Math.max(1, Math.min(60, n + Number(btn.dataset.d))); aggiornaAnteprima(); });
      });
      $('[data-azione="riscatta"]', box).addEventListener("click", async function () {
        this.disabled = true;
        try {
          const r = await conPin(function (p) { return S.riscatta(p, b.codice, n); });
          if (navigator.vibrate) navigator.vibrate([40, 60, 40]);
          S.notifica(b.codice).catch(function () {});   // avviso sul telefono dell'agente
          box.innerHTML = '<div class="card esito">' +
            '<div class="emoji">' + r.premio.emoji + "</div>" +
            '<div class="avviso ok">✅ Fatto! Da servire: <b>' + C.esc(r.premio.nome.it) + "</b></div>" +
            "<p>" + C.esc(r.agente) + " <b style=\"color:var(--gold)\">+" + C.euro(r.euro) + "</b></p>" +
            '<p class="dim">' + n + (n === 1 ? " persona" : " persone") + " · " + C.spiegaRighe(r.righe) + "</p>" +
            '<button class="btn oro pieno" style="margin-top:14px" data-azione="altro">📷 Scansiona un altro</button>' +
            '<button class="btn vuoto pieno" style="margin-top:10px" data-azione="annulla">Annulla (ho sbagliato)</button></div>';
          legaAltro();
          legaAnnulla(b.codice);
          riassuntoSera();
        } catch (e) {
          this.disabled = false;
          errore(e);
          if (e.codice === "usato" || e.codice === "scaduto") cerca(b.codice);
        }
      });
    }
    legaAnnulla(b.codice);
  }

  function legaAltro() {
    $$('[data-azione="altro"]', $("#r-esito")).forEach(function (btn) {
      btn.addEventListener("click", function () {
        $("#r-esito").innerHTML = "";
        $("#codice").value = "";
        $("#r-inizio").hidden = false;
        window.scrollTo(0, 0);
      });
    });
  }
  function legaAnnulla(codice) {
    const btn = $('[data-azione="annulla"]', $("#r-esito"));
    if (!btn) return;
    btn.addEventListener("click", async function () {
      if (!confirm("Annullo il riscatto? Il buono torna valido e la provvigione viene tolta.")) return;
      try {
        await conPin(function (p) { return S.annulla(p, codice); });
        C.toast("Riscatto annullato");
        cerca(codice);
        riassuntoSera();
      } catch (e) { errore(e); }
    });
  }

  /* ---------- premio del Club (7 caratteri) ---------- */
  const TIPO_CLUB = { benvenuto: "Premio di benvenuto", compleanno: "Regalo di compleanno", promo: "Offerta del Club",
                      fortuna: "Premio di Tenta la Fortuna", regalo: "Regalo a sorpresa della campagna" };
  // per quante persone vale un premio del Club (0 = gli sconti della Fortuna: il nome dice già "sul conto")
  function perChi(n, prima) { return n > 0 ? (prima || "") + "per " + persone(n) : ""; }
  function codiceClub(c) { return c.slice(0, 3) + " " + c.slice(3); }
  function giorniNoTesto(g) {
    return g && g.length ? g.map(function (n) { return C.NOMI_GIORNI[n]; }).join(" e ") + " escluso" : "";
  }
  function persone(n) { return n + (n === 1 ? " persona" : " persone"); }

  async function cercaClub(codice) {
    $("#r-inizio").hidden = true;
    $("#r-esito").innerHTML = '<div class="card center muted">Cerco il premio ' + codiceClub(codice) + "…</div>";
    try {
      const p = await conPin(function (pp) { return S.clubLeggiPremio(pp, codice); });
      mostraPremioClub(p);
    } catch (e) {
      if (e.codice === "pin") return;
      $("#r-esito").innerHTML = '<div class="card esito"><div class="emoji">🤔</div>' +
        '<div class="avviso no">' + C.esc(e.message) + "<br><small>Codice: " + codiceClub(codice) + "</small></div>" +
        '<button class="btn vuoto pieno" data-azione="altro">← Scansiona un altro</button></div>';
      legaAltro();
    }
  }

  function intestazionePremioClub(p) {
    const no = giorniNoTesto(p.giorniNo);
    return '<div class="emoji">' + C.esc(p.emoji) + "</div>" +
      '<div class="nome">' + C.esc(p.nome.it) + "</div>" +
      (p.persone > 0 ? '<div class="muted small">' + perChi(p.persone) + "</div>" : "") +
      '<p style="margin-top:10px">' + (TIPO_CLUB[p.tipo] || "Premio del Club") + " di <b>" + C.esc(p.iscritto.nome) + "</b></p>" +
      '<p class="dim">Codice ' + codiceClub(p.codice) + " · vale da " + C.dataBreve(p.dal) + " a " + C.dataBreve(p.al) +
      (no ? " · " + no : "") + "</p>";
  }

  function mostraPremioClub(p) {
    const box = $("#r-esito");
    const forza = '<button class="btn vuoto pieno" style="margin-top:4px" data-azione="forza">Dallo lo stesso</button>';
    let corpo;
    if (p.stato === "usato") {
      corpo = '<div class="avviso no">⚠️ Già usato ' + quando(p.usato) + "</div>" +
        (p.annullabile ? '<button class="btn vuoto pieno" data-azione="annulla-club">Annulla (torna da usare)</button>' : "");
    } else if (p.stato === "presto") {
      corpo = '<div class="avviso no">⏳ Non ancora: vale da ' + (p.dal === C.piuGiorni(C.sera(), 1) ? "domani, " : "") +
        C.dataBreve(p.dal) + ". È un premio per la prossima visita.</div>" + forza;
    } else if (p.stato === "oggi_no") {
      corpo = '<div class="avviso no">⛔ Stasera è ' + C.NOMI_GIORNI[C.giornoSettimana(C.sera())] + ": questo premio non vale.</div>" + forza;
    } else if (p.stato === "scaduto") {
      corpo = '<div class="avviso no">⛔ Scaduto: valeva fino a ' + C.dataBreve(p.al) + ".</div>" + forza;
    } else if (p.soloPrenotati && !p.prenotato) {
      corpo = '<div class="avviso no">📅 Questo regalo vale solo con una prenotazione fatta dal sito per stasera, e non la trovo.</div>' + forza;
    } else {
      corpo = '<button class="btn verde pieno grande" style="margin-top:14px" data-azione="usa">✅ Usa il premio</button>';
    }
    box.innerHTML = '<div class="card oro esito">' + intestazionePremioClub(p) + corpo +
      '<button class="btn vuoto pieno" style="margin-top:10px" data-azione="altro">← Scansiona un altro</button></div>';
    legaAltro();

    const usa = async function (btn, forzato) {
      btn.disabled = true;
      try {
        const r = await conPin(function (pp) { return S.clubUsa(pp, p.codice, forzato); });
        if (navigator.vibrate) navigator.vibrate([40, 60, 40]);
        box.innerHTML = '<div class="card esito">' +
          '<div class="emoji">' + C.esc(r.emoji) + "</div>" +
          '<div class="avviso ok">✅ Fatto! Da servire: <b>' + C.esc(r.nome.it) + "</b><br>per " + persone(r.persone) + "</div>" +
          "<p>" + (TIPO_CLUB[r.tipo] || "Premio del Club") + " di <b>" + C.esc(r.iscritto.nome) + "</b></p>" +
          '<button class="btn oro pieno" style="margin-top:14px" data-azione="altro">📷 Scansiona un altro</button>' +
          '<button class="btn vuoto pieno" style="margin-top:10px" data-azione="annulla-club">Annulla (ho sbagliato)</button></div>';
        legaAltro();
        legaAnnullaClub(p.codice);
      } catch (e) {
        btn.disabled = false;
        errore(e);
        if (e.codice !== "pin") cercaClub(p.codice);
      }
    };
    const bUsa = $('[data-azione="usa"]', box);
    if (bUsa) bUsa.addEventListener("click", function () { usa(bUsa, false); });
    const bForza = $('[data-azione="forza"]', box);
    if (bForza) bForza.addEventListener("click", function () {
      if (!confirm("Stasera questo premio non varrebbe. Lo dai lo stesso a " + p.iscritto.nome + "?")) return;
      usa(bForza, true);
    });
    legaAnnullaClub(p.codice);
  }
  function legaAnnullaClub(codice) {
    const btn = $('[data-azione="annulla-club"]', $("#r-esito"));
    if (!btn) return;
    btn.addEventListener("click", async function () {
      if (!confirm("Annullo? Il premio torna da usare.")) return;
      try {
        await conPin(function (p) { return S.clubAnnulla(p, codice); });
        C.toast("Annullato: il premio è di nuovo da usare");
        cercaClub(codice);
      } catch (e) { errore(e); }
    });
  }

  /* ---------- scanner ---------- */
  let flusso = null, giro = null;
  function caricaJsQR() {
    if (window.jsQR) return Promise.resolve();
    return new Promise(function (ok, ko) {
      const s = document.createElement("script");
      s.src = "https://cdn.jsdelivr.net/npm/jsqr@1.4.0/dist/jsQR.min.js";
      s.onload = ok; s.onerror = ko;
      document.head.appendChild(s);
    });
  }
  async function apriScanner() {
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
      C.toast("Fotocamera non disponibile: scrivi il codice", true);
      return;
    }
    const sc = $("#scanner"), video = $("video", sc);
    sc.hidden = false;
    try {
      flusso = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false });
    } catch (e) {
      sc.hidden = true;
      C.toast("Non riesco ad aprire la fotocamera: scrivi il codice", true);
      return;
    }
    video.srcObject = flusso;
    try { await video.play(); } catch (e) {}

    let leggiFrame = null;
    if ("BarcodeDetector" in window) {
      try {
        const det = new BarcodeDetector({ formats: ["qr_code"] });
        leggiFrame = async function () { const r = await det.detect(video); return r[0] && r[0].rawValue; };
      } catch (e) {}
    }
    if (!leggiFrame) {
      try { await caricaJsQR(); } catch (e) { chiudiScanner(); C.toast("Lettore QR non disponibile: scrivi il codice", true); return; }
      const tela = document.createElement("canvas");
      const ctx = tela.getContext("2d", { willReadFrequently: true });
      leggiFrame = async function () {
        const w = video.videoWidth, h = video.videoHeight;
        if (!w) return null;
        const k = Math.min(1, 640 / Math.max(w, h));
        tela.width = Math.round(w * k); tela.height = Math.round(h * k);
        ctx.drawImage(video, 0, 0, tela.width, tela.height);
        const img = ctx.getImageData(0, 0, tela.width, tela.height);
        const r = jsQR(img.data, img.width, img.height, { inversionAttempts: "dontInvert" });
        return r && r.data;
      };
    }
    const ciclo = async function () {
      if (!flusso) return;
      try {
        const testo = await leggiFrame();
        const c = testo && C.pulisciCodice(testo);
        if (c && (c.length === 6 || c.length === 7)) {
          chiudiScanner();
          if (navigator.vibrate) navigator.vibrate(60);
          if (c.length === 6) cerca(c); else cercaClub(c);
          return;
        }
      } catch (e) {}
      giro = setTimeout(ciclo, 180);
    };
    ciclo();
  }
  function chiudiScanner() {
    clearTimeout(giro);
    if (flusso) flusso.getTracks().forEach(function (t) { t.stop(); });
    flusso = null;
    $("#scanner").hidden = true;
  }
  $("#scansiona").addEventListener("click", apriScanner);
  $("#chiudi-scanner").addEventListener("click", chiudiScanner);

  /* ================= STASERA ================= */

  async function caricaStasera() {
    try {
      const p = await conPin(S.panoramica);
      const persone = p.tavoli.reduce(function (s, t) { return s + t.persone; }, 0);
      const euro = p.tavoli.reduce(function (s, t) { return s + t.euro; }, 0);
      $("#st-chiusura").textContent = "buoni validi fino alle " + p.chiusura;
      $("#st-giocate").textContent = p.giocate;
      $("#st-tavoli").textContent = p.tavoli.length;
      $("#st-persone").textContent = persone;
      $("#st-euro").textContent = C.euro(euro);
      $("#st-attesa").textContent = p.inAttesa;

      const conGiocate = p.agenti.filter(function (a) { return a.stasera.giocate > 0; });
      $("#st-agenti").innerHTML = conGiocate.length ? conGiocate.map(function (a) {
        return '<li><div class="cresce"><b>' + C.esc(a.nome) + '</b><div class="dim">' + a.stasera.giocate +
          " giocate · " + a.stasera.tavoli + " tavoli · " + a.stasera.persone + " persone</div></div>" +
          '<span class="euro">' + C.euro(a.stasera.euro) + "</span></li>";
      }).join("") : '<li class="vuoto">Nessuno ha ancora giocato stasera.</li>';

      $("#st-tavoli-lista").innerHTML = p.tavoli.length ? p.tavoli.map(function (t) {
        return '<li><span style="font-size:1.4rem">' + t.premio.emoji + '</span><div class="cresce"><b>' + t.persone +
          (t.persone === 1 ? " persona" : " persone") + '</b> · <span class="muted">' + C.esc(t.agente) + "</span>" +
          '<div class="dim">' + C.ora(t.quando) + " · " + C.esc(t.premio.nome.it) + "</div></div>" +
          '<div style="text-align:right"><span class="euro">' + C.euro(t.euro) + "</span>" +
          (t.annullabile ? '<br><button class="btn vuoto piccolo" style="margin-top:4px" data-annulla="' + t.codice + '">Annulla</button>' : "") +
          "</div></li>";
      }).join("") : '<li class="vuoto">Nessun tavolo ancora.</li>';
      $$("[data-annulla]", $("#st-tavoli-lista")).forEach(function (btn) {
        btn.addEventListener("click", async function () {
          if (!confirm("Annullo questo tavolo? Il buono torna valido e la provvigione viene tolta.")) return;
          try { await conPin(function (pp) { return S.annulla(pp, btn.dataset.annulla); }); C.toast("Annullato"); caricaStasera(); }
          catch (e) { errore(e); }
        });
      });
    } catch (e) { errore(e); }
  }

  /* ================= CLUB ================= */

  // anni che compie in quel giorno (per i compleanni) / anni che ha in quel giorno
  function anni(nascita, giorno) { return +giorno.slice(0, 4) - +nascita.slice(0, 4); }
  function eta(nascita, giorno) { return anni(nascita, giorno) - (giorno.slice(5) < nascita.slice(5) ? 1 : 0); }
  // "+393331112233" → "+39 333 111 2233"
  function telBello(t) { return String(t || "").replace(/^\+39(\d{3})(\d{3})(\d+)$/, "+39 $1 $2 $3"); }

  // le campagne "regalo a sorpresa" (supabase/18-campagna-regalo.sql): come stanno andando
  async function caricaCampagne() {
    let lista = null;
    try { lista = await conPin(S.campPanoramica); } catch (e) { /* non ancora installate: il riquadro resta nascosto */ }
    $("#cl-camp-box").hidden = !(lista && lista.length);
    if (!lista) return;
    $("#cl-camp").innerHTML = lista.map(function (k) {
      return '<p style="margin-top:4px"><b>' + C.esc(k.nome) + "</b>" + (k.attiva ? "" : ' <span class="pill">ferma</span>') + "</p>" +
        '<div class="kpi" style="margin-top:8px">' +
          "<div><b>" + k.contatti + "</b><span>contatti</span></div>" +
          "<div><b>" + k.aperti + "</b><span>hanno aperto il link</span></div>" +
          '<div class="euro"><b>' + k.scoperti + "</b><span>regali scoperti</span></div></div>" +
        '<div class="kpi" style="margin-top:8px">' +
          '<div class="euro"><b>' + k.prenotati + "</b><span>hanno prenotato</span></div>" +
          "<div><b>" + k.usati + "</b><span>regali usati</span></div>" +
          "<div><b>" + k.disiscritti + "</b><span>disiscritti</span></div></div>" +
        '<ul class="lista" style="margin-top:8px">' + (k.premi || []).map(function (p) {
          const finiti = p.limite != null && p.usciti >= p.limite;
          return '<li><span style="font-size:1.3rem">' + C.esc(p.emoji) + '</span><span class="cresce">' + C.esc(p.nome) + "</span>" +
            '<span class="pill' + (finiti ? " no" : "") + '">' + p.usciti + (p.limite != null ? " / " + p.limite : "") +
            (finiti ? " finiti" : "") + "</span></li>";
        }).join("") + "</ul>" +
        '<p class="dim" style="margin-top:6px">Il regalo vale ' + k.sere + " sere da quando lo scoprono, sabato escluso" +
        (k.scopriEntro ? " · i link danno regali fino al " + C.dataBreve(k.scopriEntro) : "") + "</p>" +
        campWhatsapp(k);
    }).join("");
    $$("[data-camp-wa]", $("#cl-camp")).forEach(function (btn) {
      btn.addEventListener("click", async function () {
        const accendi = btn.dataset.campWa === "1";
        if (accendi && !confirm("Accendo il WhatsApp di richiamo? Parte solo se Meta ha approvato il modello, " +
          "ai clienti che non hanno ancora scoperto il regalo, " + "qualche giorno dopo l'email del loro gruppo.")) return;
        btn.disabled = true;
        try { await conPin(function (pp) { return S.campWaAttiva(pp, btn.dataset.camp, accendi); }); caricaCampagne(); }
        catch (e) { errore(e); btn.disabled = false; }
      });
    });
  }
  // il WhatsApp di richiamo (supabase/19-campagna-whatsapp.sql): acceso o no, i gruppi e quando parte
  function campWhatsapp(k) {
    const w = k.wa;
    if (!w) return "";
    const quando = function (t) { return C.dataBreve(C.sera(t)) + " " + C.ora(t); };
    return '<p style="margin-top:14px"><b>📲 WhatsApp di richiamo</b></p>' +
      '<p class="dim">A chi non ha ancora scoperto il regalo, ' + w.giorni + " giorni dopo l'email del suo gruppo " +
      "(sabato escluso, dalle 10 alle 20). Chi si toglie dalle email o scrive STOP non lo riceve.</p>" +
      '<div class="riga" style="margin-top:8px;align-items:center">' +
        '<span class="pill fisso ' + (w.attivo ? "ok" : "no") + '">' + (w.attivo ? "acceso" : "spento") + "</span>" +
        '<button class="btn fisso ' + (w.attivo ? "vuoto " : "oro ") + 'piccolo" data-camp="' + C.esc(k.id) + '" data-camp-wa="' +
          (w.attivo ? "0" : "1") + '">' + (w.attivo ? "Spegni" : "Accendi") + "</button></div>" +
      (w.attivo || w.inviati ? '<div class="kpi" style="margin-top:8px">' +
        "<div><b>" + w.inviati + "</b><span>WhatsApp partiti</span></div>" +
        "<div><b>" + w.letti + "</b><span>letti</span></div>" +
        '<div class="euro"><b>' + w.scopertiDopo + "</b><span>regali scoperti dopo</span></div></div>" : "") +
      (w.errori ? '<p class="dim" style="margin-top:6px">⚠️ ' + w.errori + " non partiti" +
        (w.ultimoErrore ? ": " + C.esc(w.ultimoErrore) : "") + "</p>"
        : w.ultimoErrore ? '<p class="dim" style="margin-top:6px">⏳ Si riprova fra poco: ' + C.esc(w.ultimoErrore) + "</p>" : "") +
      ((k.gruppi || []).length ? '<ul class="lista" style="margin-top:8px">' + k.gruppi.map(function (g) {
        return '<li><div class="cresce"><b>Gruppo ' + g.gruppo + "</b> · " + g.contatti + " contatti" +
          '<div class="dim">✉️ ' + quando(g.email) + " · 📲 " + quando(g.wa) + "</div></div>" +
          '<span class="pill oro">' + g.scoperti + " scoperti</span>" +
          (g.whatsapp ? ' <span class="pill">' + g.whatsapp + " WhatsApp</span>" : "") + "</li>";
      }).join("") + "</ul>" : "") +
      (k.senzaGruppo ? '<p class="dim" style="margin-top:6px">' + k.senzaGruppo +
        " contatti non hanno ancora l'email programmata: niente WhatsApp finché non parte la loro.</p>" : "");
  }

  async function caricaClub() {
    cercaIscritti();
    caricaCampagne();
    try {
      const v = await Promise.all([conPin(S.clubPanoramica), conPin(S.clubImpostazioni)]);
      const p = v[0], imp = v[1];
      $("#cl-iscritti").textContent = p.iscritti;
      $("#cl-nuovi").textContent = p.nuovi;
      $("#cl-attivi").textContent = p.attivi;
      $("#cl-promo").textContent = p.promo + " accettano le offerte";
      $("#cl-mese").textContent = "Questo mese: " + p.usatiMese + (p.usatiMese === 1 ? " premio usato" : " premi usati");
      $("#cl-stasera").innerHTML = p.stasera.length ? p.stasera.map(function (x) {
        return '<li data-premio="' + C.esc(x.codice) + '" style="cursor:pointer"><span style="font-size:1.4rem">' + C.esc(x.emoji) + "</span>" +
          '<div class="cresce"><b>' + C.esc(x.nome) + '</b><div class="dim">' + C.ora(x.quando) + " · " + C.esc(x.premio.it) +
          perChi(x.persone, " · ") + "</div></div></li>";
      }).join("") : '<li class="vuoto">Nessun premio usato stasera.</li>';
      $$("[data-premio]", $("#cl-stasera")).forEach(function (li) {
        li.addEventListener("click", function () { vai("riscatta"); cercaClub(li.dataset.premio); });
      });
      const oggi = C.sera();
      $("#cl-compleanni-box").hidden = !p.compleanni.length;
      $("#cl-compleanni").innerHTML = p.compleanni.map(function (x) {
        const nome1 = x.nome.split(/\s+/)[0];
        return "<li><span style=\"font-size:1.4rem\">🎂</span><div class=\"cresce\"><b>" + C.esc(x.nome) + "</b>" +
          '<div class="dim">' + (x.giorno === oggi ? "<b style=\"color:var(--gold)\">oggi</b>" : C.dataBreve(x.giorno)) +
          " · compie " + anni(x.nascita, x.giorno) + " anni</div></div>" +
          '<a class="btn vuoto piccolo" target="_blank" rel="noopener" href="' +
          linkChat(x.telefono, "Tanti auguri " + nome1 + "! 🎂 Ti aspettiamo al Vico del Carmine per festeggiare insieme.") +
          '">💬 Auguri</a></li>';
      }).join("");
      $("#cl-emoji").value = imp.emoji;
      $("#cl-nome").value = imp.nome.it || "";
      $("#cl-nome-en").value = imp.nome.en || "";
      $("#cl-persone").value = imp.persone;
      $("#cl-sere").value = imp.sere;
      chipGiorni($("#cl-giorni-no"), imp.giorniNo || []);
      chipGiorni($("#cl-giorni-chiusura"), imp.giorniChiusura || []);
      impClub = imp;
      $("#cl-comp-per").value = imp.compleannoPer;
      $("#cl-comp-giorni").value = imp.compleannoGiorni;
      anteprimaCompleanno();
      $("#cl-off-attive").checked = imp.offerteAttive;
      $("#cl-off-settimane").value = imp.offerteSettimane;
      $("#cl-off-pausa").value = imp.offertePausa;
      $("#cl-off-persone").value = imp.offertePersone;
      $("#cl-off-sere").value = imp.offerteSere;
      $("#cl-av-notifiche").textContent = p.conNotifiche + (p.conNotifiche === 1 ? " iscritto le ha accese" : " iscritti le hanno accese") +
        (p.inCoda ? " · " + p.inCoda + " avvisi in coda" : "");
      $("#cl-av-giro").textContent = p.ultimoGiro
        ? "Ultimo: " + C.nomeSera(C.sera(p.ultimoGiro)).toLowerCase() + " alle " + C.ora(p.ultimoGiro) +
          (p.ultimoEsito ? " · " + esitoGiro(p.ultimoEsito) : "")
        : "Ogni giorno verso le 11: compleanni e offerte";
      statoEmail(imp);
      caricaOfferte();
      caricaMessaggi();
    } catch (e) { errore(e); }
  }

  /* --- compleanno --- */
  let impClub = null;
  function anteprimaCompleanno() {
    if (!impClub) return;
    const per = parseInt($("#cl-comp-per").value, 10) || 1, g = parseInt($("#cl-comp-giorni").value, 10) || 0;
    $("#cl-comp-anteprima").textContent = "= " + impClub.nome.it + " per " + persone(impClub.persone * per) +
      ", da " + g + (g === 1 ? " giorno" : " giorni") + " prima a " + g + (g === 1 ? " giorno" : " giorni") + " dopo il compleanno.";
  }
  ["#cl-comp-per", "#cl-comp-giorni"].forEach(function (id) { $(id).addEventListener("input", anteprimaCompleanno); });
  $("#cl-comp-salva").addEventListener("click", async function () {
    try {
      await conPin(function (p) {
        return S.clubSalvaImpostazioni(p, { compleannoPer: $("#cl-comp-per").value, compleannoGiorni: $("#cl-comp-giorni").value });
      });
      C.toast("Regalo di compleanno salvato");
      caricaClub();
    } catch (e) { errore(e); }
  });

  /* --- offerte "ci manchi" --- */
  let offerteBozza = [];
  async function caricaOfferte() {
    try {
      offerteBozza = JSON.parse(JSON.stringify(await conPin(S.clubOfferte)));
      disegnaOfferte();
    } catch (e) { errore(e); }
  }
  function disegnaOfferte() {
    $("#cl-offerte").innerHTML = offerteBozza.length ? offerteBozza.map(function (o, i) {
      return '<div class="premio-ed' + (o.attivo ? "" : " spento") + '" data-i="' + i + '">' +
        '<div class="testa"><input type="text" class="emo" data-k="emoji" value="' + C.esc(o.emoji) + '" aria-label="Emoji">' +
        '<div class="cresce"><input type="text" data-k="nome.it" value="' + C.esc(o.nome.it) + '" placeholder="es. Dolce offerto"></div>' +
        '<label class="switch"><input type="checkbox" data-k="attivo"' + (o.attivo ? " checked" : "") + "><i></i></label></div>" +
        "<details><summary>Inglese e togli</summary>" +
        '<label class="campo"><span>In inglese (per i turisti)</span><input type="text" data-k="nome.en" value="' + C.esc(o.nome.en || "") + '"></label>' +
        '<button class="btn vuoto piccolo" data-togli>🗑 Togli questa offerta</button></details></div>';
    }).join("") : '<div class="vuoto">Nessuna offerta: aggiungine una.</div>';
  }
  $("#cl-offerte").addEventListener("input", function (e) {
    const k = e.target.dataset.k, riga = e.target.closest("[data-i]");
    if (!k || !riga) return;
    const o = offerteBozza[+riga.dataset.i];
    const v = e.target.type === "checkbox" ? e.target.checked : e.target.value;
    if (k.indexOf(".") > 0) { const kk = k.split("."); o[kk[0]][kk[1]] = v; } else o[k] = v;
    riga.classList.toggle("spento", !o.attivo);
  });
  $("#cl-offerte").addEventListener("click", function (e) {
    if (!e.target.hasAttribute("data-togli")) return;
    offerteBozza.splice(+e.target.closest("[data-i]").dataset.i, 1);
    disegnaOfferte();
  });
  $("#cl-off-nuova").addEventListener("click", function () {
    offerteBozza.push({ id: null, emoji: "🎁", attivo: true, nome: { it: "", en: "" } });
    disegnaOfferte();
    const ultima = $$(".premio-ed", $("#cl-offerte")).pop();
    $('[data-k="nome.it"]', ultima).focus();
  });
  $("#cl-off-salva").addEventListener("click", async function () {
    try {
      await conPin(function (p) {
        return S.clubSalvaImpostazioni(p, {
          offerteAttive: $("#cl-off-attive").checked, offerteSettimane: $("#cl-off-settimane").value,
          offertePausa: $("#cl-off-pausa").value, offertePersone: $("#cl-off-persone").value, offerteSere: $("#cl-off-sere").value,
        });
      });
      await conPin(function (p) { return S.clubSalvaOfferte(p, offerteBozza); });
      C.toast("Offerte salvate");
      caricaClub();
    } catch (e) { errore(e); }
  });

  /* --- avvisi: email, giro, ultimi messaggi --- */
  async function statoEmail(imp) {
    const sw = $("#cl-av-email");
    sw.checked = !!imp.emailAttive;
    let collegate = false;
    try { collegate = !!(await S.clubStatoInvii()).email; } catch (e) {}
    sw.disabled = !collegate && !imp.emailAttive;
    $("#cl-av-email-stato").textContent = collegate
      ? (imp.emailAttive ? "Accese: partono da club@ai-io.it, le risposte arrivano a vicodelcarmine1@gmail.com" : "Collegate ma spente")
      : "Da collegare (servizio Resend): per ora partono solo le notifiche";
  }
  $("#cl-av-email").addEventListener("change", async function () {
    const acceso = this.checked;
    try {
      await conPin(function (p) { return S.clubSalvaImpostazioni(p, { emailAttive: acceso }); });
      C.toast(acceso ? "Email del Club accese" : "Email del Club spente");
      caricaClub();
    } catch (e) { this.checked = !acceso; errore(e); }
  });
  $("#cl-giro").addEventListener("click", async function () {
    if (!confirm("Controllo adesso compleanni e offerte e mando gli avvisi. Non manda niente due volte. Procedo?")) return;
    this.disabled = true;
    try {
      const r = await conPin(S.clubGiroOra);
      await S.clubInvia();
      C.toast("Fatto: " + esitoGiro(r));
      caricaClub();
    } catch (e) { errore(e); }
    this.disabled = false;
  });
  function esitoGiro(r) {
    return r.compleanni + (r.compleanni === 1 ? " compleanno, " : " compleanni, ") + r.offerte + (r.offerte === 1 ? " offerta" : " offerte");
  }
  const ICONA_AVVISO = { compleanno: "🎂", promo: "💌", benvenuto: "👋", codice: "🔑", prova: "🔔" };
  function esitoAvviso(m) {
    if (!m.inviato) return "in coda";
    if (!m.esito) return "in invio…";
    const parti = [];
    if (m.esito.push > 0) parti.push("🔔 arrivato su " + m.esito.push + (m.esito.push === 1 ? " telefono" : " telefoni"));
    else if (m.tipo !== "codice" && m.tipo !== "benvenuto") parti.push("🔔 nessun telefono");
    if (m.esito.email && m.esito.email !== "no") parti.push("📧 " + m.esito.email);
    return parti.join(" · ");
  }
  async function caricaMessaggi() {
    try {
      const lista = await conPin(S.clubMessaggi);
      $("#cl-messaggi").innerHTML = lista.length ? lista.map(function (m) {
        return '<li><span style="font-size:1.3rem">' + (ICONA_AVVISO[m.tipo] || "📨") + "</span>" +
          '<div class="cresce"><b>' + C.esc(m.nome) + '</b> <span class="muted small">' + C.esc(m.titolo) + "</span>" +
          '<div class="dim">' + C.dataBreve(C.sera(m.creato)) + " alle " + C.ora(m.creato) + " · " + C.esc(esitoAvviso(m)) + "</div></div></li>";
      }).join("") : '<li class="vuoto">Ancora nessun avviso.</li>';
    } catch (e) { errore(e); }
  }

  let timerCerca = null;
  $("#cl-cerca").addEventListener("input", function () {
    clearTimeout(timerCerca);
    timerCerca = setTimeout(cercaIscritti, 250);
  });
  async function cercaIscritti() {
    const box = $("#cl-lista");
    try {
      const lista = await conPin(function (p) { return S.clubElenco(p, $("#cl-cerca").value); });
      box.innerHTML = lista.length ? lista.map(function (i) {
        return '<li data-iscritto="' + C.esc(i.id) + '" style="cursor:pointer"><div class="cresce"><b>' + C.esc(i.nome) + "</b>" +
          '<div class="dim">' + C.esc(telBello(i.telefono)) + " · dal " + C.dataBreve(C.sera(i.creato)) + "</div></div>" +
          (i.premi ? '<span class="pill oro">🎁 ' + i.premi + "</span>" : "") + "</li>";
      }).join("") : '<li class="vuoto">' + ($("#cl-cerca").value.trim() ? "Nessuno con questo nome." : "Ancora nessun iscritto: arriveranno dal menu.") + "</li>";
      $$("[data-iscritto]", box).forEach(function (li) {
        li.addEventListener("click", function () { apriIscritto(li.dataset.iscritto); });
      });
    } catch (e) { errore(e); }
  }

  const STATO_CLUB = {
    valido: ["ok", "da usare"], presto: ["oro", "dalla prossima visita"], oggi_no: ["oro", "da usare"],
    usato: ["", "usato"], scaduto: ["no", "scaduto"],
  };
  async function apriIscritto(id) {
    let i;
    try { i = await conPin(function (p) { return S.clubDettaglio(p, id); }); }
    catch (e) { errore(e); return; }
    const nome1 = i.nome.split(/\s+/)[0];
    const oggi = C.sera();
    apriFoglio(
      "<h2>" + C.esc(i.nome) + "</h2>" +
      '<p class="dim">Nel Club dal ' + C.dataBreve(C.sera(i.creato)) + "</p>" +
      '<ul class="lista" style="margin-top:8px">' +
      '<li><span class="cresce">📞 ' + C.esc(telBello(i.telefono)) + "</span>" +
        '<a class="btn vuoto piccolo" target="_blank" rel="noopener" href="' + linkChat(i.telefono, "Ciao " + nome1 + "!") + '">💬</a>' +
        '<a class="btn vuoto piccolo" href="tel:' + C.esc(i.telefono) + '">Chiama</a></li>' +
      '<li><span class="cresce">✉️ <a href="mailto:' + C.esc(i.email) + '">' + C.esc(i.email) + "</a></span></li>" +
      '<li><span class="cresce">🎂 ' + C.esc(C.dataBreve(i.nascita).replace(/^\S+ /, "")) + " " + i.nascita.slice(0, 4) +
        " · " + eta(i.nascita, oggi) + " anni</span></li>" +
      '<li><span class="cresce">📣 Offerte: ' + (i.promo ? "<b>sì</b>" : "no") + "</span></li>" +
      '<li><span class="cresce">🔔 Avvisi: ' + (i.notifiche > 0 ? "<b>accesi</b> su " + i.notifiche + (i.notifiche === 1 ? " telefono" : " telefoni") : "spenti") +
        (i.emailConfermata ? " · 📧 email confermata" : "") + "</span>" +
        (i.notifiche > 0 ? '<button class="btn vuoto piccolo fisso" id="cl-prova">Prova</button>' : "") + "</li></ul>" +

      '<div class="card"><h3>🎁 Premi</h3><ul class="lista">' +
      (i.premi.length ? i.premi.map(function (p) {
        const st = STATO_CLUB[p.stato] || ["", p.stato];
        return '<li data-premio="' + C.esc(p.codice) + '" style="cursor:pointer"><span style="font-size:1.4rem">' + C.esc(p.emoji) + "</span>" +
          '<div class="cresce"><b>' + C.esc(p.nome.it) + '</b><div class="dim">' + (TIPO_CLUB[p.tipo] || "") + perChi(p.persone, " · ") +
          " · " + (p.usato ? "usato " + quando(p.usato) : "dal " + C.dataBreve(p.dal) + " al " + C.dataBreve(p.al)) + "</div></div>" +
          '<span class="pill ' + st[0] + '">' + st[1] + "</span></li>";
      }).join("") : '<li class="vuoto">Nessun premio.</li>') + "</ul></div>" +

      '<div class="card"><h3>📲 Riapri il Club sul suo telefono</h3>' +
      '<p class="dim">Se ha cambiato telefono o ha cancellato i dati del browser: fagli inquadrare questo QR con la fotocamera e ritrova la sua tessera con i premi. È personale: non darlo ad altri.</p>' +
      '<div class="qr" style="width:170px;margin:12px auto">' + C.disegnaQR(C.urlMenuClub(i.chiave)) + "</div></div>" +

      '<button class="btn vuoto pieno" id="cl-elimina" style="color:var(--danger);border-color:rgba(255,107,94,.45)">🗑 Elimina dal Club</button>'
    );
    $$("[data-premio]", $("#foglio-corpo")).forEach(function (li) {
      li.addEventListener("click", function () { chiudiFoglio(); vai("riscatta"); cercaClub(li.dataset.premio); });
    });
    const prova = $("#cl-prova");
    if (prova) prova.addEventListener("click", async function () {
      prova.disabled = true;
      try {
        await conPin(function (p) { return S.clubProvaAvviso(p, id); });
        await S.clubInvia();
        C.toast("Avviso di prova mandato a " + i.nome + ": guarda il suo telefono");
        caricaMessaggi();
      } catch (e) { errore(e); }
      prova.disabled = false;
    });
    $("#cl-elimina").addEventListener("click", async function () {
      if (!confirm("Elimino " + i.nome + " dal Club? Si cancellano i suoi dati e i suoi premi. Non si può tornare indietro.")) return;
      try {
        await conPin(function (p) { return S.clubElimina(p, id); });
        chiudiFoglio();
        C.toast(i.nome + " eliminato dal Club");
        caricaClub();
      } catch (e) { errore(e); }
    });
  }

  // giorni della settimana da lunedì a domenica (0 = domenica), accesi = "on"
  function chipGiorni(box, accesi) {
    box.innerHTML = [1, 2, 3, 4, 5, 6, 0].map(function (g) {
      return '<button type="button" data-g="' + g + '" class="' + (accesi.indexOf(g) >= 0 ? "on" : "") + '">' +
        C.NOMI_GIORNI[g].slice(0, 3) + "</button>";
    }).join("");
  }
  function giorniAccesi(box) { return $$("button.on", box).map(function (b) { return Number(b.dataset.g); }); }
  [$("#cl-giorni-no"), $("#cl-giorni-chiusura")].forEach(function (box) {
    box.addEventListener("click", function (e) { if (e.target.dataset.g != null) e.target.classList.toggle("on"); });
  });
  $("#cl-salva").addEventListener("click", async function () {
    try {
      await conPin(function (p) {
        return S.clubSalvaImpostazioni(p, {
          emoji: $("#cl-emoji").value, nome: { it: $("#cl-nome").value, en: $("#cl-nome-en").value },
          persone: $("#cl-persone").value, sere: $("#cl-sere").value,
          giorniNo: giorniAccesi($("#cl-giorni-no")), giorniChiusura: giorniAccesi($("#cl-giorni-chiusura")),
        });
      });
      C.toast("Salvato: vale per i prossimi iscritti");
      caricaClub();
    } catch (e) { errore(e); }
  });

  /* ================= PRENOTA ================= */

  const FONTI = { sito: "🌐 sito", telefono: "📞 telefono", thefork: "🍴 TheFork", google: "🔎 Google", altro: "✍️ altro" };
  // il WhatsApp di conferma: consegnato = il numero è giusto (e vale il prosecco di benvenuto)
  const WA = { in_coda: "📲 WhatsApp in invio", inviato: "📲 WhatsApp inviato, non ancora consegnato",
               consegnato: "✅ WhatsApp consegnato: numero verificato", letto: "✅ WhatsApp letto: numero verificato",
               errore: "⚠️ WhatsApp non arrivato: numero da controllare" };
  const WA_BREVE = { in_coda: "📲", inviato: "📲", consegnato: "✅ verificato", letto: "✅ verificato", errore: "⚠️ numero?" };
  const STATO_PREN = {
    confermata: ["ok", "confermata"], arrivati: ["oro", "arrivati"], noshow: ["no", "non venuti"], annullata: ["no", "annullata"],
  };
  let prSera = null;    // la sera che si sta guardando; null = oggi
  let prDati = null;    // l'ultima sera caricata
  let prImp = null;     // impostazioni delle prenotazioni
  let prChiuse = [];    // sere chiuse in più, mentre si modificano

  // per le prenotazioni conta il giorno di calendario a Firenze (a mezzanotte e mezza è già "domani")
  function oggiCalendario() { return C.sera(Date.now() + 6 * 3600e3); }
  function nomeGiorno(s) {
    const o = oggiCalendario();
    return s === o ? "Oggi" : s === C.piuGiorni(o, 1) ? "Domani" : C.dataBreve(s);
  }

  function caricaPrenota() {
    caricaSeraPren();
    caricaImpostazioniPren();
    caricaAsporto();
    caricaWhatsapp();
    aggiornaNovita();
  }

  /* --- le novità: prenotazioni nuove, annullate dal cliente, messaggi WhatsApp ---
     Finché non vengono guardate l'icona Prenota è accesa e salta, con il numero sopra.
     Si controlla ogni 30 secondi (solo a dashboard aperta) e quando si torna sull'app. */
  let novitaPrima = null;   // quante erano al controllo prima (null = primo controllo: niente avviso)
  let novitaAvviata = false;
  function avviaNovita() {
    aggiornaNovita();
    if (novitaAvviata) return;
    novitaAvviata = true;
    setInterval(function () { if (!document.hidden) aggiornaNovita(); }, 30000);
    document.addEventListener("visibilitychange", function () { if (!document.hidden) aggiornaNovita(); });
  }
  async function aggiornaNovita() {
    if (!pin) return;
    let n;
    try { n = await S.prenNovita(pin); } catch (e) { return; }   // senza rete si riprova al giro dopo
    segnaNovita(n.totale);
    disegnaNovita(n);
    if (novitaPrima !== null && n.totale > novitaPrima && n.lista.length) {
      if (navigator.vibrate) navigator.vibrate([200, 100, 200]);
      C.toast(n.lista[0].titolo);
      if (schedaAttiva === "prenota") caricaSeraPren();
    }
    novitaPrima = n.totale;
  }
  function segnaNovita(n) {
    const b = $('.tabbar [data-vai="prenota"]');
    b.classList.toggle("salta", n > 0);
    if (n > 0) b.dataset.badge = n > 99 ? "99+" : n; else delete b.dataset.badge;
    // il numerino anche sull'icona dell'app, sulla schermata Home
    try {
      const fatto = n > 0 ? navigator.setAppBadge && navigator.setAppBadge(n) : navigator.clearAppBadge && navigator.clearAppBadge();
      if (fatto) fatto.catch(function () {});
    } catch (e) {}
  }
  function disegnaNovita(n) {
    $("#pr-novita").hidden = !n.totale;
    $("#pr-novita-titolo").textContent = "🔔 Novità da guardare · " + n.totale;
    $("#pr-novita-lista").innerHTML = n.lista.map(function (a) {
      const giorno = a.sera ? C.esc(nomeGiorno(a.sera)) + (nomeGiorno(a.sera) === C.dataBreve(a.sera) ? "" : " " + C.dataBreve(a.sera)) + " alle " + C.esc(a.turno) : "";
      return '<li data-avviso="' + C.esc(a.id) + '" data-pren="' + C.esc(a.prenotazione || "") + '" data-sera="' + C.esc(a.sera || "") + '">' +
        '<div class="cresce"><b>' + C.esc(a.titolo) + (a.tipo === "whatsapp" ? "" : " · " + C.esc(a.nome)) + "</b>" +
        (a.testo ? '<div class="msg-riga">«' + C.esc(a.testo) + "»</div>" : "") +
        '<div class="dim">' + (giorno ? giorno + (a.persone ? " · " + persone(a.persone) : "") + " · " : "") + (a.tipo === "whatsapp" ? "arrivato " : "arrivata ") + quando(a.quando) + "</div></div>" +
        '<span class="fisso muted">›</span></li>';
    }).join("");
  }
  $("#pr-novita-lista").addEventListener("click", async function (e) {
    const li = e.target.closest("[data-avviso]");
    if (!li) return;
    if (!li.dataset.pren) { apriMessaggiWa(); return; }     // un messaggio senza prenotazione
    prSera = li.dataset.sera;
    await caricaSeraPren();
    apriPrenotazione(li.dataset.pren);
  });
  $("#pr-novita-viste").addEventListener("click", async function () {
    try {
      await conPin(function (p) { return S.prenVisto(p, null); });
      aggiornaNovita();
      caricaSeraPren();
      caricaWhatsapp();
    } catch (e) { errore(e); }
  });

  /* --- WhatsApp di conferma delle prenotazioni (e prosecco di benvenuto) --- */
  async function caricaWhatsapp() {
    try {
      const w = await conPin(S.waImpostazioni);
      $("#wa-attivo").checked = w.attivo;
      $("#wa-benvenuto").value = w.benvenutoMax;
      $("#wa-numero").value = w.numeroId || "";
      $("#wa-modello-nuovo").value = w.modelloNuovo;
      $("#wa-modello").value = w.modello;
      $("#wa-modello-voto").value = w.modelloVoto || "";
      $("#wa-recensioni").value = w.linkRecensioni || "";
      $("#wa-club-ore").value = w.clubDopoOre;
      $("#wa-voto-ora").value = w.votoOra || "";
      $("#wa-inglese").checked = !!w.inglese;
      $("#wa-messaggi").textContent = "💬 Messaggi ricevuti" + (w.nonLetti ? " · " + w.nonLetti + " nuovi" : "");
      const s = w.settimana || {};
      $("#wa-stato").innerHTML = !w.configurato ? "⚙️ Da collegare con Meta: finché è spento, il prosecco si vede sulla conferma del sito."
        : !w.attivo ? "Spento: la conferma resta solo sul sito."
        : "<b>Ultimi 7 giorni:</b> " + (s.inviati || 0) + " inviati · " + (s.verificati || 0) + " verificati · " +
          (s.attivati || 0) + " hanno risposto CIAO" + (s.voti ? " · ⭐ " + s.media + " su " + s.voti + " voti" : "") +
          (s.errori ? " · ⚠️ " + s.errori + " non arrivati" : "") +
          (w.ultimoErrore ? '<span class="dim" style="display:block">Ultimo errore: ' + C.esc(w.ultimoErrore) + "</span>" : "");
    } catch (e) { errore(e); }
  }
  $("#wa-salva").addEventListener("click", async function () {
    try {
      await conPin(function (p) {
        return S.waSalva(p, { numeroId: $("#wa-numero").value.trim(), modelloNuovo: $("#wa-modello-nuovo").value.trim(),
          modello: $("#wa-modello").value.trim(), modelloVoto: $("#wa-modello-voto").value.trim(),
          benvenutoMax: Number($("#wa-benvenuto").value), linkRecensioni: $("#wa-recensioni").value.trim(),
          clubDopoOre: Number($("#wa-club-ore").value), votoOra: $("#wa-voto-ora").value, inglese: $("#wa-inglese").checked });
      });
      C.toast("Salvato");
      caricaWhatsapp();
    } catch (e) { errore(e); }
  });
  // i messaggi dei clienti su WhatsApp: si leggono qui e, entro 24 ore dal loro ultimo messaggio, si risponde
  async function apriMessaggiWa() {
    let lista;
    try { lista = await conPin(S.waMessaggi); } catch (e) { errore(e); return; }
    apriFoglio("<h2>💬 Messaggi WhatsApp</h2>" +
      '<p class="dim small">Le risposte dei clienti al numero del Vico. Si può rispondere solo entro 24 ore dal loro ultimo messaggio.</p>' +
      (lista.length ? '<ul class="lista" style="margin-top:10px">' + lista.map(function (m) {
        return '<li style="display:block' + (m.letto ? "" : ";border-left:3px solid var(--gold);padding-left:10px") + '">' +
          "<b>" + C.esc(m.nome) + "</b>" + (m.voto ? ' <span class="pill oro">⭐ ' + m.voto + "</span>" : "") +
          ' <span class="dim small">' + quando(m.quando) + (m.sera ? " · 📅 " + C.esc(nomeGiorno(m.sera)) + " alle " + C.esc(m.turno) : "") + "</span>" +
          '<div style="margin-top:4px;white-space:pre-wrap">' + C.esc(m.testo) + "</div>" +
          (m.aperta ? '<div class="riga" style="margin-top:8px"><input type="text" class="cresce wa-risposta" maxlength="1000" placeholder="Rispondi…">' +
            '<button class="btn oro piccolo fisso" data-wa-tel="' + C.esc(m.telefono) + '" type="button">Invia</button></div>' : "") +
          "</li>";
      }).join("") + "</ul>" : '<p class="vuoto">Ancora nessun messaggio.</p>'));
    $$("[data-wa-tel]", $("#foglio-corpo")).forEach(function (b) {
      b.addEventListener("click", async function () {
        const campo = b.parentNode.querySelector(".wa-risposta");
        const testo = campo.value.trim();
        if (!testo) return;
        b.disabled = true;
        try {
          await conPin(function (p) { return S.waRispondi(p, b.dataset.waTel, testo); });
          campo.value = "";
          C.toast("Inviato");
        } catch (e) { errore(e); }
        b.disabled = false;
      });
    });
    caricaWhatsapp();
    aggiornaNovita();
    caricaSeraPren();
  }
  $("#wa-messaggi").addEventListener("click", apriMessaggiWa);
  $("#wa-attivo").addEventListener("change", async function () {
    const acceso = this.checked;
    try {
      await conPin(function (p) { return S.waSalva(p, { attivo: acceso }); });
      C.toast(acceso ? "WhatsApp di conferma acceso" : "WhatsApp di conferma spento");
      caricaWhatsapp();
    } catch (e) { this.checked = !acceso; errore(e); }
  });

  /* --- asporto: le regole, gli ordini li gestisce il Banco --- */
  async function caricaAsporto() {
    try {
      const a = await conPin(S.aspImpostazioni);
      $("#as-attive").checked = a.attive;
      $("#as-dalle").value = a.dalle;
      $("#as-alle").value = a.alle;
      $("#as-piatti").value = a.piatti;
      $("#as-passo").value = String(a.passo);
      $("#as-anticipo").value = a.anticipoMin;
      chipGiorni($("#as-giorni-no"), a.giorniNo || []);
      const s = a.stasera || {};
      $("#as-stasera").innerHTML = !a.attive ? "Asporto spento: il sito dice che stasera è chiuso."
        : !a.apertoStasera ? "Stasera niente asporto (sera esclusa)."
        : "<b>Stasera:</b> " + (s.ordini || 0) + (s.ordini === 1 ? " ordine" : " ordini") + " · " + (s.piatti || 0) + " piatti" +
          (s.incasso ? " · " + C.euro(s.incasso) : "") + (s.aperti ? " · " + s.aperti + " da preparare" : "");
    } catch (e) { errore(e); }
  }
  $("#as-giorni-no").addEventListener("click", function (e) { if (e.target.dataset.g != null) e.target.classList.toggle("on"); });

  /* --- asporto: gli ordini di una sera qualsiasi e le ultime sere (si rivedono e basta: li manda avanti il Banco) --- */
  const STATO_ASP = {
    ricevuto: ["oro", "ricevuto"], preparazione: ["oro", "in preparazione"], pronto: ["ok", "pronto"],
    ritirato: ["ok", "ritirato"], annullato: ["no", "annullato"],
  };
  function contaOrdini(n) { return n + (n === 1 ? " ordine" : " ordini"); }
  async function apriStoricoAsporto(sera) {
    let d;
    try { d = await conPin(function (p) { return S.aspStorico(p, sera); }); } catch (e) { errore(e); return; }
    const vivi = d.ordini.filter(function (o) { return o.stato !== "annullato"; });
    const piatti = vivi.reduce(function (t, o) { return t + (o.pezzi || 0); }, 0);
    const incasso = vivi.reduce(function (t, o) { return t + (Number(o.totale) || 0); }, 0);
    const annullati = d.ordini.length - vivi.length;
    const giorno = nomeGiorno(d.sera) + (nomeGiorno(d.sera) === C.dataBreve(d.sera) ? "" : " · " + C.dataBreve(d.sera));
    apriFoglio(
      "<h2>🛍️ Ordini da asporto</h2>" +
      '<div class="riga giorno-nav">' +
        '<button class="btn vuoto piccolo fisso" id="as-prima" aria-label="Sera prima">‹</button>' +
        '<label class="btn vuoto piccolo scegli-data"><span>' + C.esc(giorno) + "</span>" +
          '<input type="date" id="as-data" max="' + d.oggi + '" value="' + d.sera + '" aria-label="Scegli la sera"></label>' +
        '<button class="btn vuoto piccolo fisso" id="as-dopo" aria-label="Sera dopo"' + (d.sera >= d.oggi ? " disabled" : "") + ">›</button>" +
      "</div>" +
      '<p class="small" style="margin:10px 0">' + (d.ordini.length
        ? "<b>" + contaOrdini(vivi.length) + "</b> · " + piatti + " piatti · " + C.euro(incasso) +
          (annullati ? ' <span class="dim">· ' + annullati + (annullati === 1 ? " annullato" : " annullati") + "</span>" : "")
        : '<span class="dim">Nessun ordine da asporto in questa sera.</span>') + "</p>" +
      (d.ordini.length ? '<ul class="lista">' + d.ordini.map(function (o) {
        const st = STATO_ASP[o.stato] || ["", o.stato];
        const righe = (o.righe || []).map(function (r) { return r.qta + "× " + C.esc(r.nome) + (r.nota ? " (" + C.esc(r.nota) + ")" : ""); }).join(", ");
        return '<li class="' + (o.stato === "annullato" ? "spenta" : "") + '">' +
          '<div class="cresce"><b><span class="ora-arrivo">' + C.esc(o.ritiro) + "</span> " + C.esc(o.nome) + "</b>" +
          ' <span class="pill ' + st[0] + '">' + st[1] + "</span>" +
          '<div class="dim">' + righe + "</div>" +
          '<div class="dim">codice ' + C.esc(o.codice) + (o.socio ? " · 💳 socio" : "") +
            (o.nota ? " · «" + C.esc(o.nota) + "»" : "") + "</div></div>" +
          '<div style="text-align:right"><b>' + (o.totale != null ? C.euro(Number(o.totale)) : "") + "</b>" +
            (o.telefono ? '<a class="btn vuoto piccolo" style="display:block;margin-top:6px" href="tel:' + C.esc(o.telefono) + '">📞</a>' : "") +
          "</div></li>";
      }).join("") + "</ul>" : "") +
      '<div class="card" style="margin-top:14px"><h3>📆 Ultime sere</h3>' +
        '<p class="small"><b>Questo mese:</b> ' + contaOrdini(d.mese.ordini || 0) + " · " + C.euro(Number(d.mese.incasso) || 0) + "</p>" +
        (d.sere.length ? '<ul class="lista" id="as-sere">' + d.sere.map(function (g) {
          return '<li data-sera="' + g.sera + '" style="cursor:pointer"' + (g.sera === d.sera ? ' class="qui"' : "") + ">" +
            '<span class="cresce"><b>' + C.esc(nomeGiorno(g.sera)) + "</b>" +
            (nomeGiorno(g.sera) !== C.dataBreve(g.sera) ? ' <span class="dim">' + C.dataBreve(g.sera) + "</span>" : "") + "</span>" +
            (g.ordini ? '<span class="pill oro">' + contaOrdini(g.ordini) + " · " + C.euro(Number(g.incasso)) + "</span>"
              : '<span class="pill">' + g.annullati + (g.annullati === 1 ? " annullato" : " annullati") + "</span>") + "</li>";
        }).join("") + "</ul>" : '<p class="vuoto">Ancora nessun ordine.</p>') +
      "</div>"
    );
    $("#as-prima").addEventListener("click", function () { apriStoricoAsporto(C.piuGiorni(d.sera, -1)); });
    $("#as-dopo").addEventListener("click", function () { apriStoricoAsporto(C.piuGiorni(d.sera, 1)); });
    $("#as-data").addEventListener("change", function () { if (this.value) apriStoricoAsporto(this.value); });
    const sere = $("#as-sere");
    if (sere) sere.addEventListener("click", function (e) {
      const li = e.target.closest("[data-sera]");
      if (li) apriStoricoAsporto(li.dataset.sera);
    });
  }
  $("#as-storico").addEventListener("click", function () { apriStoricoAsporto(null); });
  $("#as-salva").addEventListener("click", async function () {
    try {
      await conPin(function (p) {
        return S.aspSalvaImpostazioni(p, {
          dalle: $("#as-dalle").value, alle: $("#as-alle").value, piatti: Number($("#as-piatti").value),
          passo: Number($("#as-passo").value), anticipoMin: Number($("#as-anticipo").value),
          giorniNo: giorniAccesi($("#as-giorni-no")),
        });
      });
      C.toast("Salvato: il menu si aggiorna da solo");
      caricaAsporto();
    } catch (e) { errore(e); }
  });
  $("#as-attive").addEventListener("change", async function () {
    const acceso = this.checked;
    try {
      await conPin(function (p) { return S.aspSalvaImpostazioni(p, { attive: acceso }); });
      C.toast(acceso ? "Asporto acceso" : "Asporto spento: nel menu si può solo sfogliare");
      caricaAsporto();
    } catch (e) { this.checked = !acceso; errore(e); }
  });

  async function caricaSeraPren() {
    try {
      const d = await conPin(function (p) { return S.prenGiorno(p, prSera); });
      prDati = d;
      prSera = d.sera;
      $("#pr-sera").textContent = nomeGiorno(d.sera) + (nomeGiorno(d.sera) === C.dataBreve(d.sera) ? "" : " · " + C.dataBreve(d.sera));
      $("#pr-data").value = d.sera;
      $("#pr-prima").disabled = d.sera <= C.piuGiorni(d.oggi, -1);
      $("#pr-chiuso").hidden = !d.chiuso;
      $("#pr-turni").innerHTML = d.turni.length ? d.turni.map(function (t) { return disegnaTurno(t, d.coperti); }).join("")
        : '<div class="card"><p class="vuoto">Nessun turno impostato.</p></div>';
      // dei prossimi 14 giorni si vedono solo quelli con almeno una prenotazione
      const conPren = d.prossimi.filter(function (g) { return g.prenotazioni > 0; });
      $("#pr-prossimi").innerHTML = conPren.length ? conPren.map(function (g) {
        return '<li data-sera="' + g.sera + '" style="cursor:pointer"' + (g.sera === d.sera ? ' class="qui"' : "") + '>' +
          '<span class="cresce"><b>' + C.esc(nomeGiorno(g.sera)) + "</b>" +
          (nomeGiorno(g.sera) !== C.dataBreve(g.sera) ? ' <span class="dim">' + C.dataBreve(g.sera) + "</span>" : "") + "</span>" +
          (g.chiuso ? '<span class="pill">chiuso</span>'
            : g.prenotazioni ? '<span class="pill oro">' + g.prenotazioni + (g.prenotazioni === 1 ? " tavolo" : " tavoli") +
              " · " + persone(g.persone) + "</span>" : '<span class="dim">—</span>') + "</li>";
      }).join("") : '<li class="vuoto">Nessuna prenotazione nei prossimi 14 giorni.</li>';
    } catch (e) { errore(e); }
  }

  // un turno = una fascia di orari di arrivo con i suoi coperti; dentro, ogni tavolo con la sua ora
  function disegnaTurno(t, coperti) {
    const pieno = Math.min(100, Math.round(100 * t.prenotati / Math.max(1, coperti)));
    return '<div class="card turno">' +
      '<div class="riga"><h3 class="cresce" style="margin:0">' +
        (t.previsto ? "🕢 " + (t.numero ? t.numero + "° turno · " : "") + C.esc(t.ora) : "🕘 Altri orari") + "</h3>" +
      (t.previsto ? '<span class="pill ' + (t.prenotati >= coperti ? "no" : "oro") + '">' + t.prenotati + " / " + coperti + " coperti</span>"
        : '<span class="pill">' + persone(t.prenotati) + "</span>") + "</div>" +
      (t.previsto ? '<div class="barra-coperti"><i style="width:' + pieno + '%"></i></div>' : "") +
      '<ul class="lista">' + (t.lista.length ? t.lista.map(function (x) {
        const st = STATO_PREN[x.stato] || ["", x.stato];
        const nov = x.novita || {};
        const suoi = (x.conversazione || []).filter(function (m) { return m.da === "cliente"; });
        const ultimo = suoi[suoi.length - 1];
        return '<li data-pren="' + C.esc(x.id) + '" class="' + (x.stato === "annullata" ? "spenta" : "") +
          (nov.nuova || nov.annullata || nov.messaggi ? " pren-nuova" : "") + '" style="cursor:pointer">' +
          '<span class="persone-tondo">' + x.persone + "</span>" +
          '<div class="cresce"><b><span class="ora-arrivo">' + C.esc(x.turno) + "</span> " + C.esc(x.nome) + "</b>" +
          '<div class="dim">' + (FONTI[x.fonte] || C.esc(x.fonte)) + (x.socio ? " · 💳 socio" : "") +
          (x.benvenuto ? " · 🥂 prosecco per " + x.benvenuto + (x.waAttivato ? " attivato" : x.whatsapp ? " (attende il CIAO)" : "") : "") +
          (x.regalo ? " · " + C.esc(x.regalo.emoji) + " regalo" + (x.regalo.usato ? " usato" : "") : "") +
          (x.whatsapp ? " · " + (WA_BREVE[x.whatsapp] || "") : "") + (x.voto ? " · ⭐ " + x.voto : "") +
          (x.nota ? " · «" + C.esc(x.nota) + "»" : "") + "</div>" +
          (ultimo ? '<div class="msg-riga">💬 «' + C.esc(ultimo.testo) + "»</div>" : "") + "</div>" +
          (nov.nuova ? '<span class="pill nuova">NUOVA</span>' : "") +
          (nov.messaggi ? '<span class="pill nuova">💬 ' + nov.messaggi + "</span>" : "") +
          (x.stato === "confermata" ? "" : '<span class="pill ' + st[0] + '">' + st[1] + "</span>") + "</li>";
      }).join("") : '<li class="vuoto">Nessuna prenotazione.</li>') + "</ul></div>";
  }

  $("#pr-turni").addEventListener("click", function (e) {
    const li = e.target.closest("[data-pren]");
    if (li) apriPrenotazione(li.dataset.pren);
  });
  $("#pr-prossimi").addEventListener("click", function (e) {
    const li = e.target.closest("[data-sera]");
    if (!li) return;
    prSera = li.dataset.sera;
    caricaSeraPren();
    window.scrollTo({ top: 0, behavior: "smooth" });
  });
  $("#pr-prima").addEventListener("click", function () { prSera = C.piuGiorni(prSera || oggiCalendario(), -1); caricaSeraPren(); });
  $("#pr-dopo").addEventListener("click", function () { prSera = C.piuGiorni(prSera || oggiCalendario(), 1); caricaSeraPren(); });
  $("#pr-data").addEventListener("change", function () { if (this.value) { prSera = this.value; caricaSeraPren(); } });

  function trovaPrenotazione(id) {
    for (const t of (prDati ? prDati.turni : [])) {
      const x = t.lista.find(function (p) { return p.id === id; });
      if (x) return x;
    }
    return null;
  }

  // la conversazione su WhatsApp con il cliente: in cima alla scheda, e si risponde da lì
  function htmlConversazione(x) {
    const conv = x.conversazione || [];
    if (!conv.length && !x.finestra) return "";
    return '<div class="card conv" id="pr-conv"><h3>' + (conv.length ? "💬 Messaggi del cliente" : "💬 Scrivi al cliente") + "</h3>" +
      conv.map(function (m) {
        return '<div class="bolla ' + (m.da === "cliente" ? "sua" : "mia") + (m.da === "cliente" && !m.letto ? " nuova" : "") + '">' + C.esc(m.testo) +
          "<small>" + (m.da === "cliente" ? "" : "tu · ") + quando(m.quando) + (m.stato === "errore" ? " · ⚠️ non arrivato" : "") + "</small></div>";
      }).join("") +
      (x.finestra && x.telefono
        ? '<div class="riga" style="margin-top:10px"><input type="text" id="pr-conv-testo" maxlength="1000" placeholder="Rispondi su WhatsApp…">' +
          '<button class="btn oro piccolo fisso" id="pr-conv-invia" type="button">Invia</button></div>'
        : '<p class="dim small" style="margin-top:8px">Sono passate più di 24 ore dal suo ultimo messaggio: WhatsApp non lascia più rispondere dal numero del Vico. Usa il tasto 📱 qui sotto o chiamalo.</p>') +
      "</div>";
  }
  function legaConversazione(x) {
    const invia = $("#pr-conv-invia");
    if (!invia) return;
    invia.addEventListener("click", async function () {
      const testo = $("#pr-conv-testo").value.trim();
      if (!testo) return;
      invia.disabled = true;
      try {
        await conPin(function (p) { return S.waRispondi(p, x.telefono, testo); });
        C.toast("Inviato");
        x.conversazione = (x.conversazione || []).map(function (m) { return Object.assign({}, m, { letto: true }); })
          .concat([{ da: "titolare", testo: testo, quando: Date.now(), letto: true, stato: "in_coda" }]);
        $("#pr-conv").outerHTML = htmlConversazione(x);
        legaConversazione(x);
      } catch (e) { invia.disabled = false; errore(e); }
    });
  }

  function apriPrenotazione(id) {
    const x = trovaPrenotazione(id);
    if (!x) return;
    const nome1 = x.nome.split(/\s+/)[0];
    const st = STATO_PREN[x.stato] || ["", x.stato];
    const azioni = {
      confermata: [["arrivati", "✅ Sono arrivati", "verde"], ["noshow", "🚫 Non sono venuti", "vuoto"], ["annullata", "❌ Annulla", "vuoto"]],
      arrivati: [["confermata", "↺ Non ancora arrivati", "vuoto"]],
      noshow: [["arrivati", "✅ Sono arrivati", "verde"], ["confermata", "↺ Rimetti confermata", "vuoto"]],
      annullata: [["confermata", "↺ Rimetti confermata", "vuoto"]],
    }[x.stato] || [];
    apriFoglio(
      "<h2>" + C.esc(x.nome) + "</h2>" +
      '<p class="dim">' + C.esc(nomeGiorno(x.sera)) + (nomeGiorno(x.sera) !== C.dataBreve(x.sera) ? " " + C.dataBreve(x.sera) : "") +
        " alle " + C.esc(x.turno) + " · " + persone(x.persone) + ' · <span class="pill ' + st[0] + '">' + st[1] + "</span></p>" +
      htmlConversazione(x) +
      '<ul class="lista" style="margin-top:8px">' +
      // il tasto del messaggio fa due cose: se il cliente ha scritto nelle ultime 24 ore si risponde
      // da qui, dal numero del Vico; altrimenti WhatsApp non lo permette e si apre quello di questo telefono
      (x.telefono ? '<li><span class="cresce">📞 ' + C.esc(telBello(x.telefono)) +
        '<span class="dim small" style="display:block">' + (x.finestra
          ? "💬 Ti ha scritto nelle ultime 24 ore: il messaggio parte dal " + C.esc(telBello("+" + C.RISTORANTE.whatsapp))
          : "📱 Non ti ha scritto nelle ultime 24 ore: il messaggio parte dal WhatsApp di questo telefono") + "</span></span>" +
        (x.finestra
          ? '<button class="btn oro piccolo" id="pr-scrivi" type="button" aria-label="Scrivi dal numero del Vico">💬</button>'
          : '<a class="btn vuoto piccolo" target="_blank" rel="noopener" aria-label="Scrivi dal WhatsApp di questo telefono" href="' + linkChat(x.telefono, "Ciao " + nome1 + "!") + '">📱</a>') +
        '<a class="btn vuoto piccolo" href="tel:' + C.esc(x.telefono) + '">Chiama</a></li>' : "") +
      (x.benvenuto ? '<li><span class="cresce">🥂 Cliente nuovo: prosecco di benvenuto per ' + persone(x.benvenuto) +
        '<span class="dim" style="display:block">' + (x.waAttivato ? "Attivato: ha risposto su WhatsApp " + quando(x.waAttivato)
          : x.whatsapp ? "Vale quando risponde CIAO al WhatsApp di conferma" : "Lo vede sulla conferma del sito") + "</span></span></li>" : "") +
      (x.regalo ? '<li><span class="cresce">' + C.esc(x.regalo.emoji) + " Regalo a sorpresa: " + C.esc(x.regalo.nome.it) +
        '<span class="dim" style="display:block">' + (x.regalo.usato ? "Già usato " + quando(x.regalo.usato)
          : "Codice " + codiceClub(x.regalo.codice) + " · si usa come i premi del Club") + "</span></span>" +
        (x.regalo.usato ? "" : '<button class="btn oro piccolo" data-azione="regalo" data-codice="' + C.esc(x.regalo.codice) + '">Apri</button>') +
        "</li>" : "") +
      (x.voto ? '<li><span class="cresce">⭐ Voto alla serata: ' + x.voto + " su 5</span></li>" : "") +
      (x.whatsapp ? '<li><span class="cresce">' + (WA[x.whatsapp] || C.esc(x.whatsapp)) +
        (x.waErrore ? '<span class="dim" style="display:block">' + C.esc(x.waErrore) + "</span>" : "") + "</span></li>" : "") +
      '<li><span class="cresce">' + (FONTI[x.fonte] || C.esc(x.fonte)) + (x.socio ? " · 💳 socio del Club" : "") +
        '<span class="dim" style="display:block">codice ' + C.esc(x.codice) + " · presa " + quando(x.creato) +
        (x.annullata ? " · annullata " + quando(x.annullata) + (x.annullataDa === "cliente" ? " dal cliente" : "") : "") + "</span></span></li>" +
      "</ul>" +
      '<div class="azioni-pren">' + azioni.map(function (a) {
        return '<button class="btn ' + a[2] + ' pieno" data-stato="' + a[0] + '">' + a[1] + "</button>";
      }).join("") + "</div>" +
      '<div class="card"><h3>✏️ Modifica</h3>' +
      '<div class="riga">' +
        '<label class="campo"><span>Persone</span><input type="number" inputmode="numeric" id="pm-persone" min="1" max="200" value="' + x.persone + '"></label>' +
        '<label class="campo"><span>Ora di arrivo</span><input type="time" id="pm-turno" value="' + C.esc(x.turno) + '"></label></div>' +
      '<label class="campo"><span>Sera</span><input type="date" id="pm-sera" value="' + x.sera + '"></label>' +
      '<label class="campo"><span>Nota</span><textarea id="pm-nota" rows="2" maxlength="300">' + C.esc(x.nota) + "</textarea></label>" +
      '<button class="btn oro pieno" id="pm-salva">Salva le modifiche</button></div>'
    );
    legaConversazione(x);
    const scrivi = $("#pr-scrivi");
    if (scrivi) scrivi.addEventListener("click", function () {
      const campo = $("#pr-conv-testo");
      campo.scrollIntoView({ block: "center" });
      campo.focus();
    });
    // aperta = vista: l'icona Prenota si calma (e i messaggi risultano letti)
    const nov = x.novita || {};
    if (nov.nuova || nov.annullata || nov.messaggi) {
      x.novita = {};
      S.prenVisto(pin, x.id).then(function () { aggiornaNovita(); caricaSeraPren(); }).catch(function () {});
    }
    $$("[data-stato]", $("#foglio-corpo")).forEach(function (b) {
      b.addEventListener("click", async function () {
        const stato = b.dataset.stato;
        if (stato === "annullata" && !confirm("Annullo la prenotazione di " + x.nome + "? Il posto torna libero sul sito.")) return;
        await modificaPren(x, { stato: stato }, { arrivati: "Segnati come arrivati", noshow: "Segnati come non venuti",
          annullata: "Prenotazione annullata", confermata: "Di nuovo confermata" }[stato]);
      });
    });
    $("#pm-salva").addEventListener("click", function () {
      modificaPren(x, { persone: $("#pm-persone").value, turno: $("#pm-turno").value, sera: $("#pm-sera").value,
        nota: $("#pm-nota").value }, "Prenotazione aggiornata");
    });
    // il regalo della campagna si usa dalla pagina "Riscatta", come i premi del Club
    const bRegalo = $('[data-azione="regalo"]', $("#foglio-corpo"));
    if (bRegalo) bRegalo.addEventListener("click", function () {
      chiudiFoglio();
      vai("riscatta");
      cercaClub(bRegalo.dataset.codice);
    });
  }

  async function modificaPren(x, dati, messaggio) {
    try {
      await conPin(function (p) { return S.prenModifica(p, x.id, dati); });
      chiudiFoglio();
      C.toast(messaggio);
      caricaSeraPren();
    } catch (e) { errore(e); }
  }

  $("#pr-nuova").addEventListener("click", function () {
    const turni = (prImp && prImp.orari) || ["19:00", "19:30", "20:00", "20:30", "21:00", "21:30", "22:00", "22:30"];
    apriFoglio(
      "<h2>＋ Nuova prenotazione</h2>" +
      '<p class="dim">Per quelle arrivate al telefono, da TheFork o da Google: così i coperti sul sito tornano giusti.</p>' +
      '<label class="campo"><span>Da dove arriva</span><select id="pn-fonte">' +
        '<option value="telefono">📞 Telefono</option><option value="thefork">🍴 TheFork</option>' +
        '<option value="google">🔎 Google</option><option value="altro">✍️ Altro</option></select></label>' +
      '<label class="campo"><span>Sera</span><input type="date" id="pn-sera" value="' + (prSera || oggiCalendario()) + '"></label>' +
      '<p class="muted small">Ora di arrivo</p><div class="turni-scelta" id="pn-turni">' +
        turni.map(function (t, i) { return '<button type="button" data-ora="' + t + '" class="' + (i ? "" : "on") + '">' + t + "</button>"; }).join("") +
        '<input type="time" id="pn-altro" aria-label="Altro orario"></div>' +
      '<div class="riga">' +
        '<label class="campo"><span>Persone</span><input type="number" inputmode="numeric" id="pn-persone" min="1" max="200" value="2"></label>' +
        '<label class="campo"><span>Telefono (se c\'è)</span><input type="tel" id="pn-telefono" autocomplete="off"></label></div>' +
      '<label class="campo"><span>Nome</span><input type="text" id="pn-nome" autocomplete="off" maxlength="60"></label>' +
      '<label class="campo"><span>Nota</span><textarea id="pn-nota" rows="2" maxlength="300" placeholder="allergie, seggiolone, compleanno…"></textarea></label>' +
      '<button class="btn oro pieno" id="pn-salva">Aggiungi</button>'
    );
    const box = $("#pn-turni");
    box.addEventListener("click", function (e) {
      if (e.target.dataset.ora == null) return;
      $$("button", box).forEach(function (b) { b.classList.toggle("on", b === e.target); });
      $("#pn-altro").value = "";
    });
    $("#pn-altro").addEventListener("input", function () { $$("button", box).forEach(function (b) { b.classList.remove("on"); }); });
    $("#pn-salva").addEventListener("click", async function () {
      const scelto = $("button.on", box);
      const dati = {
        fonte: $("#pn-fonte").value, sera: $("#pn-sera").value, turno: $("#pn-altro").value || (scelto && scelto.dataset.ora) || "",
        persone: $("#pn-persone").value, telefono: $("#pn-telefono").value, nome: $("#pn-nome").value, nota: $("#pn-nota").value,
      };
      // fuori dai coperti del turno: si può, ma meglio saperlo
      if (prDati && dati.sera === prDati.sera) {
        const t = prDati.turni.find(function (x) { return x.previsto && dati.turno >= x.dalle && dati.turno <= x.alle; });
        const dopo = t ? t.prenotati + Number(dati.persone || 0) : 0;
        if (t && dopo > prDati.coperti && !confirm("Con questa il " + t.numero + "° turno (" + t.ora + ") arriva a " + dopo +
            " coperti su " + prDati.coperti + ". La aggiungo lo stesso?")) return;
      }
      try {
        await conPin(function (p) { return S.prenAggiungi(p, dati); });
        chiudiFoglio();
        C.toast("Prenotazione aggiunta");
        prSera = dati.sera;
        caricaSeraPren();
      } catch (e) { errore(e); }
    });
  });

  /* --- impostazioni --- */
  async function caricaImpostazioniPren() {
    try {
      prImp = await conPin(S.prenImpostazioni);
      $("#pr-attive").checked = prImp.attive;
      $("#pr-fasce").innerHTML = prImp.fasce.map(rigaFascia).join("");
      $("#pr-passo").value = String(prImp.passo);
      anteprimaOrari();
      $("#pr-coperti").value = prImp.coperti;
      $("#pr-max").value = prImp.maxPersone;
      $("#pr-avanti").value = prImp.giorniAvanti;
      $("#pr-anticipo").value = prImp.anticipoMin / 60;
      prChiuse = prImp.dateChiuse.slice();
      disegnaChiuse();
      const gc = prImp.giorniChiusura || [];
      $("#pr-giorno-chiusura").textContent = gc.length
        ? "Chiuso ogni " + gc.map(function (g) { return C.NOMI_GIORNI[g]; }).join(" e ") + ": si cambia nella scheda Club."
        : "Giorno di chiusura settimanale: nessuno (si imposta nella scheda Club).";
      statoAvvisiPren();
    } catch (e) { errore(e); }
  }
  // un turno = arrivi "dalle"–"alle"; il numero (1°, 2°…) segue l'ordine
  function rigaFascia(f) {
    return '<div class="fascia"><span class="fascia-n"></span>' +
      '<input type="time" class="f-dalle" value="' + C.esc(f.dalle) + '" aria-label="Arrivi dalle">' +
      '<span class="fascia-tratto">–</span>' +
      '<input type="time" class="f-alle" value="' + C.esc(f.alle) + '" aria-label="Arrivi fino alle">' +
      '<button type="button" class="togli" aria-label="Togli questo turno">×</button></div>';
  }
  function fasceScritte() {
    return $$("#pr-fasce .fascia").map(function (r) { return { dalle: $(".f-dalle", r).value, alle: $(".f-alle", r).value }; });
  }
  // "il cliente vede: 19:00 19:30 20:00 20:30 · 21:00 …" (come pren_orari nel database)
  function anteprimaOrari() {
    $$("#pr-fasce .fascia-n").forEach(function (n, i) { n.textContent = (i + 1) + "°"; });
    const passo = Number($("#pr-passo").value) || 30;
    const min = function (t) { const p = t.split(":"); return +p[0] * 60 + +p[1]; };
    const hhmm = function (m) { return String(Math.floor(m / 60)).padStart(2, "0") + ":" + String(m % 60).padStart(2, "0"); };
    const gruppi = fasceScritte().filter(function (f) { return f.dalle && f.alle && f.dalle <= f.alle; })
      .sort(function (a, b) { return a.dalle < b.dalle ? -1 : 1; })
      .map(function (f) {
        const l = [];
        for (let m = min(f.dalle); m <= min(f.alle) && l.length < 40; m += passo) l.push(hhmm(m));
        return l.join(" ");
      });
    $("#pr-orari-anteprima").textContent = gruppi.length ? "Il cliente può scegliere: " + gruppi.join("  ·  ") : "";
  }
  $("#pr-fascia-piu").addEventListener("click", function () {
    if ($$("#pr-fasce .fascia").length >= 4) { C.toast("Al massimo 4 turni", true); return; }
    $("#pr-fasce").insertAdjacentHTML("beforeend", rigaFascia({ dalle: "23:00", alle: "23:30" }));
    anteprimaOrari();
  });
  $("#pr-fasce").addEventListener("click", function (e) {
    if (!e.target.classList.contains("togli")) return;
    if ($$("#pr-fasce .fascia").length <= 1) { C.toast("Serve almeno un turno", true); return; }
    e.target.closest(".fascia").remove();
    anteprimaOrari();
  });
  $("#pr-fasce").addEventListener("input", anteprimaOrari);
  $("#pr-passo").addEventListener("change", anteprimaOrari);
  function disegnaChiuse() {
    $("#pr-chiuse").innerHTML = prChiuse.length ? prChiuse.map(function (d) {
      return '<li><span class="cresce">🔒 ' + C.esc(nomeGiorno(d)) + (nomeGiorno(d) !== C.dataBreve(d) ? " " + C.dataBreve(d) : "") + "</span>" +
        '<button type="button" class="btn vuoto piccolo fisso" data-riapri="' + d + '">Riapri</button></li>';
    }).join("") : "";
  }
  $("#pr-chiusa-piu").addEventListener("click", function () {
    const d = $("#pr-chiusa-data").value;
    if (!d) { C.toast("Scegli la sera da chiudere", true); return; }
    if (d < oggiCalendario()) { C.toast("Quella sera è già passata", true); return; }
    if (prChiuse.indexOf(d) < 0) prChiuse.push(d);
    prChiuse.sort();
    $("#pr-chiusa-data").value = "";
    disegnaChiuse();
  });
  $("#pr-chiuse").addEventListener("click", function (e) {
    const d = e.target.dataset.riapri;
    if (!d) return;
    prChiuse = prChiuse.filter(function (x) { return x !== d; });
    disegnaChiuse();
  });
  $("#pr-salva").addEventListener("click", async function () {
    const ore = parseFloat(String($("#pr-anticipo").value).replace(",", "."));
    try {
      prImp = await conPin(function (p) {
        return S.prenSalvaImpostazioni(p, {
          attive: $("#pr-attive").checked,
          fasce: fasceScritte(), passo: Number($("#pr-passo").value),
          coperti: Number($("#pr-coperti").value), maxPersone: Number($("#pr-max").value),
          giorniAvanti: Number($("#pr-avanti").value), anticipoMin: isNaN(ore) ? null : Math.round(ore * 60),
          dateChiuse: prChiuse,
        });
      });
      C.toast("Salvato: il sito si aggiorna da solo");
      caricaPrenota();
    } catch (e) { errore(e); }
  });
  // l'interruttore vale subito, senza dover premere Salva
  $("#pr-attive").addEventListener("change", async function () {
    const acceso = this.checked;
    try {
      await conPin(function (p) { return S.prenSalvaImpostazioni(p, { attive: acceso }); });
      C.toast(acceso ? "Prenotazioni dal sito accese" : "Prenotazioni dal sito spente: il sito dice di chiamare");
    } catch (e) { this.checked = !acceso; errore(e); }
  });
  $("#pr-copia").addEventListener("click", async function () {
    try { await navigator.clipboard.writeText("https://vicodelcarmine.it/#prenota"); C.toast("Link copiato"); }
    catch (e) { C.toast("vicodelcarmine.it/#prenota"); }
  });

  /* --- avvisi sul telefono del titolare --- */
  const supportaPush = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  const suIphone = /iPhone|iPad|iPod/.test(navigator.userAgent);
  const installata = navigator.standalone === true || matchMedia("(display-mode: standalone)").matches;
  function b64ToU8(b64) {
    const s = atob((b64 + "=".repeat((4 - b64.length % 4) % 4)).replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(s, function (c) { return c.charCodeAt(0); });
  }
  async function iscrizionePush() {
    try {
      const reg = await navigator.serviceWorker.getRegistration();
      return reg ? await reg.pushManager.getSubscription() : null;
    } catch (e) { return null; }
  }
  async function statoAvvisiPren() {
    const testo = $("#pr-avvisi-testo"), attiva = $("#pr-avvisi-attiva"), prova = $("#pr-avvisi-prova");
    const altri = prImp && prImp.telefoni ? " Telefoni con gli avvisi: " + prImp.telefoni + "." : "";
    attiva.hidden = true;
    prova.hidden = true;
    if (S.DEMO) { testo.textContent = "Nella demo le notifiche non partono."; return; }
    if (!supportaPush) {
      testo.innerHTML = suIphone && !installata
        ? "Su iPhone: tocca <b>Condividi</b> ↑ e poi <b>«Aggiungi alla schermata Home»</b>. Apri la dashboard da lì e attiva gli avvisi."
        : "Questo telefono non riceve notifiche." + C.esc(altri);
      return;
    }
    if (Notification.permission === "denied") {
      testo.textContent = "Le notifiche sono bloccate: riattivale dalle impostazioni del telefono per questa app." + altri;
      return;
    }
    const sub = Notification.permission === "granted" ? await iscrizionePush() : null;
    if (sub) {
      testo.textContent = "✅ Attivi: ti arriva una notifica a ogni prenotazione nuova o annullata dal sito." + altri;
      prova.hidden = false;
      conPin(function (p) { return S.prenSalvaPush(p, sub.toJSON()); }).catch(function () {});   // la tengo fresca sul server
      return;
    }
    testo.textContent = "Ricevi una notifica a ogni prenotazione nuova o annullata dal sito, anche con la dashboard chiusa." + altri;
    attiva.hidden = false;
  }
  $("#pr-avvisi-attiva").addEventListener("click", async function () {
    const btn = this;
    btn.disabled = true;
    try {
      const permesso = await Notification.requestPermission();
      if (permesso === "granted") {
        const reg = await navigator.serviceWorker.register("sw.js");
        await navigator.serviceWorker.ready;
        let sub = await reg.pushManager.getSubscription();
        if (!sub) {
          sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToU8(await S.chiavePush()) });
        }
        const n = await conPin(function (p) { return S.prenSalvaPush(p, sub.toJSON()); });
        if (prImp) prImp.telefoni = n;
        C.toast("Avvisi attivati! 🎉");
      }
    } catch (e) {
      C.toast(e.message || "Non sono riuscito ad attivarli", true);
    }
    btn.disabled = false;
    statoAvvisiPren();
  });
  $("#pr-avvisi-prova").addEventListener("click", async function () {
    const btn = this;
    btn.disabled = true;
    try {
      const ok = await conPin(S.prenProvaAvviso);
      C.toast(ok ? "Prova mandata: tra qualche secondo arriva la notifica" : "Serve almeno una prenotazione per fare la prova", !ok);
    } catch (e) { errore(e); }
    btn.disabled = false;
  });
  if (supportaPush && !S.DEMO) navigator.serviceWorker.register("sw.js").catch(function () {});

  /* ================= AGENTI ================= */

  // i posti dove si pubblica l'annuncio "Lavora come PR": ognuno ha il suo link ?ref=
  const CANALI_PR = [
    ["fb-cerco-offro-lavoro", "Facebook · Firenze cerco/offro lavoro"],
    ["fb-firenze-lavoro", "Facebook · Firenze Lavoro"],
    ["fb-gruppi-lavoro", "Facebook · altri gruppi di lavoro"],
    ["esn-florentia", "ESN Florentia (Erasmus)"],
    ["aegee-firenze", "AEGEE Firenze (Erasmus)"],
    ["erasmus-whatsapp", "Gruppi WhatsApp Erasmus"],
    ["gruppi-studenti", "Gruppi studenti UniFi e accademie"],
    ["subito", "Subito.it"],
    ["bakeca", "Bakeca"],
    ["instagram-ads", "Instagram sponsorizzato"],
    ["tiktok-ads", "TikTok sponsorizzato"],
  ];
  const NOMI_CANALI = { diretto: "Senza link (diretto)", guide: "Pagina guide (senza link)" };
  CANALI_PR.forEach(function (c) { NOMI_CANALI[c[0]] = c[1]; });
  function nomeCanale(k) { return NOMI_CANALI[k] || k; }
  function linkCanale(k) { return C.RADICE + "diventa/?ref=" + encodeURIComponent(k); }

  function linkChat(telefono, testo) {
    const num = String(telefono || "").replace(/\D/g, "");
    const intl = num ? (num.length <= 10 ? "39" + num : num) : "";
    return "https://wa.me/" + intl + (testo ? "?text=" + encodeURIComponent(testo) : "");
  }

  async function caricaRichieste() {
    const box = $("#richieste");
    let lista = [];
    try { lista = await conPin(S.candidature); } catch (e) { errore(e); return; }
    segnaRichieste(lista.length);
    if (!lista.length) { box.innerHTML = ""; return; }
    box.innerHTML = '<div class="sez-titolo"><h2>📝 Richieste</h2><span class="pill no">' + lista.length +
      (lista.length === 1 ? " da vedere" : " da vedere") + "</span></div>" +
      lista.map(function (c) {
        return '<div class="card" data-richiesta="' + C.esc(c.id) + '">' +
          '<div class="riga"><div class="cresce"><h3 style="margin:0">' + C.esc(c.nome) + "</h3>" +
          (c.ruolo ? '<span class="pill oro">' + C.esc(c.ruolo) + "</span>" : "") +
          (c.canale ? ' <span class="pill ok">📣 ' + C.esc(nomeCanale(c.canale)) + "</span>" : "") + "</div>" +
          '<span class="dim fisso">' + C.esc(C.dataBreve(C.sera(c.creato))) + "</span></div>" +
          '<p class="small" style="margin-top:8px">📞 ' + C.esc(c.telefono) +
          ' · <a target="_blank" rel="noopener" href="' + linkChat(c.telefono, "Ciao " + c.nome.split(/\s+/)[0] + "! Abbiamo visto la tua richiesta per fare il PR.") +
          '">💬 Scrivigli</a></p>' +
          (c.note ? '<p class="small muted" style="margin-top:6px">' + C.esc(c.note) + "</p>" : "") +
          '<div class="riga" style="margin-top:12px"><button class="btn verde piccolo" data-approva>✅ Approva</button>' +
          '<button class="btn vuoto piccolo" data-scarta>✕ Scarta</button></div></div>';
      }).join("");
    $$("[data-richiesta]", box).forEach(function (card) {
      const c = lista.find(function (x) { return String(x.id) === card.dataset.richiesta; });
      $("[data-approva]", card).addEventListener("click", function () { approvaRichiesta(c); });
      $("[data-scarta]", card).addEventListener("click", async function () {
        if (!confirm("Scarto la richiesta di " + c.nome + "? I suoi dati vengono cancellati.")) return;
        try {
          await conPin(function (p) { return S.scartaCandidatura(p, c.id); });
          C.toast("Richiesta scartata");
          caricaRichieste();
        } catch (e) { errore(e); }
      });
    });
  }

  function approvaRichiesta(c) {
    apriFoglio("<h2>Approva " + C.esc(c.nome) + "</h2>" +
      '<p class="muted small">Diventa agente con le tariffe standard. Subito dopo si apre la sua scheda: da lì gli mandi il link dell\'app su WhatsApp.</p>' +
      '<label class="riga" style="margin-top:14px;gap:12px"><span class="cresce">🔥 Settimana di benvenuto' +
      '<span class="dim" style="display:block">Tariffe maggiorate per le sue prime sere.</span></span>' +
      '<span class="switch fisso"><input type="checkbox" id="ap-bonus" checked><i></i></span></label>' +
      '<button class="btn rosso pieno" id="ap-crea" style="margin-top:16px">Crea agente</button>');
    $("#ap-crea").addEventListener("click", async function () {
      this.disabled = true;
      try {
        const a = await conPin(function (p) { return S.approvaCandidatura(p, c.id, $("#ap-bonus").checked); });
        C.toast(c.nome + " è un agente: mandagli il link");
        caricaAgenti();
        apriAgente(a.id);
      } catch (e) { this.disabled = false; errore(e); }
    });
  }

  async function caricaAgenti() {
    caricaRichieste();
    try {
      const p = await conPin(S.panoramica);
      const box = $("#lista-agenti");
      if (!p.agenti.length) { box.innerHTML = '<div class="vuoto">Nessun agente. Aggiungine uno con “＋ Nuovo”.</div>'; return; }
      box.innerHTML = p.agenti.map(function (a) {
        return '<div class="card" data-agente="' + a.id + '" style="cursor:pointer">' +
          '<div class="riga"><div><h3 style="margin:0">' + C.esc(a.nome) + "</h3>" +
          '<span class="pill ' + (a.attivo ? "ok" : "no") + '">' + (a.attivo ? "attivo" : "in pausa") + "</span>" +
          (a.bonusFino ? ' <span class="pill oro">🔥 benvenuto fino a ' + C.esc(C.dataBreve(a.bonusFino)) + "</span>" : "") +
          (a.validita > 1 ? ' <span class="pill oro">🎟️ buoni ' + a.validita + " giorni</span>" : "") + "</div>" +
          '<label class="switch fisso" onclick="event.stopPropagation()"><input type="checkbox" data-attiva="' + a.id + '"' +
          (a.attivo ? " checked" : "") + "><i></i></label></div>" +
          '<div class="kpi" style="margin-top:12px">' +
          "<div><b>" + a.stasera.persone + "</b><span>persone stasera</span></div>" +
          '<div><b>' + C.euro(a.mese.euro) + "</b><span>" + a.mese.nome + "</span></div>" +
          '<div class="euro"><b>' + C.euro(a.daPagare) + "</b><span>da pagare</span></div></div></div>";
      }).join("");
      $$("[data-agente]", box).forEach(function (c) {
        c.addEventListener("click", function () { apriAgente(c.dataset.agente); });
      });
      $$("[data-attiva]", box).forEach(function (sw) {
        sw.addEventListener("change", async function () {
          try {
            await conPin(function (pp) { return S.salvaAgente(pp, { id: sw.dataset.attiva, attivo: sw.checked }); });
            C.toast(sw.checked ? "Agente attivo: il suo QR funziona" : "Agente in pausa: il suo QR è bloccato");
            caricaAgenti();
          } catch (e) { sw.checked = !sw.checked; errore(e); }
        });
      });
    } catch (e) { errore(e); }
  }

  function editorFasce(fasce) {
    return '<div class="fasce-ed">' + fasce.map(function (f, i) {
      const da = i === 0 ? 1 : fasce[i - 1].fino + 1;
      const quale = f.fino == null
        ? 'dalla <b class="da">' + da + "</b>ª persona in poi"
        : 'dalla <b class="da">' + da + '</b>ª alla <input type="number" inputmode="numeric" class="fino" min="1" value="' + f.fino + '">ª';
      return '<div class="fascia"><div class="quale">' + quale + "</div>" +
        '<div class="soldi"><input type="text" inputmode="decimal" class="soldi-val" value="' + String(f.euro).replace(".", ",") + '"></div></div>';
    }).join("") + "</div>";
  }
  function legaFasce(box) {
    box.addEventListener("input", function (e) {
      if (!e.target.classList.contains("fino")) return;
      const righe = $$(".fascia", box);
      righe.forEach(function (r, i) {
        if (i === 0) return;
        const prima = $(".fino", righe[i - 1]);
        $(".da", r).textContent = (parseInt(prima.value, 10) || 0) + 1;
      });
    });
  }
  function leggiFasce(box) {
    return $$(".fascia", box).map(function (r) {
      const fi = $(".fino", r);
      return { fino: fi ? fi.value : null, euro: $(".soldi-val", r).value };
    });
  }

  $("#nuovo-agente").addEventListener("click", function () {
    apriFoglio('<h2>Nuovo agente</h2>' +
      '<label class="campo"><span>Nome</span><input type="text" id="na-nome" autocomplete="off"></label>' +
      '<label class="campo"><span>Telefono (per mandargli il link su WhatsApp)</span><input type="tel" id="na-tel" placeholder="es. 333 1234567"></label>' +
      '<p class="dim">Parte con le tariffe standard (2 € · 3 € · 4 €): puoi cambiarle dopo.</p>' +
      '<label class="riga" style="margin-top:12px;gap:12px"><span class="cresce">🔥 Settimana di benvenuto' +
      '<span class="dim" style="display:block">Tariffe maggiorate per i primi giorni. Spegnila per chi lavorava già con te.</span></span>' +
      '<span class="switch fisso"><input type="checkbox" id="na-bonus" checked><i></i></span></label>' +
      '<button class="btn rosso pieno" id="na-crea" style="margin-top:14px">Crea agente</button>');
    $("#na-nome").focus();
    $("#na-crea").addEventListener("click", async function () {
      const nome = $("#na-nome").value.trim();
      if (!nome) { C.toast("Scrivi il nome", true); return; }
      try {
        const a = await conPin(function (p) {
          return S.salvaAgente(p, { nome: nome, telefono: $("#na-tel").value, bonus: $("#na-bonus").checked });
        });
        C.toast("Agente creato");
        caricaAgenti();
        apriAgente(a.id);
      } catch (e) { errore(e); }
    });
  });

  function linkWhatsApp(a) {
    const testo = "Ciao " + a.nome.replace(/\s*\(.*\)$/, "") + "! Questa è la tua app agente del Vico del Carmine: " +
      C.urlAgente(a.chiave) + "\nAprila e poi 'Aggiungi alla schermata Home'.";
    const num = String(a.telefono || "").replace(/\D/g, "");
    const intl = num ? (num.length <= 10 ? "39" + num : num) : "";
    return "https://wa.me/" + intl + "?text=" + encodeURIComponent(testo);
  }

  async function apriAgente(id) {
    let a;
    try { a = await conPin(function (p) { return S.dettaglioAgente(p, id); }); }
    catch (e) { errore(e); return; }
    apriFoglio(
      "<h2>" + C.esc(a.nome) + "</h2>" +
      (a.canale ? '<p class="dim">📣 Arrivato da: ' + C.esc(nomeCanale(a.canale)) + "</p>" : "") +
      (a.bonusPeriodo ? '<label class="riga bonus" style="margin-top:8px;gap:12px"><span class="cresce">🔥 <b>Settimana di benvenuto</b>' +
        '<span class="dim" style="display:block">' + (a.bonus !== false
          ? "Tariffe " + (Number(a.bonusPer) === 2 ? "doppie" : "×" + String(a.bonusPer).replace(".", ",")) +
            " fino a " + C.esc(C.dataBreve(a.bonusPeriodo)) + " compreso. Qui sotto vedi le tariffe normali."
          : "Spenta: per questo agente valgono le tariffe normali.") + "</span></span>" +
        '<span class="switch fisso"><input type="checkbox" id="ag-bonus"' + (a.bonus !== false ? " checked" : "") + "><i></i></span></label>" : "") +
      '<div class="kpi" style="margin-top:12px">' +
      "<div><b>" + C.euro(a.maturato) + "</b><span>guadagnati</span></div>" +
      "<div><b>" + C.euro(a.pagato) + "</b><span>pagati</span></div>" +
      '<div class="euro"><b>' + C.euro(a.daPagare) + "</b><span>da pagare</span></div></div>" +

      '<div class="card"><h3>💶 Segna un pagamento</h3><div class="riga">' +
      '<input type="text" inputmode="decimal" id="ag-importo" value="' + (a.daPagare > 0 ? String(a.daPagare).replace(".", ",") : "") + '" placeholder="Importo €">' +
      '<button class="btn verde fisso" id="ag-paga">Pagato</button></div>' +
      '<input type="text" id="ag-nota" placeholder="Nota (es. contanti, bonifico)" style="margin-top:8px"></div>' +

      '<div class="card"><h3>📲 App dell\'agente</h3>' +
      '<p class="dim">Fagli inquadrare questo QR, oppure mandagli il link. È personale: chi ce l\'ha vede i suoi guadagni.</p>' +
      '<div class="qr" style="width:170px;margin:12px auto">' + C.disegnaQR(C.urlAgente(a.chiave)) + "</div>" +
      '<div class="riga"><a class="btn verde" target="_blank" rel="noopener" href="' + linkWhatsApp(a) + '">WhatsApp</a>' +
      '<button class="btn vuoto" id="ag-copia">Copia link</button></div>' +
      '<button class="btn vuoto pieno piccolo" id="ag-chiave" style="margin-top:10px">Nuovo link (il vecchio smette di funzionare)</button></div>' +

      '<div class="card"><h3>✏️ Dati e tariffe</h3>' +
      '<label class="campo"><span>Nome</span><input type="text" id="ag-nome" value="' + C.esc(a.nome) + '"></label>' +
      '<label class="campo"><span>Telefono</span><input type="tel" id="ag-tel" value="' + C.esc(a.telefono) + '"></label>' +
      '<label class="campo"><span>🎟️ I buoni dei suoi clienti valgono</span><select id="ag-validita">' +
      [1, 2, 3, 4, 5, 6, 7].map(function (n) {
        return '<option value="' + n + '"' + ((a.validita || 1) === n ? " selected" : "") + ">" +
          (n === 1 ? "solo la sera stessa" : n + " giorni (stasera e " + (n === 2 ? "la sera dopo" : "le " + (n - 1) + " sere dopo") + ")") + "</option>";
      }).join("") + "</select></label>" +
      '<p class="dim" style="margin-top:-4px">Il sabato (e ogni giorno di pausa) non si conta.</p>' +
      '<p class="muted small" style="margin-top:12px">Euro a persona, si riparte da zero ogni sera:</p>' +
      '<div id="ag-fasce">' + editorFasce(a.fasce) + "</div>" +
      '<button class="btn rosso pieno" id="ag-salva" style="margin-top:8px">Salva</button></div>' +

      '<div class="card"><h3>📅 Serate</h3><ul class="lista">' +
      (a.serate.length ? a.serate.map(function (s) {
        return '<li><div class="cresce"><b>' + C.nomeSera(s.sera) + '</b><div class="dim">' + s.giocate + " giocate · " +
          s.tavoli + " tavoli · " + s.persone + " persone</div></div>" +
          '<span class="euro">' + C.euro(s.euro) + "</span></li>";
      }).join("") : '<li class="vuoto">Ancora nessuna serata.</li>') + "</ul></div>" +

      '<div class="card"><h3>👛 Pagamenti fatti</h3><ul class="lista">' +
      (a.pagamenti.length ? a.pagamenti.map(function (p) {
        const d = new Date(p.data);
        return '<li><div class="cresce">' + d.toLocaleDateString("it-IT", { day: "numeric", month: "short", year: "numeric" }) +
          (p.nota ? '<div class="dim">' + C.esc(p.nota) + "</div>" : "") + "</div>" +
          '<span class="euro">' + C.euro(p.importo) + "</span></li>";
      }).join("") : '<li class="vuoto">Nessun pagamento registrato.</li>') + "</ul></div>" +

      '<button class="btn vuoto pieno" id="ag-elimina" style="color:var(--danger);border-color:rgba(255,107,94,.45)">🗑 Elimina agente</button>'
    );
    legaFasce($("#ag-fasce"));
    if ($("#ag-bonus")) $("#ag-bonus").addEventListener("change", async function () {
      const acceso = this.checked;
      try {
        await conPin(function (p) { return S.salvaAgente(p, { id: id, bonus: acceso }); });
        C.toast(acceso ? "Settimana di benvenuto accesa" : "Settimana di benvenuto spenta per " + a.nome);
        caricaAgenti();
        apriAgente(id);
      } catch (e) { this.checked = !acceso; errore(e); }
    });

    $("#ag-salva").addEventListener("click", async function () {
      try {
        await conPin(function (p) {
          return S.salvaAgente(p, { id: id, nome: $("#ag-nome").value, telefono: $("#ag-tel").value,
            validita: $("#ag-validita").value, fasce: leggiFasce($("#ag-fasce")) });
        });
        C.toast("Salvato");
        caricaAgenti();
        apriAgente(id);
      } catch (e) { errore(e); }
    });
    $("#ag-paga").addEventListener("click", async function () {
      const imp = $("#ag-importo").value;
      if (!confirm("Segno " + C.euro(parseFloat(String(imp).replace(",", ".")) || 0) + " pagati a " + a.nome + "?")) return;
      try {
        await conPin(function (p) { return S.pagamento(p, id, imp, $("#ag-nota").value); });
        C.toast("Pagamento registrato");
        caricaAgenti();
        apriAgente(id);
      } catch (e) { errore(e); }
    });
    $("#ag-copia").addEventListener("click", async function () {
      const url = C.urlAgente(a.chiave);
      try { await navigator.clipboard.writeText(url); C.toast("Link copiato"); } catch (e) { prompt("Link dell'agente:", url); }
    });
    $("#ag-elimina").addEventListener("click", async function () {
      const tavoli = a.serate.reduce(function (s, x) { return s + x.tavoli; }, 0);
      const storico = tavoli > 0 || a.pagamenti.length > 0;
      const domanda = storico
        ? "Elimino " + a.nome + " e TUTTO il suo storico?\n\nSi cancellano anche " + tavoli + (tavoli === 1 ? " tavolo, " : " tavoli, ") +
          C.euro(a.maturato) + " di provvigioni e " + a.pagamenti.length + (a.pagamenti.length === 1 ? " pagamento registrato" : " pagamenti registrati") +
          ". Non si può tornare indietro.\n\n" +
          "Se vuoi solo fermarlo, premi Annulla e mettilo in pausa con l'interruttore."
        : "Elimino " + a.nome + "? Il suo link e il suo QR smettono subito di funzionare.";
      if (!confirm(domanda)) return;
      try {
        await conPin(function (p) { return S.eliminaAgente(p, id); });
        chiudiFoglio();
        C.toast(a.nome + " eliminato");
        caricaAgenti();
      } catch (e) { errore(e); }
    });
    $("#ag-chiave").addEventListener("click", async function () {
      if (!confirm("Creo un link nuovo per " + a.nome + "? Quello vecchio smette subito di funzionare (utile se ha perso il telefono).")) return;
      try {
        await conPin(function (p) { return S.nuovaChiave(p, id); });
        C.toast("Nuovo link creato: mandaglielo");
        apriAgente(id);
      } catch (e) { errore(e); }
    });
  }

  /* ================= PREMI ================= */

  async function caricaPremi() {
    try {
      const lista = await conPin(S.premi);
      premiBozza = JSON.parse(JSON.stringify(lista));
      disegnaPremi();
    } catch (e) { errore(e); }
  }
  function percentuali() {
    const tot = premiBozza.reduce(function (s, p) { return s + (p.attivo ? p.peso : 0); }, 0);
    return premiBozza.map(function (p) { return p.attivo && tot ? Math.round((p.peso / tot) * 1000) / 10 : 0; });
  }
  function disegnaPremi() {
    const perc = percentuali();
    const box = $("#lista-premi");
    box.innerHTML = premiBozza.map(function (p, i) {
      return '<div class="premio-ed' + (p.attivo ? "" : " spento") + '" data-i="' + i + '">' +
        '<div class="testa"><input type="text" class="emo" data-k="emoji" value="' + C.esc(p.emoji) + '" aria-label="Emoji">' +
        '<div class="cresce"><input type="text" data-k="nome.it" value="' + C.esc(p.nome.it) + '" placeholder="Nome del premio"></div>' +
        '<span class="perc">' + String(perc[i]).replace(".", ",") + "%</span>" +
        '<label class="switch"><input type="checkbox" data-k="attivo"' + (p.attivo ? " checked" : "") + "><i></i></label></div>" +
        '<input type="range" min="0" max="50" step="1" data-k="peso" value="' + p.peso + '" aria-label="Frequenza">' +
        "<details><summary>Descrizione e inglese</summary>" +
        '<label class="campo"><span>Descrizione</span><input type="text" data-k="desc.it" value="' + C.esc(p.desc.it) + '"></label>' +
        '<label class="campo"><span>Nome in inglese (per i turisti)</span><input type="text" data-k="nome.en" value="' + C.esc(p.nome.en) + '"></label>' +
        '<label class="campo"><span>Descrizione in inglese</span><input type="text" data-k="desc.en" value="' + C.esc(p.desc.en) + '"></label>' +
        '<button class="btn vuoto piccolo" data-togli>🗑 Togli questo premio</button>' +
        "</details></div>";
    }).join("");
  }
  $("#lista-premi").addEventListener("input", function (e) {
    const k = e.target.dataset.k;
    const riga = e.target.closest("[data-i]");
    if (!k || !riga) return;
    const p = premiBozza[+riga.dataset.i];
    const v = e.target.type === "checkbox" ? e.target.checked : e.target.type === "range" ? +e.target.value : e.target.value;
    if (k.indexOf(".") > 0) { const [a, b] = k.split("."); p[a][b] = v; } else p[k] = v;
    // aggiorno solo le percentuali, senza ridisegnare (così non si perde il dito sulla barra)
    const perc = percentuali();
    $$(".premio-ed", $("#lista-premi")).forEach(function (el, i) {
      $(".perc", el).textContent = String(perc[i]).replace(".", ",") + "%";
      el.classList.toggle("spento", !premiBozza[i].attivo);
    });
  });
  $("#lista-premi").addEventListener("click", function (e) {
    if (!e.target.hasAttribute("data-togli")) return;
    const i = +e.target.closest("[data-i]").dataset.i;
    if (!confirm("Tolgo “" + premiBozza[i].nome.it + "”? (Ricordati di salvare)")) return;
    premiBozza.splice(i, 1);
    disegnaPremi();
  });
  $("#nuovo-premio").addEventListener("click", function () {
    premiBozza.push({ id: null, emoji: "🎁", peso: 10, attivo: true, nome: { it: "", en: "" }, desc: { it: "", en: "" } });
    disegnaPremi();
    const ultimo = $$(".premio-ed", $("#lista-premi")).pop();
    ultimo.scrollIntoView({ behavior: "smooth", block: "center" });
    $('[data-k="nome.it"]', ultimo).focus();
  });
  $("#salva-premi").addEventListener("click", async function () {
    if (premiBozza.some(function (p) { return p.attivo && !p.nome.it.trim(); })) { C.toast("Ogni premio attivo ha bisogno di un nome", true); return; }
    try {
      const lista = await conPin(function (p) { return S.salvaPremi(p, premiBozza); });
      premiBozza = JSON.parse(JSON.stringify(lista));
      disegnaPremi();
      C.toast("Premi salvati: valgono da subito");
    } catch (e) { errore(e); }
  });

  /* ================= ALTRO ================= */

  async function caricaAltro() {
    $("#demo-azzera").hidden = !S.DEMO;
    try {
      const imp = await conPin(S.impostazioni);
      $("#chiusura").value = imp.chiusura;
      $("#bonus-giorni").value = imp.bonusGiorni;
      $("#bonus-per").value = String(imp.bonusPer).replace(".", ",");
      disegnaGiorni(imp.giorniPausa || []);
      $("#fasce-standard").innerHTML = editorFasce(imp.fasce);
      const p = await conPin(S.panoramica);
      $$("[data-pagina]").forEach(function (a) { a.href = C.RADICE + a.dataset.pagina; });
      const primo = p.agenti.find(function (a) { return a.attivo; }) || p.agenti[0];
      const lg = $("#link-gioco");
      if (primo) { lg.href = C.urlGioca(primo.codice); lg.hidden = false; } else lg.hidden = true;
      caricaCanali();
    } catch (e) { errore(e); }
  }

  // ricerca PR: per ogni canale richieste, agenti e chi ha già fatto sedere il primo tavolo
  async function caricaCanali() {
    const box = $("#canali-numeri");
    let lista = [];
    try { lista = await conPin(S.canali); } catch (e) { box.innerHTML = ""; return; }
    box.innerHTML = lista.length ? '<ul class="lista">' + lista.map(function (r) {
      return '<li><div class="cresce"><b>' + C.esc(nomeCanale(r.canale)) + '</b><div class="dim">' +
        r.richieste + (r.richieste === 1 ? " richiesta" : " richieste") + " · " +
        r.agenti + (r.agenti === 1 ? " agente" : " agenti") + " · " +
        r.persone + (r.persone === 1 ? " persona portata" : " persone portate") + "</div></div>" +
        '<span class="pill ' + (r.conTavolo ? "ok" : "no") + ' fisso">' + r.conTavolo + " col 1° tavolo</span></li>";
    }).join("") + "</ul>"
      : '<p class="vuoto">Ancora nessuna richiesta arrivata da un link.</p>';
  }
  $("#canali-link").innerHTML = CANALI_PR.map(function (c) {
    return '<li><span class="cresce">' + C.esc(c[1]) + '<span class="dim" style="display:block">?ref=' + C.esc(c[0]) + "</span></span>" +
      '<button class="btn oro piccolo fisso" data-canale="' + C.esc(c[0]) + '">Copia</button></li>';
  }).join("");
  async function copiaCanale(k) {
    const url = linkCanale(k);
    try { await navigator.clipboard.writeText(url); C.toast("Link copiato: usalo solo per " + nomeCanale(k)); }
    catch (e) { prompt("Il link per " + nomeCanale(k) + ":", url); }
  }
  $("#canali-link").addEventListener("click", function (e) {
    const b = e.target.closest("[data-canale]");
    if (b) copiaCanale(b.dataset.canale);
  });
  $("#canale-copia").addEventListener("click", function () {
    const k = $("#canale-nuovo").value.trim().toLowerCase().replace(/\s+/g, "-");
    if (!/^[a-z0-9][a-z0-9:._-]{0,39}$/.test(k)) {
      C.toast("Scrivi un nome corto: lettere minuscole, numeri e trattini", true);
      $("#canale-nuovo").focus();
      return;
    }
    $("#canale-nuovo").value = k;
    copiaCanale(k);
  });
  legaFasce($("#fasce-standard"));
  $$("[data-copia]").forEach(function (b) {
    b.addEventListener("click", async function () {
      const url = C.RADICE + b.dataset.copia;
      try { await navigator.clipboard.writeText(url); C.toast("Link copiato: incollalo sotto il video"); }
      catch (e) { prompt("Il link della pagina:", url); }
    });
  });

  // giorni della settimana da lunedì a domenica (0 = domenica)
  function disegnaGiorni(pausa) {
    $("#giorni-pausa").innerHTML = [1, 2, 3, 4, 5, 6, 0].map(function (g) {
      return '<button type="button" data-g="' + g + '" class="' + (pausa.indexOf(g) >= 0 ? "on" : "") + '">' +
        C.NOMI_GIORNI[g].slice(0, 3) + "</button>";
    }).join("");
  }
  $("#giorni-pausa").addEventListener("click", function (e) {
    if (e.target.dataset.g != null) e.target.classList.toggle("on");
  });
  $("#salva-pausa").addEventListener("click", async function () {
    const giorni = $$("#giorni-pausa button.on").map(function (b) { return Number(b.dataset.g); });
    try {
      await conPin(function (p) { return S.salvaImpostazioni(p, { giorniPausa: giorni }); });
      C.toast(giorni.length ? "Pausa: " + giorni.map(function (g) { return C.NOMI_GIORNI[g]; }).join(", ") : "Nessun giorno di pausa");
    } catch (e) { errore(e); }
  });
  $("#salva-bonus").addEventListener("click", async function () {
    try {
      await conPin(function (p) {
        return S.salvaImpostazioni(p, { bonusGiorni: $("#bonus-giorni").value, bonusPer: $("#bonus-per").value });
      });
      C.toast("Settimana di benvenuto salvata");
    } catch (e) { errore(e); }
  });
  $("#salva-chiusura").addEventListener("click", async function () {
    try { await conPin(function (p) { return S.salvaImpostazioni(p, { chiusura: $("#chiusura").value }); }); C.toast("Orario salvato"); }
    catch (e) { errore(e); }
  });
  $("#salva-fasce").addEventListener("click", async function () {
    try { await conPin(function (p) { return S.salvaImpostazioni(p, { fasce: leggiFasce($("#fasce-standard")) }); }); C.toast("Tariffe salvate per i nuovi agenti"); }
    catch (e) { errore(e); }
  });
  $("#esci").addEventListener("click", function () {
    dimenticaPin();
    pin = null;
    document.body.classList.remove("con-tab");
    mostraLogin();
  });
  $("#demo-azzera").addEventListener("click", function () {
    if (!confirm("Ricreo i dati di prova da zero?")) return;
    S.demoAzzera();
    dimenticaPin();
    location.reload();
  });

  /* ---------- avvio ---------- */
  $("#demo-bar").hidden = !S.DEMO || C.VETRINA;
  // la dashboard da computer: stessa app e stesso PIN (desktop.js legge lo stesso "vdcpr_pin")
  $$("#vai-desktop, #vai-desktop-2").forEach(function (a) { a.href = "../desktop/" + (S.DEMO ? "?demo=1" : "?demo=0"); });
  if (C.VETRINA && !pinSalvato()) ricordaPin("1234", false);   // in vetrina si entra senza PIN (dati finti)
  (async function () {
    const p = pinSalvato();
    if (!p) return mostraLogin();
    try { await S.entra(p); pin = p; dentro(); }
    catch (e) { if (e.codice === "pin") dimenticaPin(); mostraLogin(); }
  })();
})();
