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
    const q = new URLSearchParams(location.search);
    const b = C.pulisciCodice(q.get("b")), c = C.pulisciCodice(q.get("c"));
    if (b || c) {
      history.replaceState(null, "", location.pathname);
      vai("riscatta");
      if (b) cerca(b); else cercaClub(c);
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
    ({ riscatta: caricaRiscatta, stasera: caricaStasera, club: caricaClub, agenti: caricaAgenti, premi: caricaPremi, altro: caricaAltro })[nome]();
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
  const TIPO_CLUB = { benvenuto: "Premio di benvenuto", compleanno: "Regalo di compleanno", promo: "Offerta del Club" };
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
      '<div class="muted small">per ' + persone(p.persone) + "</div>" +
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

  async function caricaClub() {
    cercaIscritti();
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
          " · per " + x.persone + "</div></div></li>";
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
      '<li><span class="cresce">📣 Offerte: ' + (i.promo ? "<b>sì</b>" : "no") + "</span></li></ul>" +

      '<div class="card"><h3>🎁 Premi</h3><ul class="lista">' +
      (i.premi.length ? i.premi.map(function (p) {
        const st = STATO_CLUB[p.stato] || ["", p.stato];
        return '<li data-premio="' + C.esc(p.codice) + '" style="cursor:pointer"><span style="font-size:1.4rem">' + C.esc(p.emoji) + "</span>" +
          '<div class="cresce"><b>' + C.esc(p.nome.it) + '</b><div class="dim">' + (TIPO_CLUB[p.tipo] || "") + " · per " + p.persone +
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

  /* ================= AGENTI ================= */

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
          (c.ruolo ? '<span class="pill oro">' + C.esc(c.ruolo) + "</span>" : "") + "</div>" +
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
    } catch (e) { errore(e); }
  }
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
  if (C.VETRINA && !pinSalvato()) ricordaPin("1234", false);   // in vetrina si entra senza PIN (dati finti)
  (async function () {
    const p = pinSalvato();
    if (!p) return mostraLogin();
    try { await S.entra(p); pin = p; dentro(); }
    catch (e) { if (e.codice === "pin") dimenticaPin(); mostraLogin(); }
  })();
})();
