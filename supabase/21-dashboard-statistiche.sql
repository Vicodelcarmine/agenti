-- =============================================================================
-- DASHBOARD DA COMPUTER — LE STATISTICHE (si esegue DOPO 20-dashboard-fondamenta.sql)
-- Funzioni di SOLA LETTURA per la dashboard da computer (agenti/desktop/), tutte col PIN
-- del titolare. I conti si fanno qui: al browser arrivano numeri già aggregati; i dati
-- personali escono solo dalle funzioni dei clienti (dash_clienti, dash_cerca, dash_cliente).
-- · dash_riepilogo(pin, dal, al): un periodo intero, giorno per giorno e per ogni area.
--   La dashboard la chiama due volte (periodo scelto + periodo di confronto).
-- · dash_clienti(pin, dal, al): frequenza, nuovi e tornati, clienti da riconquistare.
-- · dash_cerca / dash_cliente: la scheda di un cliente (il telefono è la chiave).
-- · dash_salute(pin): code ferme, errori, ultimi invii.  · dash_impostazioni(pin).
-- Una "presenza" è una sera in cui il cliente è venuto: prenotazione non annullata e non
-- "non presentato" (fino a ieri), oppure un premio del Club usato quella sera.
-- Si può rieseguire.
-- =============================================================================

-- ---------- funzioni di servizio ----------

-- da dove è arrivato un iscritto al Club: quello registrato dal sito, altrimenti dedotto
create or replace function public.dash_club_canale(i public.club_iscritti) returns text
language sql stable set search_path = public as $$
  select coalesce(i.canale,
    case
      when exists (select 1 from public.camp_contatti c where c.iscritto = i.id) then 'campagna:regalo'
      when exists (select 1 from public.asp_ordini a where a.iscritto = i.id
                    and a.creato between i.creato - interval '15 minutes' and i.creato + interval '15 minutes') then 'asporto'
      when exists (select 1 from public.pren_prenotazioni p where p.iscritto = i.id
                    and p.creato between i.creato - interval '15 minutes' and i.creato + interval '15 minutes') then 'prenotazione'
      when exists (select 1 from public.fortuna_giocate f where f.iscritto = i.id) then 'fortuna'
      else 'menu-qr' end)
$$;

-- il canale di una prenotazione: dal sito quello registrato ("sito" se non si sa); quelle scritte
-- a mano dal titolare restano separate ("manuale:telefono", "manuale:thefork", "manuale:google"…)
create or replace function public.dash_pren_canale(p public.pren_prenotazioni) returns text
language sql immutable set search_path = public as $$
  select case when p.fonte = 'sito' then coalesce(p.canale, 'sito') else 'manuale:' || p.fonte end
$$;

-- tutte le presenze conosciute (telefono, sera): la base della frequenza dei clienti
create or replace function public.dash_presenze() returns table (telefono text, sera date, origine text)
language sql stable set search_path = public as $$
  select p.telefono, p.sera, 'prenotazione'
    from public.pren_prenotazioni p
   where p.telefono is not null and p.stato in ('confermata', 'arrivati') and p.sera < public.pren_oggi()
  union
  select i.telefono, r.sera_uso, 'premio'
    from public.club_premi r join public.club_iscritti i on i.id = r.iscritto
   where r.usato is not null and r.sera_uso is not null and i.telefono is not null
$$;

-- il nome più recente che conosciamo per un telefono
create or replace function public.dash_nome(t text) returns text
language sql stable set search_path = public as $$
  select coalesce(
    (select nome from public.club_iscritti where telefono = t order by creato desc limit 1),
    (select nome from public.pren_prenotazioni where telefono = t and nome <> '' order by creato desc limit 1),
    (select nome from public.asp_ordini where telefono = t and nome <> '' order by creato desc limit 1),
    (select nome from public.camp_contatti where telefono = t and nome <> '' order by creato desc limit 1),
    t)
$$;

-- i piatti più ordinati da un insieme di righe [{nome, qta, prezzo}]
create or replace function public.dash_piatti(righe jsonb[]) returns jsonb
language sql immutable set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'qta', qta, 'euro', euro) order by qta desc, nome), '[]'::jsonb)
    from (select x->>'nome' as nome, sum(coalesce((x->>'qta')::int, 1)) as qta,
                 round(sum(coalesce((x->>'qta')::int, 1) * coalesce((x->>'prezzo')::numeric, 0)), 2) as euro
            from unnest(righe) r, jsonb_array_elements(r) x
           where coalesce(x->>'nome', '') <> ''
           group by x->>'nome' order by 2 desc limit 25) t
$$;

revoke execute on function public.dash_club_canale(public.club_iscritti)      from public, anon, authenticated;
revoke execute on function public.dash_pren_canale(public.pren_prenotazioni)  from public, anon, authenticated;
revoke execute on function public.dash_presenze()                             from public, anon, authenticated;
revoke execute on function public.dash_nome(text)                             from public, anon, authenticated;
revoke execute on function public.dash_piatti(jsonb[])                        from public, anon, authenticated;


-- ================= TITOLARE (dashboard da computer, col PIN) =================

-- un periodo intero: giorno per giorno e per area
create or replace function public.dash_riepilogo(p_pin text, p_dal date, p_al date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  perform public.pr_controlla_pin(p_pin);
  if p_dal is null or p_al is null or p_al < p_dal or p_al - p_dal > 400 then
    raise exception 'Periodo non valido' using hint = 'periodo';
  end if;

  with
  pren as (select p.*, public.dash_pren_canale(p) as can from public.pren_prenotazioni p where p.sera between p_dal and p_al),
  pv   as (select * from pren where stato <> 'annullata'),
  asp  as (select * from public.asp_ordini where sera between p_dal and p_al),
  aspv as (select * from asp where stato <> 'annullato'),
  ord  as (select o.*, public.pr_sera(o.inviato_alle) as sera from public.ordini o
            where public.pr_sera(o.inviato_alle) between p_dal and p_al),
  clu  as (select i.*, public.pr_sera(i.creato) as sera, public.dash_club_canale(i) as can from public.club_iscritti i
            where public.pr_sera(i.creato) between p_dal and p_al),
  buo  as (select * from public.pr_buoni where sera between p_dal and p_al or sera_riscatto between p_dal and p_al),
  wau  as (select * from public.wa_uscita where public.pr_sera(creato) between p_dal and p_al),
  wae  as (select * from public.wa_entrata where public.pr_sera(quando) between p_dal and p_al),
  fgi  as (select * from public.fortuna_giocate where sera between p_dal and p_al)
  select jsonb_build_object(
    'dal', p_dal, 'al', p_al,
    'giorni', (select jsonb_agg(jsonb_build_object(
        'g', g,
        'pren',      (select count(*) from pv where sera = g),
        'persone',   (select coalesce(sum(persone), 0) from pv where sera = g),
        'annullate', (select count(*) from pren where sera = g and stato = 'annullata'),
        'noshow',    (select count(*) from pren where sera = g and stato = 'noshow'),
        'incasso',   (select incasso from public.cassa_sere where sera = g),
        'coperti',   (select coperti from public.cassa_sere where sera = g),
        'scontrini', (select scontrini from public.cassa_sere where sera = g),
        'cassaFonte', (select fonte from public.cassa_sere where sera = g),
        'asp',       (select count(*) from aspv where sera = g),
        'aspEuro',   (select coalesce(sum(totale), 0) from aspv where sera = g),
        'ordini',    (select count(*) from ord where sera = g),
        'ordiniEuro', (select coalesce(sum(totale), 0) from ord where sera = g),
        'club',      (select count(*) from clu where sera = g),
        'premiUsati', (select count(*) from public.club_premi where sera_uso = g),
        'giocate',   (select count(*) from buo where sera = g),
        'tavoli',    (select count(*) from buo where stato = 'riscattato' and sera_riscatto = g),
        'prPersone', (select coalesce(sum(persone), 0) from buo where stato = 'riscattato' and sera_riscatto = g),
        'prEuro',    (select coalesce(sum(euro), 0) from buo where stato = 'riscattato' and sera_riscatto = g),
        'fortuna',   (select count(*) from fgi where sera = g),
        'visite',    (select coalesce(sum(visite), 0) from public.sito_visite where giorno = g),
        'waInviati', (select count(*) from wau where public.pr_sera(creato) = g and stato in ('inviato', 'consegnato', 'letto'))
                     + (select count(*) from pren where public.pr_sera(creato) = g and wa_stato in ('inviato', 'consegnato', 'letto')),
        'waRicevuti', (select count(*) from wae where public.pr_sera(quando) = g)
      ) order by g) from generate_series(p_dal, p_al, interval '1 day') s(x), lateral (select s.x::date as g) gg),
    'prenotazioni', jsonb_build_object(
      'totale',    (select count(*) from pv),
      'persone',   (select coalesce(sum(persone), 0) from pv),
      'annullate', (select count(*) from pren where stato = 'annullata'),
      'noshow',    (select count(*) from pren where stato = 'noshow'),
      'canali',    (select coalesce(jsonb_object_agg(can, jsonb_build_object('n', n, 'persone', pe)), '{}'::jsonb)
                      from (select can, count(*) n, sum(persone) pe from pv group by can) t),
      'settimana', (select jsonb_agg(jsonb_build_object('d', d, 'n', coalesce(n, 0), 'persone', coalesce(pe, 0)) order by d)
                      from generate_series(1, 7) d
                      left join (select extract(isodow from sera)::int dd, count(*) n, sum(persone) pe from pv group by 1) t on t.dd = d),
      'orari',     (select coalesce(jsonb_agg(jsonb_build_object('ora', turno, 'n', n, 'persone', pe) order by turno), '[]'::jsonb)
                      from (select turno, count(*) n, sum(persone) pe from pv group by turno) t),
      'mappa',     (select coalesce(jsonb_agg(jsonb_build_object('d', d, 'ora', turno, 'persone', pe)), '[]'::jsonb)
                      from (select extract(isodow from sera)::int d, turno, sum(persone) pe from pv group by 1, 2) t),
      'gruppi',    (select coalesce(jsonb_object_agg(k, n), '{}'::jsonb) from (
                      select case when persone <= 2 then '1-2' when persone <= 4 then '3-4' when persone <= 6 then '5-6' else '7+' end k,
                             count(*) n from pv group by 1) t),
      'anticipo',  (select round(avg(sera - (creato at time zone 'Europe/Rome')::date), 1) from pv where fonte = 'sito'),
      'benvenuto', (select count(*) from pv where benvenuto > 0),
      'voti',      (select jsonb_build_object('n', count(voto), 'media', round(avg(voto), 2),
                        'distribuzione', jsonb_build_object('1', count(*) filter (where voto = 1), '2', count(*) filter (where voto = 2),
                          '3', count(*) filter (where voto = 3), '4', count(*) filter (where voto = 4), '5', count(*) filter (where voto = 5)))
                      from pren where voto is not null)),
    'cassa', (select jsonb_build_object('sere', count(*), 'incasso', coalesce(sum(incasso), 0), 'coperti', sum(coperti),
                     'scontrini', sum(scontrini), 'daErp', count(*) filter (where fonte = 'erp'))
                from public.cassa_sere where sera between p_dal and p_al),
    'club', jsonb_build_object(
      'nuovi',  (select count(*) from clu),
      'promo',  (select count(*) from clu where promo),
      'canali', (select coalesce(jsonb_object_agg(can, n), '{}'::jsonb) from (select can, count(*) n from clu group by can) t),
      'premi',  (select coalesce(jsonb_object_agg(tipo, jsonb_build_object('emessi', e, 'usati', u)), '{}'::jsonb) from (
                   select tipo, count(*) filter (where (creato at time zone 'Europe/Rome')::date between p_dal and p_al) e,
                          count(*) filter (where sera_uso between p_dal and p_al) u
                     from public.club_premi group by tipo) t),
      'totale', (select count(*) from public.club_iscritti where public.pr_sera(creato) <= p_al)),
    'agenti', (select coalesce(jsonb_agg(x order by (x->>'euro')::numeric desc, x->>'nome'), '[]'::jsonb) from (
                 select jsonb_build_object('id', a.id, 'nome', a.nome, 'attivo', a.attivo,
                   'giocate', (select count(*) from buo b where b.agente = a.id and b.sera between p_dal and p_al),
                   'tavoli',  (select count(*) from buo b where b.agente = a.id and b.stato = 'riscattato' and b.sera_riscatto between p_dal and p_al),
                   'persone', (select coalesce(sum(persone), 0) from buo b where b.agente = a.id and b.stato = 'riscattato' and b.sera_riscatto between p_dal and p_al),
                   'euro',    (select coalesce(sum(euro), 0) from buo b where b.agente = a.id and b.stato = 'riscattato' and b.sera_riscatto between p_dal and p_al),
                   'pagato',  (select coalesce(sum(importo), 0) from public.pr_pagamenti g where g.agente = a.id and g.data between p_dal and p_al)) x
                 from public.pr_agenti a) t),
    'asporto', jsonb_build_object(
      'ordini', (select count(*) from aspv), 'euro', (select coalesce(sum(totale), 0) from aspv),
      'pezzi',  (select coalesce(sum(pezzi), 0) from aspv), 'annullati', (select count(*) from asp where stato = 'annullato'),
      'clienti', (select count(distinct telefono) from aspv),
      'ritiri', (select coalesce(jsonb_agg(jsonb_build_object('ora', ritiro, 'n', n) order by ritiro), '[]'::jsonb)
                   from (select ritiro, count(*) n from aspv group by ritiro) t),
      'minuti', (select round(avg(extract(epoch from pronto - creato) / 60)) from aspv where pronto is not null),
      'piatti', public.dash_piatti((select array_agg(righe) from aspv))),
    'ordini', jsonb_build_object(
      'ordini', (select count(*) from ord), 'euro', (select coalesce(sum(totale), 0) from ord),
      'coperti', (select coalesce(sum(coperti), 0) from ord), 'tavoli', (select count(distinct (tavolo, sera)) from ord),
      'minuti', (select round(avg(extract(epoch from visto_alle - inviato_alle) / 60)) from ord where visto_alle is not null),
      'piatti', public.dash_piatti((select array_agg(righe) from ord))),
    'whatsapp', jsonb_build_object(
      'conferme', (select jsonb_build_object('inviate', count(*) filter (where wa_stato in ('inviato', 'consegnato', 'letto')),
                          'lette', count(*) filter (where wa_stato = 'letto'), 'errori', count(*) filter (where wa_stato = 'errore'),
                          'attivati', count(wa_attivato))
                     from pren where fonte = 'sito' and wa_stato is not null),
      'messaggi', (select coalesce(jsonb_object_agg(tipo, jsonb_build_object('inviati', i, 'letti', l, 'errori', e, 'saltati', s)), '{}'::jsonb)
                     from (select tipo, count(*) filter (where stato in ('inviato', 'consegnato', 'letto')) i,
                                  count(*) filter (where stato = 'letto') l, count(*) filter (where stato = 'errore') e,
                                  count(*) filter (where stato = 'saltato') s from wau group by tipo) t),
      'ricevuti', (select count(*) from wae), 'stop', (select count(*) from wae where tipo = 'stop')),
    'fortuna', jsonb_build_object(
      'giocate', (select count(*) from fgi), 'riscattate', (select count(*) from fgi where codice is not null),
      'premi', (select coalesce(jsonb_object_agg(emoji || ' ' || (nome->>'it'), n), '{}'::jsonb)
                  from (select emoji, nome, count(*) n from fgi group by emoji, nome) t)),
    'sito', jsonb_build_object(
      'visite', (select coalesce(sum(visite), 0) from public.sito_visite where giorno between p_dal and p_al),
      'canali', (select coalesce(jsonb_object_agg(canale, n), '{}'::jsonb)
                   from (select canale, sum(visite) n from public.sito_visite where giorno between p_dal and p_al group by canale) t),
      'pagine', (select coalesce(jsonb_object_agg(pagina, n), '{}'::jsonb)
                   from (select pagina, sum(visite) n from public.sito_visite where giorno between p_dal and p_al group by pagina) t))
  ) into r;
  return r;
end $$;


-- i clienti: frequenza, nuovi, tornati, da riconquistare (il telefono è la chiave)
create or replace function public.dash_clienti(p_pin text, p_dal date, p_al date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  perform public.pr_controlla_pin(p_pin);
  if p_dal is null or p_al is null or p_al < p_dal then raise exception 'Periodo non valido' using hint = 'periodo'; end if;
  with
  pres as (select distinct telefono, sera from public.dash_presenze() where sera <= p_al),
  per  as (select telefono, count(*) tot, count(*) filter (where sera between p_dal and p_al) nel,
                  min(sera) prima, max(sera) ultima,
                  case when count(*) > 1 then round((max(sera) - min(sera))::numeric / (count(*) - 1), 1) end intervallo
             from pres group by telefono),
  att  as (select * from per where nel > 0)
  select jsonb_build_object(
    'attivi', (select count(*) from att),
    'nuovi',  (select count(*) from att where prima between p_dal and p_al),
    'tornati', (select count(*) from att where prima < p_dal),
    'conosciuti', (select count(*) from per),
    'frequenza', (select jsonb_build_object(
                    '1', count(*) filter (where tot = 1), '2', count(*) filter (where tot = 2),
                    '3', count(*) filter (where tot = 3), '4-5', count(*) filter (where tot between 4 and 5),
                    '6+', count(*) filter (where tot >= 6)) from att),
    'intervalloMedio', (select round(avg(intervallo), 1) from per where intervallo is not null),
    'top', (select coalesce(jsonb_agg(jsonb_build_object('telefono', telefono, 'nome', public.dash_nome(telefono),
                    'visite', tot, 'nelPeriodo', nel, 'prima', prima, 'ultima', ultima, 'intervallo', intervallo,
                    'club', exists (select 1 from public.club_iscritti i where i.telefono = per.telefono)) order by tot desc, ultima desc), '[]'::jsonb)
              from (select * from per order by tot desc, ultima desc limit 40) per),
    'daRiconquistare', (select coalesce(jsonb_agg(jsonb_build_object('telefono', telefono, 'nome', public.dash_nome(telefono),
                    'visite', tot, 'ultima', ultima, 'giorni', p_al - ultima) order by tot desc, ultima), '[]'::jsonb)
              from (select * from per where tot >= 2 and ultima < p_al - 45 order by tot desc, ultima limit 40) per),
    'asporto', (select jsonb_build_object('clienti', count(distinct telefono),
                    'ricorrenti', count(*) filter (where n > 1))
                  from (select telefono, count(*) n from public.asp_ordini where stato <> 'annullato' and sera <= p_al group by telefono) t)
  ) into r;
  return r;
end $$;

-- cerca un cliente per nome o telefono (in tutte le tabelle che hanno un telefono)
create or replace function public.dash_cerca(p_pin text, p_cerca text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  q  text := lower(trim(coalesce(p_cerca, '')));
  qd text := regexp_replace(q, '[^0-9]', '', 'g');
begin
  perform public.pr_controlla_pin(p_pin);
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('telefono', telefono, 'nome', public.dash_nome(telefono)) order by public.dash_nome(telefono))
      from (select distinct telefono from (
              select telefono, nome from public.club_iscritti
              union all select telefono, nome from public.pren_prenotazioni
              union all select telefono, nome from public.asp_ordini
              union all select telefono, nome from public.camp_contatti) t
             where telefono is not null
               and (lower(nome) like '%' || q || '%' or (length(qd) >= 4 and regexp_replace(telefono, '[^0-9]', '', 'g') like '%' || qd || '%'))
             limit 30) x), '[]'::jsonb);
end $$;

-- la scheda di un cliente
create or replace function public.dash_cliente(p_pin text, p_telefono text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t text := public.club_telefono(p_telefono); i public.club_iscritti;
begin
  perform public.pr_controlla_pin(p_pin);
  if t is null then raise exception 'Telefono non valido' using hint = 'telefono'; end if;
  select * into i from public.club_iscritti where telefono = t order by creato limit 1;
  return jsonb_build_object(
    'telefono', t, 'nome', public.dash_nome(t),
    'club', case when i.id is null then null else jsonb_build_object('dal', i.creato, 'email', i.email, 'nascita', i.nascita,
              'promo', i.promo, 'canale', public.dash_club_canale(i), 'lingua', i.lingua, 'ultimoContatto', i.ultimo_contatto) end,
    'presenze', (select count(distinct sera) from public.dash_presenze() p where p.telefono = t),
    'prenotazioni', (select coalesce(jsonb_agg(jsonb_build_object('sera', sera, 'turno', turno, 'persone', persone,
                       'canale', public.dash_pren_canale(p), 'stato', stato, 'voto', voto, 'nota', nota, 'creato', creato,
                       'benvenuto', benvenuto) order by sera desc), '[]'::jsonb)
                       from public.pren_prenotazioni p where p.telefono = t),
    'asporto', (select coalesce(jsonb_agg(jsonb_build_object('sera', sera, 'ritiro', ritiro, 'totale', totale, 'pezzi', pezzi,
                  'stato', stato, 'righe', righe) order by creato desc), '[]'::jsonb)
                  from public.asp_ordini where telefono = t),
    'premi', (select coalesce(jsonb_agg(jsonb_build_object('tipo', r.tipo, 'emoji', r.emoji, 'nome', r.nome->>'it', 'dal', r.dal,
                'al', r.al, 'usato', r.sera_uso) order by r.creato desc), '[]'::jsonb)
                from public.club_premi r where i.id is not null and r.iscritto = i.id),
    'campagne', (select coalesce(jsonb_agg(jsonb_build_object('campagna', c.campagna, 'gruppo', c.gruppo, 'aperto', c.aperto,
                   'premio', c.premio, 'scoperto', c.premio_quando, 'whatsapp', c.wa_quando, 'disiscritto', c.disiscritto)), '[]'::jsonb)
                   from public.camp_contatti c where c.telefono = t),
    'whatsapp', (select jsonb_build_object('stop', coalesce(bool_or(w.stop), false), 'ultimoMessaggio', max(w.ultimo_in),
                   'ricevuti', (select count(*) from public.wa_entrata e where e.telefono = t),
                   'inviati', (select count(*) from public.wa_uscita u where u.telefono = t and u.stato in ('inviato', 'consegnato', 'letto')))
                   from public.wa_contatti w where w.telefono = t));
end $$;

-- lo stato del sistema: code ferme, errori, ultimi invii
create or replace function public.dash_salute(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return jsonb_build_object(
    'adesso', now(),
    'waCoda', (select count(*) from public.wa_uscita where stato = 'in_coda' and quando < now() - interval '30 minutes'),
    'waErrori24h', (select count(*) from public.wa_uscita where stato = 'errore' and creato > now() - interval '24 hours')
                   + (select count(*) from public.pren_prenotazioni where wa_stato = 'errore' and creato > now() - interval '24 hours'),
    'waUltimoErrore', (select errore from public.wa_uscita where stato = 'errore' order by id desc limit 1),
    'waUltimoInvio', (select max(creato) from public.wa_uscita where stato in ('inviato', 'consegnato', 'letto')),
    'waAcceso', (select whatsapp from public.pren_impostazioni where id = 1),
    'avvisiFermi', (select count(*) from public.pren_avvisi where inviato is null and creato < now() - interval '15 minutes'),
    'clubCoda', (select count(*) from public.club_messaggi where inviato is null and creato < now() - interval '30 minutes'),
    'erp', (select jsonb_build_object('collegato', chiave_hash is not null, 'creata', creata, 'ultimoInvio', ultimo_invio,
                                      'ultimoEsito', ultimo_esito) from public.erp_config where id = 1),
    'ultimaSeraCassa', (select max(sera) from public.cassa_sere),
    'oggi', public.pren_oggi(),
    'orologio', (select jsonb_agg(jsonb_build_object('lavoro', j.jobname, 'ultimo', d.end_time, 'esito', d.status))
                   from cron.job j
                   left join lateral (select end_time, status from cron.job_run_details r where r.jobid = j.jobid
                                       order by r.start_time desc limit 1) d on true));
end $$;

-- le impostazioni della dashboard: periodi, gestionale, da quando ci sono i dati
create or replace function public.dash_impostazioni(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return jsonb_build_object(
    'oggi', public.pren_oggi(), 'sera', public.pr_sera(now()),
    'periodi', coalesce((select jsonb_agg(to_jsonb(d) order by d.dal desc) from public.dash_periodi d), '[]'::jsonb),
    'erp', (select jsonb_build_object('collegato', chiave_hash is not null, 'creata', creata, 'ultimoInvio', ultimo_invio,
                                      'ultimoEsito', ultimo_esito) from public.erp_config where id = 1),
    'inizio', jsonb_build_object(
      'agenti', (select min(sera) from public.pr_buoni),
      'club', (select min(public.pr_sera(creato)) from public.club_iscritti),
      'prenotazioni', (select min(sera) from public.pren_prenotazioni),
      'asporto', (select min(sera) from public.asp_ordini),
      'ordini', (select min(public.pr_sera(inviato_alle)) from public.ordini),
      'cassa', (select min(sera) from public.cassa_sere),
      'sito', (select min(giorno) from public.sito_visite)),
    'campagne', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'nome', nome)) from public.camp_campagne), '[]'::jsonb));
end $$;

grant execute on function public.dash_riepilogo(text, date, date), public.dash_clienti(text, date, date),
  public.dash_cerca(text, text), public.dash_cliente(text, text), public.dash_salute(text), public.dash_impostazioni(text)
  to anon, authenticated;
