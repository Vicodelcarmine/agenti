/* Funzioni comuni alle tre pagine: orari di Firenze, calcolo provvigioni,
   QR, formattazione. Nessuna chiamata a internet. */

const Comune = (function () {
  // cartella principale del sito (quella che contiene gioca/, agente/, titolare/)
  const RADICE = new URL("../../", document.currentScript.src).href;

  const RISTORANTE = {
    nome: "Vico del Carmine",
    indirizzo: "Via Pisana 40/r · San Frediano · Firenze",
    mappa: "Vico del Carmine, Via Pisana 40r, Firenze",
    menu: "https://vicodelcarmine.github.io/menu/",
    whatsapp: "393514002503",
  };

  const FASCE_STANDARD = [
    { fino: 10, euro: 2 },
    { fino: 20, euro: 3 },
    { fino: null, euro: 4 },
  ];

  /* ---------- ora di Firenze, qualunque sia il fuso del telefono ---------- */
  const fmtRoma = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Europe/Rome", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", hourCycle: "h23",
  });
  function romaParti(d) {
    const p = {};
    fmtRoma.formatToParts(d).forEach(function (x) { p[x.type] = x.value; });
    return { y: +p.year, m: +p.month, g: +p.day, h: +p.hour, min: +p.minute };
  }
  // l'istante in cui a Firenze l'orologio segna y-m-g h:min
  function daRoma(y, m, g, h, min) {
    const ipotesi = Date.UTC(y, m - 1, g, h, min);
    const p = romaParti(new Date(ipotesi));
    const visto = Date.UTC(p.y, p.m - 1, p.g, p.h, p.min);
    return new Date(ipotesi - (visto - ipotesi));
  }
  const due = function (n) { return String(n).padStart(2, "0"); };

  // "La sera" a cui appartiene un momento: fino alle 6 del mattino conta ancora la sera prima.
  function sera(d) {
    const p = romaParti(new Date((d ? new Date(d) : new Date()).getTime() - 6 * 3600e3));
    return p.y + "-" + due(p.m) + "-" + due(p.g);
  }
  // quando scadono i buoni di quella sera (es. "23:30"; "01:00" = dopo mezzanotte)
  function scadenza(laSera, chiusura) {
    const [y, m, g] = laSera.split("-").map(Number);
    const [h, min] = chiusura.split(":").map(Number);
    const giorno = new Date(Date.UTC(y, m - 1, g + (h < 6 ? 1 : 0)));
    return daRoma(giorno.getUTCFullYear(), giorno.getUTCMonth() + 1, giorno.getUTCDate(), h, min);
  }
  function ora(d) { const p = romaParti(new Date(d)); return due(p.h) + ":" + due(p.min); }
  const GIORNI = ["dom", "lun", "mar", "mer", "gio", "ven", "sab"];
  const MESI = ["gen", "feb", "mar", "apr", "mag", "giu", "lug", "ago", "set", "ott", "nov", "dic"];
  function nomeSera(laSera) {
    const [y, m, g] = laSera.split("-").map(Number);
    const d = new Date(Date.UTC(y, m - 1, g));
    if (laSera === sera()) return "Stasera";
    return GIORNI[d.getUTCDay()] + " " + g + " " + MESI[m - 1];
  }
  const NOMI_MESI = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio",
    "agosto", "settembre", "ottobre", "novembre", "dicembre"];
  function nomeMese(laSera) { return NOMI_MESI[+laSera.slice(5, 7) - 1]; }

  /* ---------- provvigioni a scaglioni, si riparte da zero ogni sera ---------- */
  function tariffa(fasce, persona) {
    for (const f of fasce) if (f.fino == null || persona <= f.fino) return f.euro;
    return fasce[fasce.length - 1].euro;
  }
  // gia = persone già portate stasera, n = persone del tavolo
  function provvigione(fasce, gia, n) {
    let euro = 0;
    const righe = [];
    for (let k = gia + 1; k <= gia + n; k++) {
      const e = tariffa(fasce, k);
      euro += e;
      const ultima = righe[righe.length - 1];
      if (ultima && ultima.euro === e) { ultima.a = k; ultima.n++; }
      else righe.push({ da: k, a: k, n: 1, euro: e });
    }
    return { euro: euro, righe: righe };
  }
  function spiegaRighe(righe) {
    return righe.map(function (r) {
      const chi = r.da === r.a ? r.da + "ª persona" : r.da + "ª–" + r.a + "ª";
      return chi + " a " + euro(r.euro);
    }).join(" · ");
  }
  // quante persone mancano prima di passare alla fascia dopo (null se è già all'ultima)
  function prossimaFascia(fasce, persone) {
    const i = fasce.findIndex(function (f) { return f.fino == null || persone < f.fino; });
    if (i < 0 || i >= fasce.length - 1) return null;
    return { mancano: fasce[i].fino - persone, euro: fasce[i + 1].euro };
  }
  function descriviFasce(fasce) {
    let da = 1;
    return fasce.map(function (f) {
      const t = f.fino == null ? "dalla " + da + "ª persona in poi" : "dalla " + da + "ª alla " + f.fino + "ª persona";
      if (f.fino != null) da = f.fino + 1;
      return { testo: t, euro: f.euro };
    });
  }

  /* ---------- varie ---------- */
  function euro(n) {
    n = Math.round(n * 100) / 100;
    return (Number.isInteger(n) ? String(n) : n.toFixed(2).replace(".", ",")) + " €";
  }
  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }
  function disegnaQR(testo) {
    const q = qrcode(0, "M");
    q.addData(testo);
    q.make();
    return q.createSvgTag({ cellSize: 4, margin: 0, scalable: true });
  }
  function codiceBello(c) { return c.slice(0, 3) + " " + c.slice(3); }
  function pulisciCodice(testo) {
    testo = String(testo || "").trim();
    try { const u = new URL(testo); if (u.searchParams.get("b")) testo = u.searchParams.get("b"); } catch (e) {}
    return testo.toUpperCase().replace(/[^A-Z0-9]/g, "");
  }
  function casuale(n, alfabeto) {
    alfabeto = alfabeto || "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    const b = new Uint32Array(n);
    crypto.getRandomValues(b);
    let s = "";
    for (let i = 0; i < n; i++) s += alfabeto[b[i] % alfabeto.length];
    return s;
  }
  function dispositivo() {
    let id = null;
    try { id = localStorage.getItem("vdcpr_dispositivo"); } catch (e) {}
    if (!id) {
      id = casuale(12);
      try { localStorage.setItem("vdcpr_dispositivo", id); } catch (e) {}
    }
    return id;
  }

  const urlGioca = function (codiceAgente) { return RADICE + "gioca/?a=" + codiceAgente; };
  const urlBuono = function (codice) { return RADICE + "titolare/?b=" + codice; };
  const urlAgente = function (chiave) { return RADICE + "agente/?k=" + chiave; };
  const urlStrada = "https://www.google.com/maps/dir/?api=1&travelmode=walking&destination=" +
    encodeURIComponent(RISTORANTE.mappa);
  const urlMappa = "https://www.google.com/maps?output=embed&q=" + encodeURIComponent(RISTORANTE.mappa);

  function coriandoli() {
    let box = document.getElementById("coriandoli");
    if (!box) {
      box = document.createElement("div");
      box.id = "coriandoli"; box.className = "coriandoli"; box.setAttribute("aria-hidden", "true");
      document.body.appendChild(box);
    }
    const colori = ["#e6b24a", "#c8102e", "#edcf94", "#ffffff", "#86b64a", "#d13b2f"];
    for (let i = 0; i < 60; i++) {
      const c = document.createElement("i");
      c.style.left = Math.random() * 100 + "%";
      c.style.background = colori[i % colori.length];
      c.style.animationDelay = Math.random() * 1.5 + "s";
      c.style.animationDuration = 2 + Math.random() * 2 + "s";
      c.style.borderRadius = Math.random() > .5 ? "50%" : "2px";
      const lato = 6 + Math.random() * 8;
      c.style.width = c.style.height = lato + "px";
      box.appendChild(c);
    }
    setTimeout(function () { box.innerHTML = ""; }, 4500);
  }

  let timerToast;
  function toast(msg, errore) {
    let t = document.getElementById("toast");
    if (!t) { t = document.createElement("div"); t.id = "toast"; document.body.appendChild(t); }
    t.textContent = msg;
    t.className = "on" + (errore ? " errore" : "");
    clearTimeout(timerToast);
    timerToast = setTimeout(function () { t.className = errore ? "errore" : ""; }, errore ? 4200 : 2600);
  }

  return {
    RADICE, RISTORANTE, FASCE_STANDARD,
    sera, scadenza, ora, nomeSera, nomeMese,
    tariffa, provvigione, spiegaRighe, prossimaFascia, descriviFasce,
    euro, esc, disegnaQR, codiceBello, pulisciCodice, casuale, dispositivo,
    urlGioca, urlBuono, urlAgente, urlStrada, urlMappa, toast, coriandoli,
  };
})();

const $ = function (sel, dentro) { return (dentro || document).querySelector(sel); };
const $$ = function (sel, dentro) { return Array.from((dentro || document).querySelectorAll(sel)); };
