-- =============================================================================
-- WHATSAPP — IL DIALOGO DOPO LA PRENOTAZIONE (si esegue DOPO 16-whatsapp.sql)
-- 1. Conferma (modello) al cliente nuovo: "rispondi CIAO per attivare il tuo regalo".
-- 2. Il cliente risponde (qualsiasi messaggio): numero verificato, regalo attivato →
--    subito "🥂 il prosecco ti aspetta…" e, 3 ore dopo (mai tra le 23 e le 10: alle 10),
--    l'invito al Club. Sono messaggi liberi: dentro le 24 ore dalla sua risposta, gratis.
-- 3. Il giorno dopo la cena, alle 12:30: il voto (modello voto_serata, tasti 5…1) a chi
--    ha prenotato dal sito, ha il numero verificato e non ha annullato.
-- 4. Voto 4-5: grazie + link alle recensioni Google. 1-3: "cosa non è andato?"; la sua
--    risposta arriva al titolare (notifica) e nel cruscotto.
-- 5. STOP: niente più messaggi (START per tornare). Ogni altro messaggio va al titolare.
-- Tutto passa dalla coda wa_uscita; la funzione "whatsapp-invia" la svuota, la funzione
-- "whatsapp-webhook" chiama wa_ricevi per ogni messaggio in arrivo.
-- Si può rieseguire.
-- =============================================================================

-- ---------- tabelle ----------
alter table public.wa_config
  add column if not exists modello_voto    text   not null default 'voto_serata',
  add column if not exists lingue          text[] not null default '{it}',     -- lingue dei modelli approvate
  add column if not exists link_recensioni text   not null default '',
  add column if not exists club_dopo_ore   int    not null default 3 check (club_dopo_ore between 0 and 20),
  add column if not exists voto_ora        text   not null default '12:30';

alter table public.pren_prenotazioni
  add column if not exists wa_attivato timestamptz,          -- il cliente ha risposto: regalo attivato
  add column if not exists voto        int check (voto between 1 and 5),
  add column if not exists voto_quando timestamptz;

create table if not exists public.wa_contatti (
  telefono  text primary key,                               -- +39…
  stop      boolean not null default false,                 -- ha scritto STOP
  ultimo_in timestamptz,                                    -- ultimo messaggio suo: da lì 24 ore per scrivergli libero
  creato    timestamptz not null default now()
);

create table if not exists public.wa_uscita (
  id           bigserial primary key,
  telefono     text not null,
  prenotazione uuid references public.pren_prenotazioni(id) on delete set null,
  tipo         text not null check (tipo in ('prosecco', 'club', 'voto', 'grazie', 'basso', 'stop', 'start', 'risposta')),
  modello      text,                                         -- se è un modello approvato
  parametri    jsonb,
  testo        text,                                         -- se è un messaggio libero
  lingua       text not null default 'it',
  quando       timestamptz not null default now(),           -- non prima di
  stato        text not null default 'in_coda'
               check (stato in ('in_coda', 'invio', 'inviato', 'consegnato', 'letto', 'errore', 'saltato')),
  wa_id        text,
  errore       text,
  creato       timestamptz not null default now()
);
create index if not exists wa_uscita_coda on public.wa_uscita (quando) where stato = 'in_coda';
create index if not exists wa_uscita_wa   on public.wa_uscita (wa_id);
create index if not exists wa_uscita_pren on public.wa_uscita (prenotazione, tipo);

create table if not exists public.wa_entrata (
  id           bigserial primary key,
  wa_id        text unique not null,
  telefono     text not null,
  nome         text not null default '',                     -- il nome sul suo profilo WhatsApp
  testo        text not null default '',
  tipo         text not null default 'testo' check (tipo in ('attiva', 'voto', 'testo', 'stop', 'start')),
  prenotazione uuid references public.pren_prenotazioni(id) on delete set null,
  quando       timestamptz not null default now(),
  letto        boolean not null default false
);
create index if not exists wa_entrata_quando on public.wa_entrata (quando desc);

alter table public.wa_contatti enable row level security;
alter table public.wa_uscita   enable row level security;
alter table public.wa_entrata  enable row level security;

-- gli avvisi al titolare possono essere anche i messaggi WhatsApp dei clienti
alter table public.pren_avvisi alter column prenotazione drop not null;
alter table public.pren_avvisi add column if not exists titolo text, add column if not exists testo text;
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.pren_avvisi'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%tipo%'
  loop
    execute format('alter table public.pren_avvisi drop constraint %I', c);
  end loop;
end $$;
alter table public.pren_avvisi add constraint pren_avvisi_tipo_check check (tipo in ('nuova', 'annullata', 'whatsapp'));

create or replace function public.pren_prendi_avvisi(n int) returns jsonb
language sql volatile security definer set search_path = public as $$
  with presi as (
    update public.pren_avvisi a set inviato = now()
     where a.id in (select id from public.pren_avvisi where inviato is null order by creato limit n for update skip locked)
    returning a.*)
  select jsonb_build_object(
    'avvisi', coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'tipo', a.tipo, 'prenotazione', coalesce(p.id::text, 'wa-' || a.id),
      'titolo', coalesce(a.titolo, case when a.tipo = 'nuova' then '📅 Nuova prenotazione' else '❌ Prenotazione annullata' end),
      'testo', coalesce(a.testo, p.nome || ' · ' || public.club_persone(p.persone, 'it') || ' · ' ||
               public.club_data(p.sera, 'it') || ' alle ' || p.turno ||
               case when p.benvenuto > 0 and a.tipo = 'nuova' then ' · 🥂 cliente nuovo: prosecco per ' || p.benvenuto else '' end ||
               case when p.nota <> '' and a.tipo = 'nuova' then ' · «' || left(p.nota, 60) || '»' else '' end))
      order by a.id) filter (where a.id is not null), '[]'::jsonb),
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', x.endpoint, 'sub', x.sub)) from public.pren_push x), '[]'::jsonb))
    from presi a left join public.pren_prenotazioni p on p.id = a.prenotazione
$$;
revoke execute on function public.pren_prendi_avvisi(int) from public, anon, authenticated;
grant execute on function public.pren_prendi_avvisi(int) to service_role;


-- ---------- i testi dei messaggi liberi ----------
create or replace function public.wa_testo(tipo text, lingua text, p public.pren_prenotazioni, link text) returns text
language sql stable set search_path = public as $$
  select case when lingua = 'it' then
    case tipo
      when 'prosecco' then '🥂 Regalo attivato! Il prosecco per ' || public.club_persone(greatest(p.benvenuto, 1), 'it') ||
                           ' ti aspetta ' || public.club_data(p.sera, 'it') || ' alle ' || p.turno ||
                           ': mostra questo messaggio al cameriere. A presto!'
      when 'club'     then '🎁 Un altro regalo ti aspetta! Entra gratis nel Club del Vico: un omaggio alla prossima visita e uno per il compleanno 👉 https://vicodelcarmine.it/club'
      when 'grazie'   then case when coalesce(link, '') <> ''
                             then 'Grazie di cuore! 🙏 Ci aiuti con una recensione su Google? Bastano 30 secondi 👉 ' || link
                             else 'Grazie di cuore! 🙏 Ti aspettiamo presto al Vico del Carmine.' end
      when 'basso'    then 'Ci dispiace 😔 Ci racconti cosa non è andato? Leggiamo tutto noi, di persona.'
      when 'stop'     then 'Ok, non ti scriveremo più. Per riattivare i messaggi scrivi START.'
      when 'start'    then 'Bentornato! 🙌 Riceverai di nuovo i nostri messaggi.'
    end
  else
    case tipo
      when 'prosecco' then '🥂 Gift unlocked! Prosecco for ' || public.club_persone(greatest(p.benvenuto, 1), 'en') ||
                           ' is waiting for you on ' || public.club_data(p.sera, 'en') || ' at ' || p.turno ||
                           ': show this message to the waiter. See you soon!'
      when 'club'     then '🎁 Another gift is waiting for you! Join the Vico Club for free: a treat on your next visit and one for your birthday 👉 https://vicodelcarmine.it/club'
      when 'grazie'   then case when coalesce(link, '') <> ''
                             then 'Thank you so much! 🙏 Would you help us with a Google review? It takes 30 seconds 👉 ' || link
                             else 'Thank you so much! 🙏 We hope to see you again soon at Vico del Carmine.' end
      when 'basso'    then 'We are sorry 😔 Could you tell us what went wrong? We read every message ourselves.'
      when 'stop'     then 'Ok, we won''t write to you anymore. To receive our messages again, write START.'
      when 'start'    then 'Welcome back! 🙌 You will receive our messages again.'
    end
  end
$$;

-- quando mandare l'invito al Club: N ore dopo, ma mai tra le 23 e le 10 (allora alle 10)
create or replace function public.wa_quando_club(da timestamptz, ore int) returns timestamptz
language sql stable set search_path = public as $$
  select case
    when extract(hour from (da + make_interval(hours => ore)) at time zone 'Europe/Rome') >= 23
      then (((da + make_interval(hours => ore)) at time zone 'Europe/Rome')::date + 1 + time '10:00') at time zone 'Europe/Rome'
    when extract(hour from (da + make_interval(hours => ore)) at time zone 'Europe/Rome') < 10
      then (((da + make_interval(hours => ore)) at time zone 'Europe/Rome')::date + time '10:00') at time zone 'Europe/Rome'
    else da + make_interval(hours => ore) end
$$;

-- la lingua per il cliente: la sua, se i modelli in quella lingua sono approvati
create or replace function public.wa_lingua(l text) returns text
language sql stable set search_path = public as $$
  select case when coalesce(l, 'it') = 'it' then 'it'
              when 'en' = any(coalesce((select lingue from public.wa_config where id = 1), '{}'::text[])) then 'en' else 'it' end
$$;


-- ---------- un messaggio in arrivo (dalla funzione whatsapp-webhook) ----------
create or replace function public.wa_ricevi(p_da text, p_nome text, p_testo text, p_wa_id text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  tel  text := public.club_telefono('+' || regexp_replace(coalesce(p_da, ''), '[^0-9]', '', 'g'));
  t    text := left(trim(coalesce(p_testo, '')), 2000);
  bassa text := lower(regexp_replace(t, '[^[:alnum:]]', '', 'g'));
  c    public.wa_contatti;
  p    public.pren_prenotazioni;
  cfg  public.wa_config;
  e    public.wa_entrata;
  v_tipo text := 'testo';
  ling text;
  avvisa boolean := true;
  v    int;
begin
  if tel is null or coalesce(p_wa_id, '') = '' then return jsonb_build_object('ok', false); end if;
  insert into public.wa_entrata (wa_id, telefono, nome, testo) values (p_wa_id, tel, left(coalesce(p_nome, ''), 80), t)
  on conflict (wa_id) do nothing returning * into e;
  if e.id is null then return jsonb_build_object('ok', true, 'doppio', true); end if;     -- Meta lo manda due volte
  insert into public.wa_contatti (telefono, ultimo_in) values (tel, now())
  on conflict (telefono) do update set ultimo_in = now() returning * into c;
  select * into cfg from public.wa_config where id = 1;
  -- la sua prenotazione più recente dal sito (ultimi 30 giorni)
  select * into p from public.pren_prenotazioni
   where telefono = tel and fonte = 'sito' and creato > now() - interval '30 days'
   order by creato desc limit 1;
  ling := public.wa_lingua(p.lingua);

  if bassa in ('stop', 'basta', 'stopp') then
    v_tipo := 'stop';
    update public.wa_contatti set stop = true where telefono = tel;
    insert into public.wa_uscita (telefono, prenotazione, tipo, testo, lingua)
    values (tel, p.id, 'stop', public.wa_testo('stop', ling, p, null), ling);
  elsif bassa in ('start', 'riattiva') then
    v_tipo := 'start';
    update public.wa_contatti set stop = false where telefono = tel;
    insert into public.wa_uscita (telefono, prenotazione, tipo, testo, lingua)
    values (tel, p.id, 'start', public.wa_testo('start', ling, p, null), ling);
  elsif c.stop then
    v_tipo := 'testo';                                     -- ha detto STOP: niente risposte automatiche
  elsif p.id is not null and p.voto is null and bassa ~ '^[1-5]$'
        and exists (select 1 from public.wa_uscita where prenotazione = p.id and tipo = 'voto'
                     and stato in ('inviato', 'consegnato', 'letto')) then
    v_tipo := 'voto';
    v := bassa::int;
    update public.pren_prenotazioni set voto = v, voto_quando = now() where id = p.id;
    insert into public.wa_uscita (telefono, prenotazione, tipo, testo, lingua)
    values (tel, p.id, case when v >= 4 then 'grazie' else 'basso' end,
            public.wa_testo(case when v >= 4 then 'grazie' else 'basso' end, ling, p, cfg.link_recensioni), ling);
    avvisa := v <= 3;                                      -- i voti bassi il titolare li vuole sapere subito
  elsif p.id is not null and p.benvenuto > 0 and p.wa_attivato is null and p.stato = 'confermata'
        and p.sera >= public.pren_oggi() then
    v_tipo := 'attiva';                                    -- ha risposto alla conferma: regalo attivato
    avvisa := false;
    update public.pren_prenotazioni set wa_attivato = now(),
           wa_stato = case when wa_stato in ('inviato', 'consegnato', 'invio', 'in_coda') then 'letto' else wa_stato end
     where id = p.id;
    insert into public.wa_uscita (telefono, prenotazione, tipo, testo, lingua)
    values (tel, p.id, 'prosecco', public.wa_testo('prosecco', ling, p, null), ling);
    if not exists (select 1 from public.club_iscritti where telefono = tel) then
      insert into public.wa_uscita (telefono, prenotazione, tipo, testo, lingua, quando)
      values (tel, p.id, 'club', public.wa_testo('club', ling, p, null), ling, public.wa_quando_club(now(), cfg.club_dopo_ore));
    end if;
  end if;

  update public.wa_entrata set tipo = v_tipo, prenotazione = p.id where id = e.id;
  if avvisa and v_tipo not in ('stop', 'start') then
    insert into public.pren_avvisi (prenotazione, tipo, titolo, testo)
    values (p.id, 'whatsapp',
            case when v_tipo = 'voto' then '⭐ Voto ' || v || ' da ' || coalesce(nullif(p.nome, ''), nullif(p_nome, ''), tel)
                 else '💬 WhatsApp da ' || coalesce(nullif(p.nome, ''), nullif(p_nome, ''), tel) end,
            case when v_tipo = 'voto' then 'Gli abbiamo chiesto cosa non è andato: la risposta arriva qui.' else left(t, 180) end);
  end if;
  return jsonb_build_object('ok', true, 'tipo', v_tipo,
                            'invia', exists (select 1 from public.wa_uscita where telefono = tel and stato = 'in_coda' and quando <= now()),
                            'avvisa', avvisa and v_tipo not in ('stop', 'start'));
end $$;


-- ---------- la coda: i messaggi da mandare adesso (dalla funzione whatsapp-invia) ----------
create or replace function public.wa_prendi_uscita(n int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare cfg public.wa_config; r record; lista jsonb := '[]'::jsonb; salta text;
begin
  select * into cfg from public.wa_config where id = 1;
  for r in
    select u.*, c.stop, c.ultimo_in, p.stato as pren_stato, p.voto, p.nome as pren_nome
      from public.wa_uscita u
      left join public.wa_contatti c on c.telefono = u.telefono
      left join public.pren_prenotazioni p on p.id = u.prenotazione
     where u.stato = 'in_coda' and u.quando <= now()
     order by u.quando limit n for update of u skip locked
  loop
    salta := case
      when coalesce(r.stop, false) and r.tipo not in ('stop', 'start') then 'ha scritto STOP'
      when r.tipo = 'club' and exists (select 1 from public.club_iscritti where telefono = r.telefono) then 'già nel Club'
      when r.tipo = 'voto' and (r.pren_stato in ('annullata', 'noshow') or r.voto is not null) then 'prenotazione annullata o voto già dato'
      when r.modello is null and (r.ultimo_in is null or r.ultimo_in < now() - interval '23 hours 50 minutes')
        then 'fuori dalle 24 ore'
      end;
    if salta is not null then
      update public.wa_uscita set stato = 'saltato', errore = salta where id = r.id;
    else
      update public.wa_uscita set stato = 'invio' where id = r.id;
      lista := lista || jsonb_build_object('id', r.id, 'telefono', r.telefono, 'tipo', r.tipo, 'modello', r.modello,
                                           'parametri', r.parametri, 'testo', r.testo, 'lingua', r.lingua);
    end if;
  end loop;
  return jsonb_build_object('numeroId', cfg.numero_id, 'messaggi', lista);
end $$;

create or replace function public.wa_esito_uscita(p_id bigint, p_wa_id text, p_errore text) returns void
language sql volatile security definer set search_path = public as $$
  update public.wa_uscita
     set stato = case when coalesce(p_wa_id, '') <> '' then 'inviato' else 'errore' end,
         wa_id = nullif(p_wa_id, ''), errore = left(p_errore, 300)
   where id = p_id;
$$;

-- lo stato che dice WhatsApp vale anche per i messaggi della coda
create or replace function public.wa_aggiorna(p_wa_id text, p_stato text, p_errore text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare nuovo text := case p_stato when 'sent' then 'inviato' when 'delivered' then 'consegnato'
                                    when 'read' then 'letto' when 'failed' then 'errore' end;
        ordine text[] := array['inviato', 'consegnato', 'letto'];
        n int := 0;
begin
  if nuovo is null or coalesce(p_wa_id, '') = '' then return false; end if;
  update public.pren_prenotazioni p
     set wa_stato = nuovo, wa_errore = case when nuovo = 'errore' then left(p_errore, 300) else p.wa_errore end,
         wa_quando = now()
   where p.wa_id = p_wa_id
     and (nuovo = 'errore' and p.wa_stato is distinct from 'letto' and p.wa_stato is distinct from 'consegnato'
          or array_position(ordine, nuovo) > coalesce(array_position(ordine, p.wa_stato), 0));
  get diagnostics n = row_count;
  update public.wa_uscita u
     set stato = nuovo, errore = case when nuovo = 'errore' then left(p_errore, 300) else u.errore end
   where u.wa_id = p_wa_id
     and (nuovo = 'errore' and u.stato not in ('letto', 'consegnato')
          or array_position(ordine, nuovo) > coalesce(array_position(ordine, u.stato), 0));
  return n > 0 or found;
end $$;

-- ogni giro: il voto delle cene di ieri, dalle 12:30 (solo numeri verificati, non annullate, senza STOP)
create or replace function public.wa_pianifica() returns int
language plpgsql volatile security definer set search_path = public as $$
declare cfg public.wa_config; imp public.pren_impostazioni; ieri date := public.pren_oggi() - 1; n int := 0;
begin
  select * into cfg from public.wa_config where id = 1;
  select * into imp from public.pren_impostazioni where id = 1;
  if not imp.whatsapp or cfg.numero_id = '' then return 0; end if;
  if now() < (public.pren_oggi() + cfg.voto_ora::time) at time zone 'Europe/Rome' then return 0; end if;
  insert into public.wa_uscita (telefono, prenotazione, tipo, modello, parametri, lingua)
  select p.telefono, p.id, 'voto', cfg.modello_voto,
         jsonb_build_array(split_part(p.nome, ' ', 1)), public.wa_lingua(p.lingua)
    from public.pren_prenotazioni p
   where p.sera = ieri and p.fonte = 'sito' and p.stato in ('confermata', 'arrivati')
     and p.wa_stato in ('consegnato', 'letto') and p.voto is null
     and not exists (select 1 from public.wa_uscita u where u.prenotazione = p.id and u.tipo = 'voto')
     and not exists (select 1 from public.wa_contatti c where c.telefono = p.telefono and c.stop);
  get diagnostics n = row_count;
  return n;
end $$;

-- la conferma (16-whatsapp.sql): stessa lingua dei modelli approvati
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
      'lingua', public.wa_lingua(p.lingua),
      'giorno', public.club_data(p.sera, public.wa_lingua(p.lingua)),
      'ora', p.turno, 'persone', public.club_persone(p.persone, public.wa_lingua(p.lingua)),
      'benvenuto', case when p.benvenuto > 0
                        then public.club_persone(p.benvenuto, public.wa_lingua(p.lingua)) end,
      'stato', p.stato) order by p.creato) filter (where p.id is not null), '[]'::jsonb))
    from prese p
$$;

revoke execute on function public.wa_testo(text, text, public.pren_prenotazioni, text) from public, anon, authenticated;
revoke execute on function public.wa_quando_club(timestamptz, int) from public, anon, authenticated;
revoke execute on function public.wa_lingua(text)                  from public, anon, authenticated;
revoke execute on function public.wa_ricevi(text, text, text, text) from public, anon, authenticated;
revoke execute on function public.wa_prendi_uscita(int)            from public, anon, authenticated;
revoke execute on function public.wa_esito_uscita(bigint, text, text) from public, anon, authenticated;
revoke execute on function public.wa_aggiorna(text, text, text)    from public, anon, authenticated;
revoke execute on function public.wa_pianifica()                   from public, anon, authenticated;
revoke execute on function public.wa_prendi(int)                   from public, anon, authenticated;
grant execute on function public.wa_ricevi(text, text, text, text), public.wa_prendi_uscita(int),
  public.wa_esito_uscita(bigint, text, text), public.wa_aggiorna(text, text, text), public.wa_pianifica(),
  public.wa_prendi(int) to service_role;


-- ================= TITOLARE (dashboard, col PIN) =================
create or replace function public.pren_vista_titolare(p public.pren_prenotazioni) returns jsonb
language sql stable set search_path = public as $$
  select public.pren_vista(p) || jsonb_build_object('id', p.id, 'telefono', p.telefono, 'fonte', p.fonte,
         'socio', p.iscritto is not null, 'iscritto', p.iscritto, 'creato', p.creato,
         'annullata', p.annullata, 'annullataDa', p.annullata_da, 'waErrore', p.wa_errore, 'waQuando', p.wa_quando,
         'waAttivato', p.wa_attivato, 'voto', p.voto)
$$;
revoke execute on function public.pren_vista_titolare(public.pren_prenotazioni) from public, anon, authenticated;

-- i messaggi ricevuti (gli ultimi 60) e quelli non letti
create or replace function public.wa_messaggi(p_pin text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare lista jsonb;
begin
  perform public.pr_controlla_pin(p_pin);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'telefono', e.telefono, 'nome', coalesce(nullif(p.nome, ''), nullif(e.nome, ''), e.telefono),
           'testo', e.testo, 'tipo', e.tipo, 'quando', e.quando, 'letto', e.letto,
           'voto', p.voto, 'sera', p.sera, 'turno', p.turno,
           'aperta', exists (select 1 from public.wa_contatti c where c.telefono = e.telefono
                              and c.ultimo_in > now() - interval '23 hours 50 minutes' and not c.stop))
           order by e.quando desc), '[]'::jsonb)
    into lista
    from (select * from public.wa_entrata order by quando desc limit 60) e
    left join public.pren_prenotazioni p on p.id = e.prenotazione;
  update public.wa_entrata set letto = true where not letto;
  return lista;
end $$;

-- il titolare risponde a mano (solo dentro le 24 ore dal suo ultimo messaggio)
create or replace function public.wa_rispondi(p_pin text, p_telefono text, p_testo text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare tel text := public.club_telefono(p_telefono); c public.wa_contatti; t text := left(trim(coalesce(p_testo, '')), 1000);
begin
  perform public.pr_controlla_pin(p_pin);
  if t = '' then raise exception 'Scrivi il messaggio' using hint = 'vuoto'; end if;
  select * into c from public.wa_contatti where telefono = tel;
  if c.telefono is null or c.ultimo_in is null or c.ultimo_in < now() - interval '23 hours 50 minutes' then
    raise exception 'Sono passate più di 24 ore dal suo ultimo messaggio: WhatsApp non lascia più scrivergli' using hint = 'finestra';
  end if;
  if c.stop then raise exception 'Ha chiesto di non ricevere messaggi (STOP)' using hint = 'stop'; end if;
  insert into public.wa_uscita (telefono, tipo, testo) values (tel, 'risposta', t);
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.wa_messaggi(text), public.wa_rispondi(text, text, text) to anon, authenticated;

-- le impostazioni: in più il link delle recensioni, le lingue, le ore del Club e i non letti
create or replace function public.wa_impostazioni(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c public.wa_config; imp public.pren_impostazioni;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into c from public.wa_config where id = 1;
  select * into imp from public.pren_impostazioni where id = 1;
  return jsonb_build_object(
    'attivo', imp.whatsapp, 'configurato', c.numero_id <> '', 'numeroId', c.numero_id,
    'modelloNuovo', c.modello_nuovo, 'modello', c.modello, 'modelloVoto', c.modello_voto, 'benvenutoMax', imp.benvenuto_max,
    'linkRecensioni', c.link_recensioni, 'inglese', 'en' = any(c.lingue), 'clubDopoOre', c.club_dopo_ore, 'votoOra', c.voto_ora,
    'ultimoInvio', c.ultimo_invio, 'ultimoErrore', c.ultimo_errore,
    'nonLetti', (select count(*) from public.wa_entrata where not letto),
    'settimana', (select jsonb_build_object(
                    'inviati', count(*) filter (where wa_stato in ('inviato', 'consegnato', 'letto')),
                    'verificati', count(*) filter (where wa_stato in ('consegnato', 'letto')),
                    'errori', count(*) filter (where wa_stato = 'errore'),
                    'attivati', count(*) filter (where wa_attivato is not null),
                    'voti', count(*) filter (where voto is not null),
                    'media', round(avg(voto), 1))
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
  if p_dati ? 'linkRecensioni' and coalesce(p_dati->>'linkRecensioni', '') !~ '^(https://[^[:space:]]{5,250})?$' then
    raise exception 'Il link deve cominciare con https://' using hint = 'link';
  end if;
  if p_dati ? 'votoOra' and coalesce(p_dati->>'votoOra', '') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'Ora non valida' using hint = 'ora';
  end if;
  update public.wa_config set
    numero_id       = coalesce(p_dati->>'numeroId', numero_id),
    modello_nuovo   = coalesce(nullif(trim(p_dati->>'modelloNuovo'), ''), modello_nuovo),
    modello         = coalesce(nullif(trim(p_dati->>'modello'), ''), modello),
    modello_voto    = coalesce(nullif(trim(p_dati->>'modelloVoto'), ''), modello_voto),
    link_recensioni = coalesce(p_dati->>'linkRecensioni', link_recensioni),
    lingue          = case when p_dati ? 'inglese' then
                        case when (p_dati->>'inglese')::boolean then '{it,en}'::text[] else '{it}'::text[] end else lingue end,
    club_dopo_ore   = coalesce((p_dati->>'clubDopoOre')::int, club_dopo_ore),
    voto_ora        = coalesce(p_dati->>'votoOra', voto_ora)
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
-- ogni 2 minuti: prepara i voti delle cene di ieri e, se c'è qualcosa da mandare, sveglia "whatsapp-invia"
select cron.schedule('whatsapp-invia', '*/2 * * * *', $wa$
  select public.wa_pianifica();
  select net.http_post(
    url     := 'https://agbvmhpktilpaoabjkre.supabase.co/functions/v1/whatsapp-invia',
    body    := '{"azione":"invia"}'::jsonb,
    headers := '{"Content-Type":"application/json","apikey":"sb_publishable_2O5l8ZbQqGnwDXwxZnsZ2Q_0Mt1V8T7"}'::jsonb)
   where exists (select 1 from public.pren_prenotazioni where wa_stato = 'in_coda')
      or exists (select 1 from public.wa_uscita where stato = 'in_coda' and quando <= now());
$wa$);
