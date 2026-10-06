# Vico Agenti

Sistema per i PR ("agenti") del Vico del Carmine.

1. **L'agente** mostra il suo QR personale (`agente/`, si apre dal suo link `agente/?k=…`).
2. **Il passante** lo inquadra, gira la slot e vince un premio per tutto il tavolo. Riceve un buono con QR, valido solo quella sera, più la mappa per arrivare (`gioca/?a=CODICE`).
3. **Il titolare** inquadra il buono (anche con la fotocamera normale del telefono, che apre `titolare/?b=CODICE`), scrive quante persone ci sono al tavolo e lo riscatta. La provvigione si calcola da sola.
4. **L'agente** riceve una notifica, "È arrivato un tuo tavolo: +9 €", anche ad app chiusa se ha attivato le notifiche. Con l'app aperta vede anche la festa a schermo.

## Provvigioni

Si paga a persona, a scaglioni, e ogni sera si riparte da zero.

Tariffe standard:
- dalla 1ª alla 10ª persona: 2 €
- dalla 11ª alla 20ª persona: 3 €
- dalla 21ª persona in poi: 4 €

Ogni agente può avere tariffe sue: si cambiano dalla dashboard.

**Settimana di benvenuto:** i primi 7 giorni da quando l'agente è stato creato, le sue tariffe raddoppiano da sole (4, 6, 8 €).
Giorni e moltiplicatore si cambiano in Dashboard → Altro.

**Giorni di pausa:** di base il sabato, perché siamo già al completo. Quella sera il gioco non dà buoni e l'agente lo vede nell'app.
I giorni si scelgono in Dashboard → Altro.

## Dati

**Supabase del Vico del Carmine** (lo stesso del menu), con tabelle e funzioni separate che hanno il prefisso `pr_`.

- `supabase/01-agenti.sql`: tabelle e funzioni, sempre aggiornato. Si può rieseguire e non cancella niente.
- `supabase/02-bonus-pausa.sql`: la sola modifica del 06/10/2026 (settimana di benvenuto e pausa), già compresa nel file 01.
- `supabase/functions/pr-notifica`: invia le notifiche (Verify JWT: OFF). Le chiavi delle notifiche le crea da sola nella tabella `pr_config`.
- **PIN della dashboard**: è il PIN da titolare del menu (`app_secrets.pw_titolare`).
- **Demo**: con `?demo=1` nell'indirizzo si usano dati finti salvati nel browser (PIN demo `1234`); `?demo=0` per tornare ai dati veri.
- **Vetrina** (per le riprese del video): `?vetrina=1`. Dati finti "belli", nessun nome, logo o mappa del ristorante, e la dashboard entra senza PIN.
  - Il QR del buono si può toccare per aprire la dashboard.
  - `agente/?vetrina=1&k=VETRINAMARCO&festa=1` fa arrivare un tavolo dopo 3 secondi.
  - `?vetrina=0` per uscire.

## Per i telefoni degli agenti

- **iPhone**: aprire il link, toccare Condividi → "Aggiungi alla schermata Home", aprire l'app da lì e attivare le notifiche.
- **Android**: basta aprire il link e attivare le notifiche.

## File

- `gioca/`, `agente/` (con `sw.js` per le notifiche), `titolare/`: le tre pagine.
- `assets/js/comune.js`: orari di Firenze, calcolo delle provvigioni, QR, coriandoli.
- `assets/js/store.js`: le chiamate a Supabase (e la versione demo).
- `assets/js/qr.js`: generatore di QR (MIT), copiato dal menu.
