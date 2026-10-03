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

## Dati

**Supabase del Vico del Carmine** (lo stesso del menu), con tabelle e funzioni separate che hanno il prefisso `pr_`.

- `supabase/01-agenti.sql`: tabelle e funzioni. Si può rieseguire e non cancella niente.
- `supabase/functions/pr-notifica`: invia le notifiche (Verify JWT: OFF). Le chiavi delle notifiche le crea da sola nella tabella `pr_config`.
- **PIN della dashboard**: è il PIN da titolare del menu (`app_secrets.pw_titolare`).
- **Demo**: con `?demo=1` nell'indirizzo si usano dati finti salvati nel browser (PIN demo `1234`); `?demo=0` per tornare ai dati veri.

## Per i telefoni degli agenti

- **iPhone**: aprire il link, toccare Condividi → "Aggiungi alla schermata Home", aprire l'app da lì e attivare le notifiche.
- **Android**: basta aprire il link e attivare le notifiche.

## File

- `gioca/`, `agente/` (con `sw.js` per le notifiche), `titolare/`: le tre pagine.
- `assets/js/comune.js`: orari di Firenze, calcolo delle provvigioni, QR, coriandoli.
- `assets/js/store.js`: le chiamate a Supabase (e la versione demo).
- `assets/js/qr.js`: generatore di QR (MIT), copiato dal menu.
