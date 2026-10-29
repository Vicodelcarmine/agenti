/* Pagina "Diventa agente": chi è interessato lascia nome e numero,
   il titolare trova la richiesta in Dashboard → Agenti e la approva. */

(function () {
  const C = Comune;
  $("#demo-bar").hidden = !Store.DEMO;

  // da quale canale arriva (link ?ref=esn-florentia): resta anche se ricarica la pagina.
  // Sulla pagina delle guide, senza link, il canale è "guide".
  const CANALE = (function () {
    const q = new URLSearchParams(location.search);
    const pulito = function (c) { c = String(c || "").trim().toLowerCase(); return /^[a-z0-9][a-z0-9:._-]{0,39}$/.test(c) ? c : ""; };
    const chiave = "vdcpr_canale_" + (location.pathname.indexOf("/guide/") >= 0 ? "guide" : "pr");
    let c = pulito(q.get("ref") || q.get("utm_source"));
    try {
      if (c) sessionStorage.setItem(chiave, c); else c = sessionStorage.getItem(chiave) || "";
    } catch (e) {}
    return c || (location.pathname.indexOf("/guide/") >= 0 ? "guide" : "");
  })();

  $("#f").addEventListener("submit", async function (e) {
    e.preventDefault();
    const nome = $("#nome").value.trim();
    const tel = $("#tel").value.trim();
    if (nome.length < 2) { C.toast("Scrivi il tuo nome", true); $("#nome").focus(); return; }
    if (tel.replace(/\D/g, "").length < 8) { C.toast("Controlla il numero di telefono", true); $("#tel").focus(); return; }
    if (!$("#ok").checked) { C.toast("Serve il consenso per poterti ricontattare", true); return; }

    const btn = $("#invia");
    btn.disabled = true;
    btn.textContent = "Invio…";
    try {
      // se la trappola è piena è un programma, non una persona: fingo che sia andata
      if (!$("#sito").value) await Store.candidatura(nome, tel, $("#ruolo").value, $("#note").value, CANALE);
      const avviso = document.getElementById("toast");
      if (avviso) avviso.className = "";
      $("#f").hidden = true;
      $("#grazie-nome").textContent = nome.split(/\s+/)[0];
      $("#grazie").hidden = false;
      $("#modulo").scrollIntoView({ behavior: "smooth", block: "center" });
    } catch (er) {
      C.toast(er.message || "Non è andata: riprova tra poco", true);
      btn.disabled = false;
      btn.textContent = "Invia la richiesta";
    }
  });
})();
