/* Pagina del cliente: si apre dal QR dell'agente (gioca/?a=CODICE).
   Gira la slot → il premio lo decide il server → buono con QR + strada per il ristorante. */

(function () {
  const C = Comune;

  const TESTI = {
    it: { bandiera: "🇮🇹", titolo: "🎰 Tenta la Fortuna!", sotto: "Gira la slot e vinci un premio per tutto il tavolo!",
      gira: "🎰 GIRA!", girando: "🎰 GIRANDO...", vinto: "🎉 HAI VINTO!", tuo: "🎁 Il tuo premio di stasera",
      tavolo: "👥 Un premio per tutto il tavolo", valido: "⏰ Valido solo stasera fino alle {ora}",
      mostra: "Mostra questo QR quando arrivi al ristorante", nota: "Valido con consumazione al ristorante.",
      dove: "Siamo a pochi passi da qui", strada: "📍 PORTAMI AL RISTORANTE", menu: "📋 SCOPRI IL NOSTRO MENU",
      prenota: "Prenota su WhatsApp", usato: "RITIRATO", buonAppetito: "Premio ritirato: buon appetito! 🍕",
      scaduto: "SCADUTO", scadutoTesto: "Questo premio è scaduto.",
      chiuso: "Per stasera abbiamo chiuso: vieni a trovarci domani!", pausa: "Stasera siamo già al completo: il gioco riapre domani!", nonAttivo: "Questo QR non è attivo.",
      nienteQr: "Inquadra il QR di un nostro agente per giocare.", errore: "Connessione assente, riprova tra un attimo." },
    en: { bandiera: "🇬🇧", titolo: "🎰 Try Your Luck!", sotto: "Spin the slot and win a prize for your whole table!",
      gira: "🎰 SPIN!", girando: "🎰 SPINNING...", vinto: "🎉 YOU WON!", tuo: "🎁 Your prize for tonight",
      tavolo: "👥 One prize for the whole table", valido: "⏰ Valid tonight only, until {ora}",
      mostra: "Show this QR code when you arrive at the restaurant", nota: "Valid with a meal at the restaurant.",
      dove: "We're just a short walk away", strada: "📍 TAKE ME TO THE RESTAURANT", menu: "📋 SEE OUR MENU",
      prenota: "Book on WhatsApp", usato: "REDEEMED", buonAppetito: "Prize redeemed: enjoy your meal! 🍕",
      scaduto: "EXPIRED", scadutoTesto: "This prize has expired.",
      chiuso: "We're closed for tonight: come and see us tomorrow!", pausa: "We're fully booked tonight: the game is back tomorrow!", nonAttivo: "This QR code is not active.",
      nienteQr: "Scan the QR code of one of our agents to play.", errore: "No connection, please try again in a moment." },
    de: { bandiera: "🇩🇪", titolo: "🎰 Versuchen Sie Ihr Glück!", sotto: "Drehen Sie den Slot und gewinnen Sie einen Preis für den ganzen Tisch!",
      gira: "🎰 DREHEN!", girando: "🎰 DREHT...", vinto: "🎉 GEWONNEN!", tuo: "🎁 Ihr Preis für heute Abend",
      tavolo: "👥 Ein Preis für den ganzen Tisch", valido: "⏰ Nur heute Abend gültig, bis {ora} Uhr",
      mostra: "Zeigen Sie diesen QR-Code bei Ihrer Ankunft im Restaurant", nota: "Gültig bei Verzehr im Restaurant.",
      dove: "Wir sind nur ein paar Schritte entfernt", strada: "📍 ZUM RESTAURANT", menu: "📋 SPEISEKARTE ANSEHEN",
      prenota: "Auf WhatsApp reservieren", usato: "EINGELÖST", buonAppetito: "Preis eingelöst: guten Appetit! 🍕",
      scaduto: "ABGELAUFEN", scadutoTesto: "Dieser Preis ist abgelaufen.",
      chiuso: "Heute Abend haben wir geschlossen: besuchen Sie uns morgen!", pausa: "Heute Abend sind wir ausgebucht: das Spiel ist morgen wieder da!", nonAttivo: "Dieser QR-Code ist nicht aktiv.",
      nienteQr: "Scannen Sie den QR-Code eines unserer Mitarbeiter, um zu spielen.", errore: "Keine Verbindung, bitte gleich noch einmal versuchen." },
    fr: { bandiera: "🇫🇷", titolo: "🎰 Tentez votre chance !", sotto: "Faites tourner la machine et gagnez un cadeau pour toute la table !",
      gira: "🎰 TOURNER !", girando: "🎰 ÇA TOURNE...", vinto: "🎉 GAGNÉ !", tuo: "🎁 Votre cadeau de ce soir",
      tavolo: "👥 Un cadeau pour toute la table", valido: "⏰ Valable ce soir seulement, jusqu'à {ora}",
      mostra: "Montrez ce QR code à votre arrivée au restaurant", nota: "Valable avec un repas au restaurant.",
      dove: "Nous sommes à quelques pas d'ici", strada: "📍 ALLER AU RESTAURANT", menu: "📋 VOIR NOTRE MENU",
      prenota: "Réserver sur WhatsApp", usato: "UTILISÉ", buonAppetito: "Cadeau utilisé : bon appétit ! 🍕",
      scaduto: "EXPIRÉ", scadutoTesto: "Ce cadeau a expiré.",
      chiuso: "Nous sommes fermés pour ce soir : revenez demain !", pausa: "Ce soir, nous sommes complets : le jeu revient demain !", nonAttivo: "Ce QR code n'est pas actif.",
      nienteQr: "Scannez le QR code de l'un de nos agents pour jouer.", errore: "Pas de connexion, réessayez dans un instant." },
    es: { bandiera: "🇪🇸", titolo: "🎰 ¡Prueba tu suerte!", sotto: "¡Gira la tragamonedas y gana un premio para toda la mesa!",
      gira: "🎰 ¡GIRAR!", girando: "🎰 GIRANDO...", vinto: "🎉 ¡HAS GANADO!", tuo: "🎁 Tu premio de esta noche",
      tavolo: "👥 Un premio para toda la mesa", valido: "⏰ Válido solo esta noche, hasta las {ora}",
      mostra: "Muestra este QR al llegar al restaurante", nota: "Válido con consumición en el restaurante.",
      dove: "Estamos a pocos pasos de aquí", strada: "📍 LLÉVAME AL RESTAURANTE", menu: "📋 VER NUESTRO MENÚ",
      prenota: "Reservar por WhatsApp", usato: "CANJEADO", buonAppetito: "Premio canjeado: ¡buen provecho! 🍕",
      scaduto: "CADUCADO", scadutoTesto: "Este premio ha caducado.",
      chiuso: "Esta noche ya hemos cerrado: ¡te esperamos mañana!", pausa: "¡Esta noche estamos completos: el juego vuelve mañana!", nonAttivo: "Este QR no está activo.",
      nienteQr: "Escanea el QR de uno de nuestros agentes para jugar.", errore: "Sin conexión, inténtalo de nuevo en un momento." },
  };
  const EMOJI_RULLO = ["🍕", "🍝", "🍰", "🥂", "🍹", "🔥", "⭐", "🎰", "🧁", "🇮🇹"];
  const SALVATO = "vdcpr_buono";

  let lingua = scegliLingua();
  let t = TESTI[lingua];
  let buonoCorrente = null;
  let timerControllo = null;

  function scegliLingua() {
    let l = null;
    try { l = localStorage.getItem("vdcpr_lingua"); } catch (e) {}
    if (!l) l = (navigator.language || "it").slice(0, 2).toLowerCase();
    return TESTI[l] ? l : "en";
  }
  function testoPremio(campo) {
    return lingua === "it" ? campo.it : (campo.en || campo.it);
  }

  function applicaLingua() {
    t = TESTI[lingua];
    document.documentElement.lang = lingua;
    $$("[data-t]").forEach(function (el) { el.textContent = t[el.dataset.t]; });
    $$("#lingue button").forEach(function (b) { b.classList.toggle("on", b.dataset.l === lingua); });
    if (buonoCorrente) mostraBuono(buonoCorrente, false);
    const m = $("#messaggio");
    if (!m.hidden && m.dataset.chiave) messaggio(m.dataset.emoji, m.dataset.chiave);
  }

  function preparaLingue() {
    const nav = $("#lingue");
    Object.keys(TESTI).forEach(function (l) {
      const b = document.createElement("button");
      b.type = "button";
      b.dataset.l = l;
      b.textContent = TESTI[l].bandiera;
      b.setAttribute("aria-label", l);
      b.addEventListener("click", function () {
        lingua = l;
        try { localStorage.setItem("vdcpr_lingua", l); } catch (e) {}
        applicaLingua();
      });
      nav.appendChild(b);
    });
  }

  function messaggio(emoji, chiave) {
    const m = $("#messaggio");
    m.dataset.emoji = emoji;
    m.dataset.chiave = chiave;
    m.innerHTML = '<div class="grande-emoji">' + emoji + "</div><p>" + C.esc(t[chiave]) + "</p>";
    m.hidden = false;
  }

  /* ---------- il buono ---------- */
  function mostraBuono(b, nuovo) {
    buonoCorrente = b;
    $("#gioco").hidden = true;
    $("#messaggio").hidden = true;
    const v = $("#vincita");
    const p = b.premio;
    let timbro = "";
    if (b.stato === "riscattato") timbro = '<div class="timbro ok"><b>✓ ' + C.esc(t.usato) + "</b></div>";
    else if (b.stato === "scaduto") timbro = '<div class="timbro no"><b>' + C.esc(t.scaduto) + "</b></div>";
    let piede;
    if (b.stato === "riscattato") piede = '<p class="buono-mostra">' + C.esc(t.buonAppetito) + "</p>";
    else if (b.stato === "scaduto") piede = '<p class="buono-mostra">' + C.esc(t.scadutoTesto) + "</p>";
    else piede =
      '<div class="buono-tavolo">' + C.esc(t.tavolo) + "</div>" +
      '<div class="buono-valido">' + C.esc(t.valido.replace("{ora}", C.ora(b.scade))) + "</div>" +
      '<p class="buono-mostra">' + C.esc(t.mostra) + "</p>" +
      '<p class="dim">' + C.esc(t.nota) + "</p>";
    v.innerHTML =
      '<div class="buono">' +
      '<div class="buono-testa">' + C.esc(nuovo ? t.vinto : t.tuo) + "</div>" +
      '<div class="buono-emoji">' + p.emoji + p.emoji + p.emoji + "</div>" +
      '<div class="buono-nome">' + C.esc(testoPremio(p.nome)) + "</div>" +
      '<div class="buono-desc">' + C.esc(testoPremio(p.desc)) + "</div>" +
      (C.VETRINA ? '<a href="' + C.urlBuono(b.codice) + '" class="qr buono-qr" style="display:block">' : '<div class="qr buono-qr">') +
      C.disegnaQR(C.urlBuono(b.codice)) + timbro + (C.VETRINA ? "</a>" : "</div>") +
      '<div class="buono-codice">' + C.codiceBello(b.codice) + "</div>" +
      piede +
      "</div>";
    v.hidden = false;
    controllaPiuTardi();
  }

  // quando il titolare lo riscatta, il telefono del cliente se ne accorge da solo
  function controllaPiuTardi() {
    clearTimeout(timerControllo);
    if (!buonoCorrente || buonoCorrente.stato !== "attivo") return;
    timerControllo = setTimeout(async function () {
      if (document.hidden) return controllaPiuTardi();
      try {
        const b = await Store.buono(buonoCorrente.codice);
        if (b.stato !== buonoCorrente.stato) mostraBuono(b, false);
        else controllaPiuTardi();
      } catch (e) { controllaPiuTardi(); }
    }, 15000);
  }

  /* ---------- la slot ---------- */
  async function gira() {
    const btn = $("#gira");
    btn.disabled = true;
    btn.textContent = t.girando;
    const slot = $$(".slot");
    slot.forEach(function (s) { s.classList.remove("ferma"); s.classList.add("gira"); });
    const rullo = setInterval(function () {
      slot.forEach(function (s) {
        if (s.classList.contains("gira")) s.firstChild.textContent = EMOJI_RULLO[Math.floor(Math.random() * EMOJI_RULLO.length)];
      });
    }, 90);

    const attesa = new Promise(function (ok) { setTimeout(ok, 1100); });
    let b;
    try {
      [b] = await Promise.all([Store.gioca(codiceAgente, C.dispositivo()), attesa]);
    } catch (e) {
      clearInterval(rullo);
      slot.forEach(function (s) { s.classList.remove("gira"); });
      btn.disabled = false;
      btn.textContent = t.gira;
      if (e.codice === "chiuso") { $("#gioco").hidden = true; messaggio("🌙", "chiuso"); }
      else if (e.codice === "pausa") { $("#gioco").hidden = true; messaggio("😊", "pausa"); }
      else if (e.codice === "agente") { $("#gioco").hidden = true; messaggio("🔒", "nonAttivo"); }
      else C.toast(t.errore, true);
      return;
    }
    // i rulli si fermano uno alla volta sul premio
    for (let i = 0; i < slot.length; i++) {
      await new Promise(function (ok) { setTimeout(ok, i === 0 ? 0 : 450); });
      slot[i].classList.remove("gira");
      slot[i].classList.add("ferma");
      slot[i].firstChild.textContent = b.premio.emoji;
    }
    clearInterval(rullo);
    await new Promise(function (ok) { setTimeout(ok, 450); });
    try { localStorage.setItem(SALVATO, JSON.stringify({ codice: b.codice, sera: C.sera() })); } catch (e) {}
    if (!b.gia) C.coriandoli();
    mostraBuono(b, !b.gia);
    $("#vincita").scrollIntoView({ behavior: "smooth", block: "start" });
  }

  /* ---------- avvio ---------- */
  const codiceAgente = (new URLSearchParams(location.search).get("a") || "").toUpperCase();

  async function avvio() {
    $("#demo-bar").hidden = !Store.DEMO || C.VETRINA;
    $("#mappa").src = C.urlMappa;
    $("#strada").href = C.urlStrada;
    $("#menu").href = C.RISTORANTE.menu;
    $("#prenota").href = "https://wa.me/" + C.RISTORANTE.whatsapp + "?text=" + encodeURIComponent("Ciao! Vorrei prenotare");
    preparaLingue();
    applicaLingua();
    $("#gira").addEventListener("click", gira);

    // ha già giocato stasera da questo telefono? gli rimostro il suo buono
    let salvato = null;
    try { salvato = JSON.parse(localStorage.getItem(SALVATO)); } catch (e) {}
    if (salvato && salvato.sera === C.sera()) {
      try { mostraBuono(await Store.buono(salvato.codice), false); return; } catch (e) {}
    }

    if (!codiceAgente) { messaggio("📱", "nienteQr"); return; }
    try {
      const a = await Store.agentePubblico(codiceAgente);
      if (!a.attivo) { messaggio("🔒", "nonAttivo"); return; }
      if (a.pausa) { messaggio("😊", "pausa"); return; }
      $("#gioco").hidden = false;
    } catch (e) {
      if (e.codice === "agente") messaggio("🔒", "nonAttivo");
      else messaggio("📶", "errore");
    }
  }

  avvio();
})();
