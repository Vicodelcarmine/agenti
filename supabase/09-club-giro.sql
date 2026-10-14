-- =============================================================================
-- CLUB DEL VICO — l'orologio: il giro di ogni mattina e l'invio degli avvisi.
-- Si esegue DOPO 08-club-avvisi.sql e DOPO aver creato la funzione "club-invia".
--   · ogni giorno alle 9:00 UTC (le 11 in Italia d'estate, le 10 d'inverno):
--     club_giro() crea regali di compleanno e offerte, poi chiama club-invia;
--   · ogni 10 minuti: club-invia manda gli avvisi rimasti in coda (prove del
--     titolare, codici via email…). Se la coda è vuota non fa niente.
-- La chiave qui sotto è quella pubblica del sito: club-invia non fa altro che
-- mandare i messaggi già in coda, quindi chiamarla in più non fa danni.
-- Si può rieseguire: i due lavori vengono sostituiti, non duplicati.
-- =============================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule('club-giro', '0 9 * * *', $giro$
  select public.club_giro();
  select net.http_post(
    url     := 'https://agbvmhpktilpaoabjkre.supabase.co/functions/v1/club-invia',
    body    := '{"azione":"invia"}'::jsonb,
    headers := '{"Content-Type":"application/json","apikey":"sb_publishable_2O5l8ZbQqGnwDXwxZnsZ2Q_0Mt1V8T7"}'::jsonb);
$giro$);

select cron.schedule('club-invia', '*/10 * * * *', $invia$
  select net.http_post(
    url     := 'https://agbvmhpktilpaoabjkre.supabase.co/functions/v1/club-invia',
    body    := '{"azione":"invia"}'::jsonb,
    headers := '{"Content-Type":"application/json","apikey":"sb_publishable_2O5l8ZbQqGnwDXwxZnsZ2Q_0Mt1V8T7"}'::jsonb)
   where exists (select 1 from public.club_messaggi where inviato is null);
$invia$);
