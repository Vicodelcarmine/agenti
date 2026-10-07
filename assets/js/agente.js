/* App dell'agente: si apre dal link personale (agente/?k=CHIAVE).
   Il link resta nell'indirizzo, così "Aggiungi a Home" se lo porta dietro. */

(function () {
  const C = Comune;
  const SALVATA = "vdcpr_agente_chiave";
  let chiave = new URLSearchParams(location.search).get("k");
  let dati = null;

  if (chiave) { try { localStorage.setItem(SALVATA, chiave); } catch (e) {} }
  else { try { chiave = localStorage.getItem(SALVATA); } catch (e) {} }

  function fuori() {
    $("#app").hidden = true;
    $("#fuori").hidden = false;
    if (!Store.DEMO) return;
    const box = $("#demo-scelta");
    box.hidden = false;
    box.querySelectorAll("a").forEach(function (a) { a.remove(); });
    Store.demoAgenti().forEach(function (a) {
      const l = document.createElement("a");
      l.className = "btn vuoto pieno";
      l.style.marginTop = "8px";
      l.href = "?k=" + a.chiave;
      l.textContent = a.nome + (a.attivo ? "" : " · in pausa");
      box.appendChild(l);
    });
  }

  function disegna(d) {
    const primaVolta = !dati;
    dati = d;
    $("#fuori").hidden = true;
    $("#app").hidden = false;
    $("#saluto").textContent = "Ciao, " + d.nome.replace(/\s*\(.*\)$/, "");
    const st = $("#stato");
    st.textContent = d.attivo ? "QR attivo" : "In pausa";
    st.className = "pill " + (d.attivo ? "ok" : "no");
    $("#in-pausa").hidden = d.attivo;
    $("#servizio-pausa").hidden = !d.pausa || !d.attivo;

    if (primaVolta) {
      const url = C.urlGioca(d.codice);
      $("#mio-qr").innerHTML = C.disegnaQR(url);
      $("#qr-grande").innerHTML = C.disegnaQR(url);
    }
    $("#mio-qr").style.opacity = d.attivo && !d.pausa ? 1 : .25;

    $("#s-giocate").textContent = d.stasera.giocate;
    $("#s-persone").textContent = d.stasera.persone;
    $("#s-euro").textContent = C.euro(d.stasera.euro);
    const pf = C.prossimaFascia(d.fasce, d.stasera.persone);
    if (pf) {
      $("#s-prossima").textContent = "Ancora " + pf.mancano + (pf.mancano === 1 ? " persona" : " persone") +
        " e poi ogni persona vale " + C.euro(pf.euro) + ".";
      const fascia = d.fasce.find(function (f) { return f.fino != null && d.stasera.persone < f.fino; });
      const inizio = d.fasce.indexOf(fascia) > 0 ? d.fasce[d.fasce.indexOf(fascia) - 1].fino : 0;
      const pct = Math.round(((d.stasera.persone - inizio) / (fascia.fino - inizio)) * 100);
      $("#s-barra").hidden = false;
      $("#s-barra > i").style.width = pct + "%";
    } else {
      $("#s-prossima").textContent = "Sei alla tariffa più alta: " + C.euro(C.tariffa(d.fasce, d.stasera.persone + 1)) + " a persona! 🔥";
      $("#s-barra").hidden = true;
    }

    // settimana di benvenuto: tariffe moltiplicate, con accanto quelle di sempre
    if (d.bonusFino) {
      const quanto = Number(d.bonusPer) === 2 ? "doppie" : "×" + String(d.bonusPer).replace(".", ",");
      $("#bonus").innerHTML = "🔥 <b>Settimana di benvenuto:</b> tariffe " + quanto + " fino a " +
        C.esc(C.dataBreve(d.bonusFino)) + " compreso";
      $("#bonus").hidden = false;
    } else {
      $("#bonus").hidden = true;
    }
    $("#fasce").innerHTML = C.descriviFasce(d.fasce).map(function (f, i) {
      const base = d.fasceBase && d.fasceBase[i] && Number(d.fasceBase[i].euro) !== Number(f.euro)
        ? '<s class="dim">' + C.euro(d.fasceBase[i].euro) + "</s> " : "";
      return '<li><span class="cresce">' + C.esc(f.testo) + "</span>" + base + '<span class="euro">' + C.euro(f.euro) + "</span></li>";
    }).join("");

    const v = d.validita || 1;
    $("#validita").hidden = v <= 1;
    $("#validita").textContent = "🎟️ I buoni dei tuoi clienti valgono " + v + " giorni: possono venire anche " +
      (v === 2 ? "domani sera" : "nelle " + (v - 1) + " sere dopo") + ", e il tavolo conta nella sera in cui si siedono.";

    $("#m-titolo").textContent = "📅 " + d.mese.nome.charAt(0).toUpperCase() + d.mese.nome.slice(1);
    $("#m-tavoli").textContent = d.mese.tavoli;
    $("#m-persone").textContent = d.mese.persone;
    $("#m-euro").textContent = C.euro(d.mese.euro);

    $("#t-maturato").textContent = C.euro(d.maturato);
    $("#t-pagato").textContent = C.euro(d.pagato);
    $("#t-dapagare").textContent = C.euro(d.daPagare);

    $("#ultimi").innerHTML = d.ultimi.length ? d.ultimi.map(function (u) {
      return '<li><div class="cresce"><b>' + u.persone + (u.persone === 1 ? " persona" : " persone") + "</b>" +
        '<div class="dim">' + C.nomeSera(u.sera) + " · " + C.ora(u.quando) + "</div></div>" +
        '<span class="euro">+' + C.euro(u.euro) + "</span></li>";
    }).join("") : '<li class="vuoto">Ancora nessun tavolo. Il primo è dietro l\'angolo! 💪</li>';

    $("#aggiornato").textContent = "Aggiornato alle " + C.ora(Date.now());
    controllaNuovi(d.ultimi);
  }

  /* ---------- festa quando arriva un tavolo (con l'app aperta) ---------- */
  const VISTO = "vdcpr_ultimo_visto";
  function controllaNuovi(ultimi) {
    const piuRecente = ultimi.length ? new Date(ultimi[0].quando).getTime() : 0;
    let visto = null;
    try { visto = localStorage.getItem(VISTO); } catch (e) {}
    if (visto !== null) {
      const nuovi = ultimi.filter(function (u) { return new Date(u.quando).getTime() > Number(visto); });
      if (nuovi.length) festa(nuovi);
    }
    if (visto === null || piuRecente > Number(visto)) {
      try { localStorage.setItem(VISTO, String(piuRecente)); } catch (e) {}
    }
  }
  function festa(nuovi) {
    const persone = nuovi.reduce(function (s, u) { return s + u.persone; }, 0);
    const euro = nuovi.reduce(function (s, u) { return s + Number(u.euro); }, 0);
    $("#festa-titolo").textContent = nuovi.length === 1 ? "È arrivato un tuo tavolo!" : "Sono arrivati " + nuovi.length + " tuoi tavoli!";
    $("#festa-testo").textContent = (nuovi.length === 1 ? "Tavolo da " : "In tutto ") + persone + (persone === 1 ? " persona" : " persone");
    $("#festa-euro").textContent = "+" + C.euro(euro);
    $("#festa").hidden = false;
    C.coriandoli();
    if (navigator.vibrate) navigator.vibrate([200, 100, 200, 100, 300]);
  }
  $("#festa-ok").addEventListener("click", function () { $("#festa").hidden = true; });

  /* ---------- notifiche anche ad app chiusa ---------- */
  const supportaPush = "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
  const suIphone = /iPhone|iPad|iPod/.test(navigator.userAgent);
  const installata = navigator.standalone === true || matchMedia("(display-mode: standalone)").matches;

  function b64ToU8(b64) {
    const s = atob((b64 + "=".repeat((4 - b64.length % 4) % 4)).replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(s, function (c) { return c.charCodeAt(0); });
  }
  async function iscrizione() {
    try {
      const reg = await navigator.serviceWorker.getRegistration();
      return reg ? await reg.pushManager.getSubscription() : null;
    } catch (e) { return null; }
  }

  async function statoAvvisi() {
    const testo = $("#avvisi-testo"), btn = $("#attiva-avvisi");
    $("#avvisi").classList.remove("attivi");
    btn.hidden = true;
    if (C.VETRINA) {   // per le riprese: come appare a chi le ha già attivate
      testo.textContent = "✅ Attive: ti arriva una notifica appena un tuo cliente si siede.";
      $("#avvisi").classList.add("attivi");
      return;
    }
    if (Store.DEMO) {
      testo.textContent = "Nella demo le notifiche non partono, ma con l'app aperta vedi lo stesso la festa quando arriva un tavolo.";
      return;
    }
    if (!supportaPush) {
      testo.innerHTML = suIphone && !installata
        ? "Su iPhone: tocca <b>Condividi</b> ↑ e poi <b>«Aggiungi alla schermata Home»</b>. Apri l'app da lì e attiva le notifiche."
        : "Questo telefono non riceve notifiche: tieni l'app aperta e ti avvisiamo qui.";
      return;
    }
    if (Notification.permission === "denied") {
      testo.textContent = "Le notifiche sono bloccate: riattivale dalle impostazioni del telefono per questa app.";
      return;
    }
    const sub = Notification.permission === "granted" ? await iscrizione() : null;
    if (sub) {
      testo.textContent = "✅ Attive: ti arriva una notifica appena un tuo cliente si siede.";
      $("#avvisi").classList.add("attivi");
      Store.salvaPush(chiave, sub.toJSON()).catch(function () {});   // la tengo fresca sul server
      return;
    }
    testo.textContent = "Ricevi una notifica appena un tuo cliente si siede, con quanto hai guadagnato.";
    btn.hidden = false;
  }

  $("#attiva-avvisi").addEventListener("click", async function () {
    const btn = this;
    btn.disabled = true;
    try {
      const permesso = await Notification.requestPermission();
      if (permesso === "granted") {
        const reg = await navigator.serviceWorker.register("sw.js");
        await navigator.serviceWorker.ready;
        let sub = await reg.pushManager.getSubscription();
        if (!sub) {
          sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64ToU8(await Store.chiavePush()) });
        }
        await Store.salvaPush(chiave, sub.toJSON());
        C.toast("Notifiche attivate! 🎉");
      }
    } catch (e) {
      C.toast(e.message || "Non sono riuscito ad attivarle", true);
    }
    btn.disabled = false;
    statoAvvisi();
  });

  async function aggiorna() {
    if (!chiave) return fuori();
    try {
      disegna(await Store.agente(chiave));
    } catch (e) {
      if (e.codice === "chiave") {
        try { localStorage.removeItem(SALVATA); } catch (er) {}
        chiave = null;
        fuori();
        C.toast("Questo link non è più valido: chiedine uno nuovo al ristorante", true);
      } else if (dati) {
        $("#aggiornato").textContent = "Senza connessione · ultimi dati delle " + C.ora(Date.now());
      } else {
        C.toast("Connessione assente, riprovo tra poco", true);
      }
    }
  }

  $("#pieno").addEventListener("click", function () {
    $("#qr-pieno").hidden = false;
    if (document.documentElement.requestFullscreen) document.documentElement.requestFullscreen().catch(function () {});
  });
  $("#qr-pieno").addEventListener("click", function () {
    $("#qr-pieno").hidden = true;
    if (document.fullscreenElement) document.exitFullscreen().catch(function () {});
  });
  $("#condividi").addEventListener("click", async function () {
    if (!dati) return;
    const url = C.urlGioca(dati.codice);
    if (navigator.share) {
      try { await navigator.share({ title: "Vico del Carmine · Tenta la Fortuna", url: url }); } catch (e) {}
    } else {
      try { await navigator.clipboard.writeText(url); C.toast("Link copiato"); } catch (e) { prompt("Il tuo link:", url); }
    }
  });

  $("#demo-bar").hidden = !Store.DEMO || C.VETRINA;
  if ("serviceWorker" in navigator && !Store.DEMO) navigator.serviceWorker.register("sw.js").catch(function () {});
  aggiorna().then(function () {
    if (dati) statoAvvisi();
    // vetrina con &festa=1: dopo 3 secondi "arriva" un tavolo da 3, per riprendere la festa
    if (dati && C.VETRINA && /[?&]festa=1/.test(location.search)) {
      setTimeout(async function () {
        try {
          const b = await Store.gioca(dati.codice, "VETRINA-" + Date.now());
          await Store.riscatta("1234", b.codice, 3);
          aggiorna();
        } catch (e) {}
      }, 3000);
    }
  });
  setInterval(function () { if (!document.hidden) aggiorna(); }, 15000);
  document.addEventListener("visibilitychange", function () { if (!document.hidden) aggiorna(); });
})();
