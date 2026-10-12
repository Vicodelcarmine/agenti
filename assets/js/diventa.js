/* Pagina "Diventa agente": chi è interessato lascia nome e numero,
   il titolare trova la richiesta in Dashboard → Agenti e la approva. */

(function () {
  const C = Comune;
  $("#demo-bar").hidden = !Store.DEMO;

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
      if (!$("#sito").value) await Store.candidatura(nome, tel, $("#ruolo").value, $("#note").value);
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
