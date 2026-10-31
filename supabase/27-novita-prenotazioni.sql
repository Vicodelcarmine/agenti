-- =============================================================================
-- PRENOTAZIONI — i messaggi WhatsApp dentro la prenotazione e le "novità" da guardare.
-- Richiesta del titolare (31/10/2026): un cliente ha scritto "sono in ritardo", ma il
-- messaggio si trovava solo in "Messaggi ricevuti" e non aprendo la sua prenotazione.
--   · ogni messaggio va nella prenotazione a cui si riferisce: quella della sera più vicina
--     con lo stesso numero, anche se scritta a mano (telefono, TheFork, Google);
--   · la prenotazione porta con sé la conversazione e si può rispondere da lì;
--   · gli avvisi al titolare (pren_avvisi: nuova, annullata, whatsapp) diventano "novità"
--     finché non vengono guardati: la dashboard accende e fa saltare l'icona Prenota.
-- Si esegue DOPO 18-campagna-regalo.sql. Si può rieseguire: non cancella niente.
-- =============================================================================

-- "visto": la novità è stata guardata. Quello che è arrivato prima di oggi è già vecchio:
-- si parte da zero, senza un mese di novità arretrate (solo la prima volta).
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'pren_avvisi' and column_name = 'visto') then
    alter table public.pren_avvisi add column visto timestamptz;
    update public.pren_avvisi set visto = now();
  end if;
end $$;
create index if not exists pren_avvisi_da_vedere on public.pren_avvisi (creato) where visto is null;
create index if not exists pren_avvisi_pren      on public.pren_avvisi (prenotazione);
create index if not exists wa_entrata_pren       on public.wa_entrata (prenotazione, quando);
create index if not exists wa_entrata_tel        on public.wa_entrata (telefono, quando);
create index if not exists pren_prenotazioni_tel on public.pren_prenotazioni (telefono);


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- è solo un saluto? ("ciao", "ok", "grazie", un'emoji): al CIAO della conferma non serve avvisare
create or replace function public.wa_saluto(t text) returns boolean
language sql immutable set search_path = public as $$
  select lower(regexp_replace(coalesce(t, ''), '[^[:alnum:]]', '', 'g'))
         ~ '^(ciao+|ok+|okay|si|yes|hello|hi|hey|hola|salve|grazie|thanks|thankyou|buonasera|buongiorno|perfetto)*$'
$$;

-- a quale prenotazione si riferisce un messaggio: stesso numero, già presa, la sera più vicina
-- (stasera, poi domani, poi ieri, poi dopodomani…; fino a 2 sere fa). Le annullate solo se non c'è altro.
create or replace function public.pren_del_messaggio(tel text, t timestamptz) returns uuid
language sql stable set search_path = public as $$
  select x.id from public.pren_prenotazioni x
   where coalesce(tel, '') <> '' and x.telefono = tel and x.creato <= t and x.sera >= public.pr_sera(t) - 2
   order by (x.stato = 'annullata'),
            case when x.sera >= public.pr_sera(t) then (x.sera - public.pr_sera(t)) * 2
                 else (public.pr_sera(t) - x.sera) * 2 + 1 end,
            x.creato desc
   limit 1
$$;

-- la conversazione di una prenotazione, dal più vecchio: i messaggi veri del cliente
-- (non il CIAO della conferma né il voto, che si vedono già altrove) e le risposte del titolare
create or replace function public.pren_conversazione(p_id uuid) returns jsonb
language sql stable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('da', m.da, 'testo', m.testo, 'quando', m.quando,
                                               'letto', m.letto, 'stato', m.stato) order by m.quando), '[]'::jsonb)
    from (select 'cliente' as da, e.testo, e.quando, e.letto, null::text as stato
            from public.wa_entrata e
           where e.prenotazione = p_id and (e.tipo = 'testo' or (e.tipo = 'attiva' and not public.wa_saluto(e.testo)))
          union all
          select 'titolare', u.testo, u.creato, true, u.stato
            from public.wa_uscita u
           where u.prenotazione = p_id and u.tipo = 'risposta') m
$$;

revoke execute on function public.wa_saluto(text)                       from public, anon, authenticated;
revoke execute on function public.pren_del_messaggio(text, timestamptz) from public, anon, authenticated;
revoke execute on function public.pren_conversazione(uuid)              from public, anon, authenticated;

-- i messaggi già arrivati vanno nella prenotazione giusta (il voto e il CIAO restano dov'erano)
update public.wa_entrata e
   set prenotazione = coalesce(public.pren_del_messaggio(e.telefono, e.quando), e.prenotazione)
 where e.tipo = 'testo';
update public.wa_uscita u
   set prenotazione = (select e.prenotazione from public.wa_entrata e
                        where e.telefono = u.telefono and e.quando <= u.creato and e.prenotazione is not null
                        order by e.quando desc limit 1)
 where u.tipo = 'risposta' and u.prenotazione is null;


-- ---------- un messaggio in arrivo (dalla funzione whatsapp-webhook) ----------
-- come in 17-whatsapp-dialogo.sql; cambia solo:
--   · il messaggio va nella prenotazione della sera più vicina, anche scritta a mano
--     (il dialogo CIAO/voto resta sulla prenotazione del sito, come prima);
--   · se la prima risposta alla conferma non è un saluto ("siamo in ritardo") il titolare viene avvisato.
create or replace function public.wa_ricevi(p_da text, p_nome text, p_testo text, p_wa_id text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  tel  text := public.club_telefono('+' || regexp_replace(coalesce(p_da, ''), '[^0-9]', '', 'g'));
  t    text := left(trim(coalesce(p_testo, '')), 2000);
  bassa text := lower(regexp_replace(t, '[^[:alnum:]]', '', 'g'));
  c    public.wa_contatti;
  p    public.pren_prenotazioni;
  r    public.pren_prenotazioni;
  cfg  public.wa_config;
  e    public.wa_entrata;
  v_tipo text := 'testo';
  ling text;
  avvisa boolean := true;
  v    int;
  dove uuid;
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
    avvisa := not public.wa_saluto(t);                     -- "siamo in ritardo" attiva il regalo, ma va anche letto
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

  -- il voto e il CIAO restano sulla prenotazione del dialogo; tutto il resto va sulla sera più vicina
  dove := case when v_tipo in ('voto', 'attiva') then p.id
               else coalesce(public.pren_del_messaggio(tel, now()), p.id) end;
  select * into r from public.pren_prenotazioni where id = dove;
  update public.wa_entrata set tipo = v_tipo, prenotazione = dove where id = e.id;
  if avvisa and v_tipo not in ('stop', 'start') then
    insert into public.pren_avvisi (prenotazione, tipo, titolo, testo)
    values (dove, 'whatsapp',
            case when v_tipo = 'voto' then '⭐ Voto ' || v || ' da ' || coalesce(nullif(p.nome, ''), nullif(p_nome, ''), tel)
                 else '💬 WhatsApp da ' || coalesce(nullif(r.nome, ''), nullif(p.nome, ''), nullif(p_nome, ''), tel) end,
            case when v_tipo = 'voto' then 'Gli abbiamo chiesto cosa non è andato: la risposta arriva qui.' else left(t, 180) end);
  end if;
  return jsonb_build_object('ok', true, 'tipo', v_tipo,
                            'invia', exists (select 1 from public.wa_uscita where telefono = tel and stato = 'in_coda' and quando <= now()),
                            'avvisa', avvisa and v_tipo not in ('stop', 'start'));
end $$;
revoke execute on function public.wa_ricevi(text, text, text, text) from public, anon, authenticated;
grant execute on function public.wa_ricevi(text, text, text, text) to service_role;


-- ================= TITOLARE (dashboard, col PIN) =================

-- la prenotazione nella dashboard: in più la conversazione, se si può rispondere e le novità da guardare
create or replace function public.pren_vista_titolare(p public.pren_prenotazioni) returns jsonb
language sql stable set search_path = public as $$
  select public.pren_vista(p) || jsonb_build_object('id', p.id, 'telefono', p.telefono, 'fonte', p.fonte,
         'socio', p.iscritto is not null, 'iscritto', p.iscritto, 'creato', p.creato,
         'annullata', p.annullata, 'annullataDa', p.annullata_da, 'waErrore', p.wa_errore, 'waQuando', p.wa_quando,
         'waAttivato', p.wa_attivato, 'voto', p.voto,
         'regalo', (select jsonb_build_object('codice', r.codice, 'emoji', r.emoji, 'nome', r.nome,
                                              'persone', r.persone, 'usato', r.usato)
                      from public.club_premi r
                     where p.iscritto is not null and p.fonte = 'sito' and r.iscritto = p.iscritto and r.tipo = 'regalo'
                       and p.sera between r.dal and r.al and (r.usato is null or r.sera_uso = p.sera)
                     order by r.creato limit 1),
         'conversazione', public.pren_conversazione(p.id),
         'finestra', exists (select 1 from public.wa_contatti c
                              where c.telefono = p.telefono and c.ultimo_in > now() - interval '23 hours 50 minutes' and not c.stop),
         'novita', jsonb_build_object(
           'nuova',     exists (select 1 from public.pren_avvisi a where a.prenotazione = p.id and a.tipo = 'nuova' and a.visto is null),
           'annullata', exists (select 1 from public.pren_avvisi a where a.prenotazione = p.id and a.tipo = 'annullata' and a.visto is null),
           'messaggi',  (select count(*) from public.pren_avvisi a where a.prenotazione = p.id and a.tipo = 'whatsapp' and a.visto is null)))
$$;
revoke execute on function public.pren_vista_titolare(public.pren_prenotazioni) from public, anon, authenticated;

-- le novità da guardare: fanno saltare l'icona Prenota finché non vengono viste
create or replace function public.pren_novita(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return jsonb_build_object(
    'totale', (select count(*) from public.pren_avvisi where visto is null),
    'lista', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'tipo', a.tipo, 'quando', a.creato, 'prenotazione', p.id, 'sera', p.sera, 'turno', p.turno,
               'nome', p.nome, 'persone', p.persone, 'testo', a.testo,
               'titolo', coalesce(a.titolo, case when a.tipo = 'nuova' then '📅 Nuova prenotazione' else '❌ Annullata dal cliente' end))
             order by a.creato desc)
        from (select * from public.pren_avvisi where visto is null order by creato desc limit 30) a
        left join public.pren_prenotazioni p on p.id = a.prenotazione), '[]'::jsonb));
end $$;

-- "l'ho visto": una prenotazione aperta, oppure (senza prenotazione) tutto. Torna quante novità restano.
create or replace function public.pren_visto(p_pin text, p_prenotazione uuid) returns int
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  if p_prenotazione is null then
    update public.pren_avvisi set visto = now() where visto is null;
    update public.wa_entrata set letto = true where not letto;
  else
    update public.pren_avvisi set visto = now() where visto is null and prenotazione = p_prenotazione;
    update public.wa_entrata set letto = true where not letto and prenotazione = p_prenotazione;
  end if;
  return (select count(*) from public.pren_avvisi where visto is null);
end $$;

-- i messaggi ricevuti: come prima, e chi apre l'elenco ha visto anche le novità dei messaggi
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
  update public.pren_avvisi set visto = now() where visto is null and tipo = 'whatsapp';
  return lista;
end $$;

-- il titolare risponde a mano (solo dentro le 24 ore): la risposta resta nella conversazione della prenotazione
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
  insert into public.wa_uscita (telefono, prenotazione, tipo, testo)
  values (tel, coalesce((select e.prenotazione from public.wa_entrata e
                          where e.telefono = tel and e.prenotazione is not null order by e.quando desc limit 1),
                        public.pren_del_messaggio(tel, now())),
          'risposta', t);
  return jsonb_build_object('ok', true);
end $$;

-- la prova degli avvisi non è una novità da guardare
create or replace function public.pren_prova_avviso(p_pin text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare id uuid;
begin
  perform public.pr_controlla_pin(p_pin);
  select p.id into id from public.pren_prenotazioni p order by creato desc limit 1;
  if id is null then return false; end if;
  insert into public.pren_avvisi (prenotazione, tipo, visto) values (id, 'nuova', now());
  return true;
end $$;

grant execute on function public.pren_novita(text), public.pren_visto(text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
