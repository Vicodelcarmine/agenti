-- =============================================================================
-- VICO AGENTI — modifica del 07/10/2026: validità dei buoni per agente (Leonardo: 3 giorni)
-- e provvigione contata nella sera in cui il tavolo si siede.
-- Estratta da 01-agenti.sql (che resta il file completo e aggiornato).
-- =============================================================================

-- per quante sere vale il buono dei suoi clienti: 1 = solo la sera stessa, 3 = stasera e le due dopo
alter table public.pr_agenti add column if not exists validita int not null default 1 check (validita between 1 and 7);

-- la sera in cui il tavolo si è seduto (può essere dopo quella del gioco, se il buono vale più giorni):
-- è quella che conta per gli scaglioni e per i guadagni della serata
alter table public.pr_buoni add column if not exists sera_riscatto date;
update public.pr_buoni set sera_riscatto = ((riscattato at time zone 'Europe/Rome') - interval '6 hours')::date
 where stato = 'riscattato' and sera_riscatto is null;
create index if not exists pr_buoni_agente_riscatto on public.pr_buoni (agente, sera_riscatto);

create or replace function public.pr_ultimo_della_sera(b public.pr_buoni) returns boolean
language sql stable set search_path = public as $$
  select not exists (
    select 1 from public.pr_buoni x
     where x.agente = b.agente and x.sera_riscatto = b.sera_riscatto and x.stato = 'riscattato' and x.riscattato > b.riscattato)
$$;

create or replace function public.pr_riepilogo(p_agente uuid) returns jsonb
language sql stable set search_path = public as $$
  with s as (select public.pr_sera(now()) as oggi),
       b as (select * from public.pr_buoni where agente = p_agente),
       ok as (select * from b where stato = 'riscattato'),
       pag as (select coalesce(sum(importo), 0) as tot from public.pr_pagamenti where agente = p_agente)
  select jsonb_build_object(
    'stasera', jsonb_build_object(
      'giocate', (select count(*) from b, s where b.sera = s.oggi),
      'tavoli',  (select count(*) from ok, s where ok.sera_riscatto = s.oggi),
      'persone', (select coalesce(sum(persone), 0) from ok, s where ok.sera_riscatto = s.oggi),
      'euro',    (select coalesce(sum(euro), 0) from ok, s where ok.sera_riscatto = s.oggi)),
    'mese', jsonb_build_object(
      'nome', (select (array['gennaio','febbraio','marzo','aprile','maggio','giugno','luglio','agosto',
                             'settembre','ottobre','novembre','dicembre'])[extract(month from oggi)::int] from s),
      'tavoli',  (select count(*) from ok, s where date_trunc('month', ok.sera_riscatto) = date_trunc('month', s.oggi)),
      'persone', (select coalesce(sum(persone), 0) from ok, s where date_trunc('month', ok.sera_riscatto) = date_trunc('month', s.oggi)),
      'euro',    (select coalesce(sum(euro), 0) from ok, s where date_trunc('month', ok.sera_riscatto) = date_trunc('month', s.oggi))),
    'maturato', (select coalesce(sum(euro), 0) from ok),
    'pagato',   (select tot from pag),
    'daPagare', (select coalesce(sum(euro), 0) from ok) - (select tot from pag))
$$;

create or replace function public.pr_gioca(p_codice text, p_dispositivo text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  a public.pr_agenti;
  imp public.pr_impostazioni;
  s date := public.pr_sera(now());
  sc timestamptz;
  b public.pr_buoni;
  p public.pr_premi;
  scelto public.pr_premi;
  tot int;
  r numeric;
  c text;
begin
  if coalesce(length(p_dispositivo), 0) < 8 or length(p_dispositivo) > 64 then
    raise exception 'Dispositivo non valido' using hint = 'dispositivo';
  end if;
  select * into a from public.pr_agenti where codice = upper(p_codice);
  if not found or not a.attivo then raise exception 'QR non attivo' using hint = 'agente'; end if;
  if public.pr_in_pausa(s) then raise exception 'Stasera siamo al completo' using hint = 'pausa'; end if;
  select * into imp from public.pr_impostazioni where id = 1;
  -- il buono vale fino alla chiusura dell'ultima sera di validità di quell'agente
  sc := public.pr_scadenza(s + a.validita - 1, imp.chiusura);
  if now() >= sc then raise exception 'Per stasera abbiamo chiuso' using hint = 'chiuso'; end if;

  -- questo telefono ha già un buono di stasera o ancora valido: gli ridò quello
  select * into b from public.pr_buoni
   where dispositivo = p_dispositivo and (sera = s or (stato = 'attivo' and scade > now()))
   order by creato desc limit 1;
  if found then return public.pr_vista(b) || jsonb_build_object('gia', true); end if;

  if (select count(*) from public.pr_buoni where agente = a.id and sera = s) >= 500 then
    raise exception 'Troppe giocate stasera' using hint = 'troppe';
  end if;

  select sum(peso) into tot from public.pr_premi where attivo and peso > 0;
  if coalesce(tot, 0) = 0 then raise exception 'Nessun premio disponibile' using hint = 'premi'; end if;
  r := random() * tot;
  for p in select * from public.pr_premi where attivo and peso > 0 order by ordine, id loop
    scelto := p;
    r := r - p.peso;
    exit when r <= 0;
  end loop;

  loop
    c := public.pr_casuale(6);
    exit when not exists (select 1 from public.pr_buoni where codice = c);
  end loop;
  insert into public.pr_buoni (codice, agente, premio, sera, scade, dispositivo)
  values (c, a.id,
          jsonb_build_object('id', scelto.id, 'emoji', scelto.emoji, 'nome', scelto.nome, 'desc', scelto.descr),
          s, sc, p_dispositivo)
  returning * into b;
  return public.pr_vista(b);
end $$;

create or replace function public.pr_agente(p_chiave text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.pr_agenti;
begin
  select * into a from public.pr_agenti where chiave = p_chiave;
  if not found then raise exception 'Link non valido' using hint = 'chiave'; end if;
  return jsonb_build_object(
      'nome', a.nome, 'codice', a.codice, 'attivo', a.attivo,
      'fasce', public.pr_fasce_sera(a, public.pr_sera(now())), 'fasceBase', a.fasce,
      'bonusFino', case when public.pr_bonus_ultima(a) >= public.pr_sera(now()) then public.pr_bonus_ultima(a) end,
      'bonusPer', (select bonus_per from public.pr_impostazioni where id = 1),
      'pausa', public.pr_in_pausa(public.pr_sera(now())),
      'validita', a.validita,
      'ultimi', coalesce((
        select jsonb_agg(to_jsonb(x) order by x.quando desc) from (
          select riscattato as quando, sera_riscatto as sera, persone, euro from public.pr_buoni
           where agente = a.id and stato = 'riscattato' order by riscattato desc limit 12) x), '[]'::jsonb))
    || public.pr_riepilogo(a.id);
end $$;

create or replace function public.pr_leggi_buono(p_pin text, p_codice text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b public.pr_buoni; a public.pr_agenti; gia int; s date := public.pr_sera(now());
begin
  perform public.pr_controlla_pin(p_pin);
  select * into b from public.pr_buoni where codice = upper(p_codice);
  if not found then raise exception 'Nessun buono con questo codice' using hint = 'buono'; end if;
  select * into a from public.pr_agenti where id = b.agente;
  -- il tavolo conta nella sera in cui si siede (stasera), non in quella in cui ha giocato
  select coalesce(sum(persone), 0) into gia from public.pr_buoni
   where agente = a.id and sera_riscatto = s and stato = 'riscattato' and codice <> b.codice;
  return public.pr_vista(b) || jsonb_build_object(
    'agente', jsonb_build_object('id', a.id, 'nome', a.nome, 'attivo', a.attivo),
    'fasce', public.pr_fasce_sera(a, s), 'giaStasera', gia,
    'bonus', coalesce(s <= public.pr_bonus_ultima(a), false),
    'seraGioco', b.sera,
    'annullabile', b.stato = 'riscattato' and public.pr_ultimo_della_sera(b));
end $$;

create or replace function public.pr_riscatta(p_pin text, p_codice text, p_persone int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare b public.pr_buoni; a public.pr_agenti; gia int; e numeric; s date := public.pr_sera(now());
begin
  perform public.pr_controlla_pin(p_pin);
  if p_persone is null or p_persone < 1 or p_persone > 60 then
    raise exception 'Numero di persone non valido' using hint = 'persone';
  end if;
  select * into b from public.pr_buoni where codice = upper(p_codice) for update;
  if not found then raise exception 'Nessun buono con questo codice' using hint = 'buono'; end if;
  if b.stato = 'riscattato' then raise exception 'Buono già usato' using hint = 'usato'; end if;
  if now() >= b.scade then raise exception 'Buono scaduto' using hint = 'scaduto'; end if;
  -- blocco l'agente: due riscatti insieme non sbagliano lo scaglione
  select * into a from public.pr_agenti where id = b.agente for update;
  select coalesce(sum(persone), 0) into gia from public.pr_buoni
   where agente = a.id and sera_riscatto = s and stato = 'riscattato';
  e := public.pr_provvigione(public.pr_fasce_sera(a, s), gia, p_persone);
  update public.pr_buoni set stato = 'riscattato', riscattato = clock_timestamp(), sera_riscatto = s,
                             persone = p_persone, euro = e
   where codice = b.codice;
  return jsonb_build_object('euro', e, 'gia', gia, 'fasce', public.pr_fasce_sera(a, s), 'agente', a.nome, 'premio', b.premio);
end $$;

create or replace function public.pr_annulla(p_pin text, p_codice text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare b public.pr_buoni;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into b from public.pr_buoni where codice = upper(p_codice) for update;
  if not found or b.stato <> 'riscattato' then raise exception 'Niente da annullare' using hint = 'buono'; end if;
  if not public.pr_ultimo_della_sera(b) then
    raise exception 'Si può annullare solo l''ultimo tavolo di quell''agente' using hint = 'ordine';
  end if;
  update public.pr_buoni set stato = 'attivo', riscattato = null, sera_riscatto = null, persone = null, euro = null,
                             notificato = false
   where codice = b.codice;
  return true;
end $$;

create or replace function public.pr_panoramica(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s date := public.pr_sera(now());
begin
  perform public.pr_controlla_pin(p_pin);
  return jsonb_build_object(
    'agenti', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'nome', a.nome, 'telefono', a.telefono,
                                          'attivo', a.attivo, 'codice', a.codice, 'validita', a.validita,
                                          'bonusFino', case when public.pr_bonus_ultima(a) >= s then public.pr_bonus_ultima(a) end)
                       || public.pr_riepilogo(a.id) order by a.creato)
        from public.pr_agenti a), '[]'::jsonb),
    'tavoli', coalesce((
      select jsonb_agg(jsonb_build_object('codice', b.codice, 'agente', a.nome, 'quando', b.riscattato,
                                          'persone', b.persone, 'euro', b.euro, 'premio', b.premio,
                                          'annullabile', public.pr_ultimo_della_sera(b))
                       order by b.riscattato desc)
        from public.pr_buoni b join public.pr_agenti a on a.id = b.agente
       where b.sera_riscatto = s and b.stato = 'riscattato'), '[]'::jsonb),
    'inAttesa', (select count(*) from public.pr_buoni where stato = 'attivo' and now() < scade),
    'giocate',  (select count(*) from public.pr_buoni where sera = s),
    'chiusura', (select chiusura from public.pr_impostazioni where id = 1));
end $$;

create or replace function public.pr_dettaglio_agente(p_pin text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.pr_agenti;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into a from public.pr_agenti where id = p_id;
  if not found then raise exception 'Agente non trovato' using hint = 'agente'; end if;
  return to_jsonb(a) || public.pr_riepilogo(a.id) || jsonb_build_object(
    'bonusFino', case when public.pr_bonus_ultima(a) >= public.pr_sera(now()) then public.pr_bonus_ultima(a) end,
    'bonusPeriodo', case when public.pr_bonus_periodo(a) >= public.pr_sera(now()) then public.pr_bonus_periodo(a) end,
    'bonusPer', (select bonus_per from public.pr_impostazioni where id = 1),
    'serate', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.sera desc) from (
        select d.sera, coalesce(g.giocate, 0) as giocate, coalesce(r.tavoli, 0) as tavoli,
               coalesce(r.persone, 0) as persone, coalesce(r.euro, 0) as euro
          from (select sera from public.pr_buoni where agente = a.id
                union
                select sera_riscatto from public.pr_buoni where agente = a.id and stato = 'riscattato') d
          left join (select sera, count(*) as giocate from public.pr_buoni where agente = a.id group by sera) g
                 on g.sera = d.sera
          left join (select sera_riscatto, count(*) as tavoli, sum(persone) as persone, sum(euro) as euro
                       from public.pr_buoni where agente = a.id and stato = 'riscattato' group by sera_riscatto) r
                 on r.sera_riscatto = d.sera) x), '[]'::jsonb),
    'pagamenti', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'importo', p.importo, 'data', p.data, 'nota', p.nota)
                       order by p.data desc)
        from public.pr_pagamenti p where p.agente = a.id), '[]'::jsonb));
end $$;

create or replace function public.pr_salva_agente(p_pin text, p_dati jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a public.pr_agenti; c text;
begin
  perform public.pr_controlla_pin(p_pin);
  if nullif(p_dati->>'id', '') is not null then
    select * into a from public.pr_agenti where id = (p_dati->>'id')::uuid for update;
    if not found then raise exception 'Agente non trovato' using hint = 'agente'; end if;
  else
    loop
      c := public.pr_casuale(5);
      exit when not exists (select 1 from public.pr_agenti where codice = c);
    end loop;
    insert into public.pr_agenti (codice, chiave, nome, fasce)
    values (c, public.pr_casuale(20), 'Agente', (select fasce from public.pr_impostazioni where id = 1))
    returning * into a;
  end if;
  if p_dati ? 'nome' then
    update public.pr_agenti set nome = coalesce(nullif(left(trim(p_dati->>'nome'), 60), ''), 'Agente') where id = a.id;
  end if;
  if p_dati ? 'telefono' then
    update public.pr_agenti set telefono = left(coalesce(trim(p_dati->>'telefono'), ''), 30) where id = a.id;
  end if;
  if p_dati ? 'attivo' then
    update public.pr_agenti set attivo = (p_dati->>'attivo')::boolean where id = a.id;
  end if;
  if p_dati ? 'bonus' then
    update public.pr_agenti set bonus = (p_dati->>'bonus')::boolean where id = a.id;
  end if;
  if p_dati ? 'validita' then
    if coalesce(p_dati->>'validita', '') !~ '^[1-7]$' then
      raise exception 'Validità non valida (da 1 a 7 giorni)' using hint = 'validita';
    end if;
    update public.pr_agenti set validita = (p_dati->>'validita')::int where id = a.id;
  end if;
  if p_dati ? 'fasce' then
    update public.pr_agenti set fasce = public.pr_valida_fasce(p_dati->'fasce') where id = a.id;
  end if;
  select * into a from public.pr_agenti where id = a.id;
  return to_jsonb(a);
end $$;

create or replace function public.pr_salva_impostazioni(p_pin text, p_dati jsonb) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare s date := public.pr_sera(now()); ch text := p_dati->>'chiusura'; v text;
begin
  perform public.pr_controlla_pin(p_pin);
  if ch is not null then
    if ch !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'Orario non valido' using hint = 'ora'; end if;
    update public.pr_impostazioni set chiusura = ch where id = 1;
    -- i buoni ancora da usare seguono il nuovo orario (ognuno nella sua ultima sera di validità)
    update public.pr_buoni set scade = public.pr_scadenza(public.pr_sera(scade), ch)
     where stato = 'attivo' and scade > now();
  end if;
  if p_dati ? 'fasce' then
    update public.pr_impostazioni set fasce = public.pr_valida_fasce(p_dati->'fasce') where id = 1;
  end if;
  if p_dati ? 'bonusGiorni' then
    v := trim(p_dati->>'bonusGiorni');
    if coalesce(v, '') !~ '^\d{1,2}$' or v::int > 60 then
      raise exception 'Giorni di benvenuto non validi (da 0 a 60)' using hint = 'bonus';
    end if;
    update public.pr_impostazioni set bonus_giorni = v::int where id = 1;
  end if;
  if p_dati ? 'bonusPer' then
    v := replace(trim(p_dati->>'bonusPer'), ',', '.');
    if coalesce(v, '') !~ '^\d(\.\d{1,2})?$' or v::numeric < 1 or v::numeric > 5 then
      raise exception 'Moltiplicatore non valido (da 1 a 5)' using hint = 'bonus';
    end if;
    update public.pr_impostazioni set bonus_per = v::numeric where id = 1;
  end if;
  if p_dati ? 'giorniPausa' then
    if jsonb_typeof(p_dati->'giorniPausa') <> 'array' then raise exception 'Giorni di pausa non validi' using hint = 'pausa'; end if;
    update public.pr_impostazioni
       set giorni_pausa = coalesce((select array_agg(distinct g::int order by g::int)
                                      from jsonb_array_elements_text(p_dati->'giorniPausa') g
                                     where g ~ '^[0-6]$'), '{}')
     where id = 1;
  end if;
  return true;
end $$;

-- Leonardo: i buoni dei suoi clienti valgono 3 giorni (stasera e le due sere dopo) — richiesta del titolare, 07/10/2026
update public.pr_agenti set validita = 3 where nome = 'Leonardo';

-- controllo
select nome, validita, bonus, (select count(*) from public.pr_buoni b where b.agente = a.id and b.stato = 'riscattato' and b.sera_riscatto is null) as riscattati_senza_sera
  from public.pr_agenti a;