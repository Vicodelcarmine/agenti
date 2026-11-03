-- =============================================================================
-- CAMPAGNA REGALO — IL PROMEMORIA "IL TUO REGALO SCADE" (si esegue DOPO 30-regalo-senza-50.sql)
-- Chi ha scoperto il regalo ma non l'ha ancora usato riceve UN WhatsApp, N sere buone prima
-- dell'ultima sera del regalo (camp_campagne.scade_sere, 3; sabato e chiusura non contano):
-- per il regalo che vale fino a mercoledì 11/11 parte domenica 8/11 alle 10.
-- Modello camp_campagne.scade_modello ('regalo_in_scadenza'): {{1}} nome, {{2}} il regalo,
-- {{3}} l'ultima sera ("mercoledì 11 novembre"), bottone col link personale ?c=CODICE.
-- Mai a chi:
--   · ha già usato il regalo                    · ha già una prenotazione fino alla scadenza
--   · si è tolto dalle email (disiscritto)      · ha scritto STOP su WhatsApp
--   · ha usato il 50% su TheFork (tf_esclusi)   · l'ha già ricevuto
-- Dalle 10 alle 20, mai di sabato, come il richiamo. Interruttore a parte (scade_attivo, spento):
-- il titolare lo accende dal cruscotto (Club → Campagne regalo) quando Meta ha approvato il modello.
-- Tutto passa dalla coda wa_uscita, tipo 'scadenza' (la funzione whatsapp-invia non cambia).
-- Si può rieseguire: non cancella niente.
-- =============================================================================

-- ---------- tabelle ----------
alter table public.camp_campagne
  add column if not exists scade_attivo  boolean not null default false,
  add column if not exists scade_modello text    not null default 'regalo_in_scadenza',
  add column if not exists scade_sere    int     not null default 3 check (scade_sere between 1 and 10);

alter table public.camp_contatti add column if not exists scade_quando timestamptz;   -- quando è partito il promemoria

alter table public.wa_uscita drop constraint if exists wa_uscita_tipo_check;
alter table public.wa_uscita add constraint wa_uscita_tipo_check
  check (tipo in ('prosecco', 'club', 'voto', 'grazie', 'basso', 'stop', 'start', 'risposta', 'campagna', 'scadenza'));


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- la sera del promemoria: n sere buone prima dell'ultima (i giorni g non contano)
create or replace function public.camp_sera_promemoria(al date, n int, g int[]) returns date
language plpgsql immutable set search_path = public as $$
declare d date := al; k int := 0;
begin
  while k < n and d > al - 60 loop
    d := d - 1;
    if not (extract(dow from d)::int = any(coalesce(g, '{}'::int[]))) then k := k + 1; end if;
  end loop;
  return d;
end $$;

-- 2026-11-11 → "mercoledì 11 novembre"
create or replace function public.camp_data_lunga(d date) returns text
language sql immutable set search_path = public as $$
  select (array['domenica','lunedì','martedì','mercoledì','giovedì','venerdì','sabato'])[extract(dow from d)::int + 1]
         || ' ' || extract(day from d)::int || ' ' ||
         (array['gennaio','febbraio','marzo','aprile','maggio','giugno','luglio','agosto',
                'settembre','ottobre','novembre','dicembre'])[extract(month from d)::int]
$$;

-- stessi ultimi 9 numeri: lo stesso telefono scritto in due modi
create or replace function public.camp_stesso_tel(a text, b text) returns boolean
language sql immutable set search_path = public as $$
  select coalesce(right(regexp_replace(a, '\D', '', 'g'), 9) = right(regexp_replace(b, '\D', '', 'g'), 9)
                  and length(regexp_replace(a, '\D', '', 'g')) >= 9, false)
$$;

-- chi deve ricevere il promemoria di una campagna, e da quale giorno (anche quelli dei giorni dopo)
create or replace function public.camp_scadenze(p_campagna text)
returns table (contatto uuid, telefono text, nome text, premio text, al date, giorno date)
language sql stable security definer set search_path = public as $$
  select distinct on (c.telefono)
         c.id, c.telefono, public.camp_nome_breve(coalesce(i.nome, c.nome)), p.nome->>'it', p.al,
         public.camp_sera_promemoria(p.al, k.scade_sere, coalesce(p.giorni_no, '{}'::int[]) || public.camp_giorni_no())
    from public.camp_contatti c
    join public.camp_campagne k on k.id = c.campagna
    join public.club_premi p on p.codice = c.club_codice
    left join public.club_iscritti i on i.id = p.iscritto
   where c.campagna = p_campagna and c.telefono is not null
     and c.scade_quando is null and c.disiscritto is null
     and p.usato is null and p.al >= public.pren_oggi()
     and not exists (select 1 from public.wa_contatti w where w.telefono = c.telefono and w.stop)
     and not exists (select 1 from public.tf_esclusi e where e.impronta = public.tf_impronta(c.telefono))
     -- ha già prenotato una sera da qui alla scadenza: non serve
     and not exists (select 1 from public.pren_prenotazioni x
                      where x.stato in ('confermata', 'arrivati') and x.sera between public.pren_oggi() and p.al
                        and (x.iscritto = p.iscritto or public.camp_stesso_tel(x.telefono, c.telefono)
                             or public.camp_stesso_tel(x.telefono, i.telefono)))
     -- lo stesso telefono su due contatti: basta un promemoria
     and not exists (select 1 from public.camp_contatti y
                      where y.campagna = c.campagna and y.telefono = c.telefono and y.id <> c.id and y.scade_quando is not null)
   order by c.telefono, p.al
$$;

-- mette in coda i promemoria arrivati al loro giorno (senza guardare l'ora: la guarda chi la chiama)
create or replace function public.camp_accoda_scadenze(p_campagna text) returns int
language plpgsql volatile security definer set search_path = public as $$
declare k public.camp_campagne; n int;
begin
  select * into k from public.camp_campagne where id = p_campagna and attiva and scade_attivo;
  if k.id is null then return 0; end if;
  with nuovi as (
    insert into public.wa_uscita (telefono, tipo, modello, parametri, link, lingua, contatto)
    select s.telefono, 'scadenza', k.scade_modello,
           jsonb_build_array(s.nome, s.premio, public.camp_data_lunga(s.al)), c.codice, 'it', s.contatto
      from public.camp_scadenze(k.id) s join public.camp_contatti c on c.id = s.contatto
     where s.giorno <= public.pren_oggi()
     order by s.al limit 50
    returning contatto)
  update public.camp_contatti set scade_quando = now() where id in (select contatto from nuovi);
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.camp_sera_promemoria(date, int, int[]) from public, anon, authenticated;
revoke execute on function public.camp_data_lunga(date)                 from public, anon, authenticated;
revoke execute on function public.camp_stesso_tel(text, text)           from public, anon, authenticated;
revoke execute on function public.camp_scadenze(text)                   from public, anon, authenticated;
revoke execute on function public.camp_accoda_scadenze(text)            from public, anon, authenticated;


-- ---------- per l'orologio (solo service_role) ----------

-- ogni giro: i promemoria di tutte le campagne accese, solo nell'ora buona
create or replace function public.camp_pianifica_scadenze() returns int
language plpgsql volatile security definer set search_path = public as $$
declare k record; n int := 0;
begin
  if coalesce((select numero_id from public.wa_config where id = 1), '') = '' then return 0; end if;
  for k in select id from public.camp_campagne where attiva and scade_attivo loop
    continue when not public.camp_ora_campagna(k.id, now());
    n := n + public.camp_accoda_scadenze(k.id);
  end loop;
  return n;
end $$;
revoke execute on function public.camp_pianifica_scadenze() from public, anon, authenticated;
grant execute on function public.camp_pianifica_scadenze() to service_role;

-- la coda (29-prenota-diretto.sql) + il promemoria: parte nell'ora buona della sua campagna,
-- solo se il suo interruttore è acceso, e salta chi nel frattempo ha usato il regalo o prenotato
create or replace function public.wa_prendi_uscita(n int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare cfg public.wa_config; r record; lista jsonb := '[]'::jsonb; salta text;
begin
  select * into cfg from public.wa_config where id = 1;
  for r in
    select u.*, c.stop, c.ultimo_in, p.stato as pren_stato, p.voto, p.nome as pren_nome,
           cc.premio as camp_premio, cc.disiscritto as camp_disiscritto,
           cp.usato as regalo_usato, cp.al as regalo_al, cp.iscritto as regalo_iscritto
      from public.wa_uscita u
      left join public.wa_contatti c on c.telefono = u.telefono
      left join public.pren_prenotazioni p on p.id = u.prenotazione
      left join public.camp_contatti cc on cc.id = u.contatto
      left join public.club_premi cp on cp.codice = cc.club_codice
     where u.stato = 'in_coda' and u.quando <= now()
       and (u.tipo not in ('campagna', 'scadenza')
            or (public.camp_ora_campagna(cc.campagna, now())
                and exists (select 1 from public.camp_campagne k where k.id = cc.campagna and k.attiva
                               and case when u.tipo = 'scadenza' then k.scade_attivo else k.wa_attivo end)))
     order by u.quando limit n for update of u skip locked
  loop
    salta := case
      when coalesce(r.stop, false) and r.tipo not in ('stop', 'start') then 'ha scritto STOP'
      when r.tipo = 'club' and exists (select 1 from public.club_iscritti where telefono = r.telefono) then 'già nel Club'
      when r.tipo = 'voto' and (r.pren_stato in ('annullata', 'noshow') or r.voto is not null) then 'prenotazione annullata o voto già dato'
      when r.tipo in ('campagna', 'scadenza') and r.contatto is null then 'contatto cancellato'
      when r.tipo = 'campagna' and r.camp_premio is not null then 'ha già scoperto il regalo'
      when r.tipo in ('campagna', 'scadenza') and r.camp_disiscritto is not null then 'disiscritto dalle email'
      when r.tipo = 'scadenza' and r.regalo_usato is not null then 'regalo già usato'
      when r.tipo = 'scadenza' and coalesce(r.regalo_al, date '1900-01-01') < public.pren_oggi() then 'regalo scaduto'
      when r.tipo = 'scadenza' and exists (select 1 from public.pren_prenotazioni x
                                            where x.stato in ('confermata', 'arrivati')
                                              and x.sera between public.pren_oggi() and r.regalo_al
                                              and (x.iscritto = r.regalo_iscritto or public.camp_stesso_tel(x.telefono, r.telefono)))
        then 'ha già prenotato'
      when r.modello is null and (r.ultimo_in is null or r.ultimo_in < now() - interval '23 hours 50 minutes')
        then 'fuori dalle 24 ore'
      end;
    if salta is not null then
      update public.wa_uscita set stato = 'saltato', errore = salta where id = r.id;
    else
      update public.wa_uscita set stato = 'invio' where id = r.id;
      lista := lista || jsonb_build_object('id', r.id, 'telefono', r.telefono, 'tipo', r.tipo, 'modello', r.modello,
                                           'parametri', r.parametri, 'link', r.link, 'testo', r.testo, 'lingua', r.lingua);
    end if;
  end loop;
  return jsonb_build_object('numeroId', cfg.numero_id, 'messaggi', lista);
end $$;
revoke execute on function public.wa_prendi_uscita(int) from public, anon, authenticated;
grant execute on function public.wa_prendi_uscita(int) to service_role;


-- ---------- CRUSCOTTO (PIN del titolare) ----------

-- come sta andando la campagna (19-campagna-whatsapp.sql) + il promemoria
create or replace function public.camp_panoramica(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', k.id, 'nome', k.nome, 'attiva', k.attiva, 'sere', k.sere, 'scopriEntro', k.scopri_entro,
      'contatti',    (select count(*) from public.camp_contatti c where c.campagna = k.id),
      'aperti',      (select count(*) from public.camp_contatti c where c.campagna = k.id and c.aperto is not null),
      'scoperti',    (select count(*) from public.camp_contatti c where c.campagna = k.id and c.premio is not null),
      'disiscritti', (select count(*) from public.camp_contatti c where c.campagna = k.id and c.disiscritto is not null),
      'prenotati',   (select count(*) from public.camp_contatti c
                       where c.campagna = k.id and c.premio is not null and c.iscritto is not null
                         and exists (select 1 from public.pren_prenotazioni x
                                      where x.iscritto = c.iscritto and x.fonte = 'sito' and x.stato <> 'annullata'
                                        and x.creato >= c.premio_quando)),
      'usati',       (select count(*) from public.camp_contatti c join public.club_premi r on r.codice = c.club_codice
                       where c.campagna = k.id and r.usato is not null),
      'premi', (select jsonb_agg(jsonb_build_object('id', p.id, 'emoji', p.emoji, 'nome', p.nome->>'it',
                                                    'peso', p.peso, 'limite', p.limite,
                                                    'usciti', (select count(*) from public.camp_contatti c
                                                                where c.campagna = k.id and c.premio = p.id)) order by p.ordine)
                  from public.camp_premi p where p.campagna = k.id),
      'wa', jsonb_build_object(
        'attivo', k.wa_attivo, 'modello', k.wa_modello, 'giorni', k.wa_giorni,
        'inviati',   (select count(*) from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                       where c.campagna = k.id and u.tipo = 'campagna' and u.stato in ('inviato', 'consegnato', 'letto')),
        'letti',     (select count(*) from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                       where c.campagna = k.id and u.tipo = 'campagna' and u.stato = 'letto'),
        'errori',    (select count(*) from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                       where c.campagna = k.id and u.tipo = 'campagna' and u.stato = 'errore'),
        'scopertiDopo', (select count(*) from public.camp_contatti c
                          where c.campagna = k.id and c.wa_quando is not null and c.premio_quando > c.wa_quando),
        'ultimoErrore', (select u.errore from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                          where c.campagna = k.id and u.tipo = 'campagna' and u.errore is not null
                            and u.stato in ('errore', 'in_coda') order by u.id desc limit 1)),
      'scade', jsonb_build_object(
        'attivo', k.scade_attivo, 'modello', k.scade_modello, 'sere', k.scade_sere,
        'inviati',   (select count(*) from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                       where c.campagna = k.id and u.tipo = 'scadenza' and u.stato in ('inviato', 'consegnato', 'letto')),
        'letti',     (select count(*) from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                       where c.campagna = k.id and u.tipo = 'scadenza' and u.stato = 'letto'),
        'errori',    (select count(*) from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                       where c.campagna = k.id and u.tipo = 'scadenza' and u.stato = 'errore'),
        'prenotatiDopo', (select count(*) from public.camp_contatti c
                           where c.campagna = k.id and c.scade_quando is not null
                             and exists (select 1 from public.pren_prenotazioni x
                                          where x.stato <> 'annullata' and x.creato >= c.scade_quando
                                            and public.camp_stesso_tel(x.telefono, c.telefono))),
        'ultimoErrore', (select u.errore from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                          where c.campagna = k.id and u.tipo = 'scadenza' and u.errore is not null
                          order by u.id desc limit 1),
        -- i prossimi: quale giorno e quanti (chi poi usa il regalo o prenota esce da solo)
        'prossimi', (select coalesce(jsonb_agg(jsonb_build_object('giorno', g.giorno, 'quanti', g.quanti) order by g.giorno), '[]'::jsonb)
                       from (select greatest(s.giorno, public.pren_oggi()) giorno, count(*) quanti
                               from public.camp_scadenze(k.id) s group by 1) g)),
      'gruppi', (select jsonb_agg(jsonb_build_object(
                   'gruppo', g.gruppo,
                   'email', g.email_quando,
                   'wa', public.camp_quando_wa(g.email_quando, k.wa_giorni),
                   'contatti', (select count(*) from public.camp_contatti c where c.campagna = k.id and c.gruppo = g.gruppo),
                   'scoperti', (select count(*) from public.camp_contatti c
                                 where c.campagna = k.id and c.gruppo = g.gruppo and c.premio is not null),
                   'whatsapp', (select count(*) from public.camp_contatti c
                                 where c.campagna = k.id and c.gruppo = g.gruppo and c.wa_quando is not null)) order by g.gruppo)
                   from public.camp_gruppi g where g.campagna = k.id),
      'senzaGruppo', (select count(*) from public.camp_contatti c
                       where c.campagna = k.id and (c.gruppo is null
                         or not exists (select 1 from public.camp_gruppi g where g.campagna = k.id and g.gruppo = c.gruppo))))
      order by k.creato desc)
      from public.camp_campagne k), '[]'::jsonb);
end $$;

-- accende / spegne il promemoria della scadenza
create or replace function public.camp_scade_attiva(p_pin text, p_campagna text, p_attivo boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  if coalesce(p_attivo, false) and coalesce((select numero_id from public.wa_config where id = 1), '') = '' then
    raise exception 'Prima collega il numero WhatsApp' using hint = 'numero';
  end if;
  update public.camp_campagne set scade_attivo = coalesce(p_attivo, false) where id = p_campagna;
  if not found then raise exception 'Campagna non trovata' using hint = 'campagna'; end if;
  -- spento: quelli ancora in coda non partono, e lo riceveranno se si riaccende
  if not coalesce(p_attivo, false) then
    with tolti as (
      update public.wa_uscita u set stato = 'saltato', errore = 'promemoria spento'
        from public.camp_contatti c
       where c.id = u.contatto and c.campagna = p_campagna and u.tipo = 'scadenza' and u.stato = 'in_coda'
      returning u.contatto)
    update public.camp_contatti set scade_quando = null where id in (select contatto from tolti);
  end if;
  return public.camp_panoramica(p_pin);
end $$;

grant execute on function public.camp_panoramica(text), public.camp_scade_attiva(text, text, boolean) to anon, authenticated;


-- ================= OROLOGIO =================
-- ogni 10 minuti mette in coda i promemoria; li manda il lavoro "whatsapp-invia" (ogni 2 minuti)
select cron.schedule('camp-scadenze', '*/10 * * * *', $sc$ select public.camp_pianifica_scadenze(); $sc$);

-- ogni 2 minuti (29-prenota-diretto.sql): fuori dall'ora buona il promemoria aspetta come la campagna,
-- senza chiamare la funzione per niente
select cron.schedule('whatsapp-invia', '*/2 * * * *', $wa$
  select public.wa_pianifica();
  select public.camp_pianifica_wa();
  select net.http_post(
    url     := 'https://agbvmhpktilpaoabjkre.supabase.co/functions/v1/whatsapp-invia',
    body    := '{"azione":"invia"}'::jsonb,
    headers := '{"Content-Type":"application/json","apikey":"sb_publishable_2O5l8ZbQqGnwDXwxZnsZ2Q_0Mt1V8T7"}'::jsonb)
   where exists (select 1 from public.pren_prenotazioni where wa_stato = 'in_coda')
      or exists (select 1 from public.wa_uscita u left join public.camp_contatti c on c.id = u.contatto
                  where u.stato = 'in_coda' and u.quando <= now()
                    and (u.tipo not in ('campagna', 'scadenza') or public.camp_ora_campagna(c.campagna, now())));
$wa$);
