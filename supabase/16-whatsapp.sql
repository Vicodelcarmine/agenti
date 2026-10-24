-- =============================================================================
-- WHATSAPP DI CONFERMA — si esegue DOPO 15-prenota-facile.sql
-- Dopo ogni prenotazione dal sito parte un WhatsApp (modello approvato da Meta) con la
-- conferma; al cliente nuovo anche il prosecco di benvenuto, da mostrare al cameriere.
-- WhatsApp ci dice se il messaggio è stato consegnato e letto: consegnato = numero giusto.
-- · pren_impostazioni.whatsapp acceso → le prenotazioni nascono con wa_stato = 'in_coda'
-- · funzione "whatsapp-invia" (Verify JWT: OFF) le manda: la chiama il sito dopo la
--   prenotazione, e l'orologio qui sotto ogni 2 minuti se è rimasto qualcosa in coda
-- · funzione "whatsapp-webhook" (Verify JWT: OFF) riceve da Meta consegnato / letto / errore
-- I segreti NON stanno qui: WHATSAPP_TOKEN, WHATSAPP_APP_SECRET e WHATSAPP_VERIFICA sono
-- "Secrets" delle Edge Functions su Supabase. Qui solo i dati non segreti (wa_config).
-- Si può rieseguire.
-- =============================================================================

create table if not exists public.wa_config (
  id            int primary key default 1 check (id = 1),
  numero_id     text not null default '',                       -- "Phone number ID" del numero su WhatsApp Cloud API
  modello_nuovo text not null default 'prenotazione_benvenuto', -- modello per il cliente nuovo (con il prosecco)
  modello       text not null default 'prenotazione_confermata',
  ultimo_errore text,
  ultimo_invio  timestamptz
);
insert into public.wa_config (id) values (1) on conflict (id) do nothing;
alter table public.wa_config enable row level security;


-- ---------- per le funzioni (solo service_role) ----------

-- prende le conferme da mandare (e le segna "in invio", così non partono due volte)
create or replace function public.wa_prendi(n int) returns jsonb
language sql volatile security definer set search_path = public as $$
  with prese as (
    update public.pren_prenotazioni p set wa_stato = 'invio', wa_quando = now()
     where p.id in (select id from public.pren_prenotazioni
                     where wa_stato = 'in_coda' or (wa_stato = 'invio' and wa_quando < now() - interval '10 minutes')
                     order by creato limit n for update skip locked)
    returning p.*)
  select jsonb_build_object(
    'config', (select jsonb_build_object('numeroId', numero_id, 'modelloNuovo', modello_nuovo, 'modello', modello)
                 from public.wa_config where id = 1),
    'messaggi', coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'telefono', p.telefono, 'nome', split_part(p.nome, ' ', 1), 'codice', p.codice,
      'lingua', case when p.lingua = 'it' then 'it' else 'en' end,
      'giorno', public.club_data(p.sera, case when p.lingua = 'it' then 'it' else 'en' end),
      'ora', p.turno, 'persone', public.club_persone(p.persone, case when p.lingua = 'it' then 'it' else 'en' end),
      'benvenuto', case when p.benvenuto > 0
                        then public.club_persone(p.benvenuto, case when p.lingua = 'it' then 'it' else 'en' end) end,
      'stato', p.stato) order by p.creato) filter (where p.id is not null), '[]'::jsonb))
    from prese p
$$;

-- com'è andato l'invio (dalla funzione)
create or replace function public.wa_esito(p_id uuid, p_wa_id text, p_errore text) returns void
language sql volatile security definer set search_path = public as $$
  update public.pren_prenotazioni
     set wa_stato = case when coalesce(p_wa_id, '') <> '' then 'inviato' else 'errore' end,
         wa_id = nullif(p_wa_id, ''), wa_errore = left(p_errore, 300), wa_quando = now()
   where id = p_id;
  update public.wa_config set ultimo_invio = now(),
         ultimo_errore = case when coalesce(p_wa_id, '') = '' then left(p_errore, 300) else ultimo_errore end
   where id = 1;
$$;

-- quello che dice WhatsApp dopo (dal webhook): sent, delivered, read, failed. Si va solo avanti.
create or replace function public.wa_aggiorna(p_wa_id text, p_stato text, p_errore text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare nuovo text := case p_stato when 'sent' then 'inviato' when 'delivered' then 'consegnato'
                                    when 'read' then 'letto' when 'failed' then 'errore' end;
        ordine text[] := array['inviato', 'consegnato', 'letto'];
begin
  if nuovo is null or coalesce(p_wa_id, '') = '' then return false; end if;
  update public.pren_prenotazioni p
     set wa_stato = nuovo, wa_errore = case when nuovo = 'errore' then left(p_errore, 300) else p.wa_errore end,
         wa_quando = now()
   where p.wa_id = p_wa_id
     and (nuovo = 'errore' and p.wa_stato is distinct from 'letto' and p.wa_stato is distinct from 'consegnato'
          or array_position(ordine, nuovo) > coalesce(array_position(ordine, p.wa_stato), 0));
  return found;
end $$;

revoke execute on function public.wa_prendi(int)               from public, anon, authenticated;
revoke execute on function public.wa_esito(uuid, text, text)   from public, anon, authenticated;
revoke execute on function public.wa_aggiorna(text, text, text) from public, anon, authenticated;
grant execute on function public.wa_prendi(int), public.wa_esito(uuid, text, text), public.wa_aggiorna(text, text, text)
  to service_role;


-- ================= TITOLARE (dashboard, col PIN) =================
create or replace function public.wa_impostazioni(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.wa_config; imp public.pren_impostazioni;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into c from public.wa_config where id = 1;
  select * into imp from public.pren_impostazioni where id = 1;
  return jsonb_build_object(
    'attivo', imp.whatsapp, 'configurato', c.numero_id <> '', 'numeroId', c.numero_id,
    'modelloNuovo', c.modello_nuovo, 'modello', c.modello, 'benvenutoMax', imp.benvenuto_max,
    'ultimoInvio', c.ultimo_invio, 'ultimoErrore', c.ultimo_errore,
    'settimana', (select jsonb_build_object(
                    'inviati', count(*) filter (where wa_stato in ('inviato', 'consegnato', 'letto')),
                    'verificati', count(*) filter (where wa_stato in ('consegnato', 'letto')),
                    'errori', count(*) filter (where wa_stato = 'errore'))
                    from public.pren_prenotazioni where fonte = 'sito' and creato > now() - interval '7 days'));
end $$;

create or replace function public.wa_salva(p_pin text, p_dati jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  if p_dati ? 'numeroId' and coalesce(p_dati->>'numeroId', '') !~ '^[0-9]{0,30}$' then
    raise exception 'Il Phone number ID è fatto solo di cifre' using hint = 'numero';
  end if;
  if coalesce((p_dati->>'attivo')::boolean, false)
     and coalesce(p_dati->>'numeroId', (select numero_id from public.wa_config where id = 1), '') = '' then
    raise exception 'Prima collega il numero WhatsApp' using hint = 'numero';
  end if;
  update public.wa_config set
    numero_id     = coalesce(p_dati->>'numeroId', numero_id),
    modello_nuovo = coalesce(nullif(trim(p_dati->>'modelloNuovo'), ''), modello_nuovo),
    modello       = coalesce(nullif(trim(p_dati->>'modello'), ''), modello)
   where id = 1;
  update public.pren_impostazioni set
    whatsapp      = coalesce((p_dati->>'attivo')::boolean, whatsapp),
    benvenuto_max = coalesce((p_dati->>'benvenutoMax')::int, benvenuto_max)
   where id = 1;
  return public.wa_impostazioni(p_pin);
exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'Numeri non validi' using hint = 'numeri';
end $$;

grant execute on function public.wa_impostazioni(text), public.wa_salva(text, jsonb) to anon, authenticated;


-- ================= OROLOGIO =================
-- se la chiamata del sito a "whatsapp-invia" non è partita, ci pensa questo giro ogni 2 minuti
select cron.schedule('whatsapp-invia', '*/2 * * * *', $wa$
  select net.http_post(
    url     := 'https://agbvmhpktilpaoabjkre.supabase.co/functions/v1/whatsapp-invia',
    body    := '{"azione":"invia"}'::jsonb,
    headers := '{"Content-Type":"application/json","apikey":"sb_publishable_2O5l8ZbQqGnwDXwxZnsZ2Q_0Mt1V8T7"}'::jsonb)
   where exists (select 1 from public.pren_prenotazioni where wa_stato = 'in_coda');
$wa$);
