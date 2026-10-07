-- =============================================================================
-- VICO AGENTI — database (Supabase del Vico del Carmine)
-- Tutto ha il prefisso pr_ : NON tocca le tabelle del menu né quelle degli ordini.
-- Le tabelle non sono leggibili dall'esterno (RLS senza regole): si passa solo
-- dalle funzioni qui sotto, che controllano PIN del titolare o link dell'agente.
-- Si può rieseguire: non cancella niente.
-- =============================================================================

-- ---------- tabelle ----------
create table if not exists public.pr_impostazioni (
  id       int primary key default 1 check (id = 1),
  chiusura text  not null default '23:30',
  fasce    jsonb not null default '[{"fino":10,"euro":2},{"fino":20,"euro":3},{"fino":null,"euro":4}]'
);
insert into public.pr_impostazioni (id) values (1) on conflict (id) do nothing;
-- settimana di benvenuto: i primi giorni dell'agente le tariffe sono moltiplicate (0 giorni = niente bonus)
alter table public.pr_impostazioni add column if not exists bonus_giorni int not null default 7;
alter table public.pr_impostazioni add column if not exists bonus_per numeric(4,2) not null default 2;
-- giorni di pausa del servizio (0 = domenica … 6 = sabato): quella sera il gioco non dà buoni
alter table public.pr_impostazioni add column if not exists giorni_pausa int[] not null default '{6}';

create table if not exists public.pr_agenti (
  id       uuid primary key default gen_random_uuid(),
  codice   text unique not null,              -- pubblico: sta nel QR del gioco
  chiave   text unique not null,              -- segreto: link personale dell'app agente
  nome     text not null,
  telefono text not null default '',
  attivo   boolean not null default true,
  fasce    jsonb not null,
  creato   timestamptz not null default now()
);
-- false = per questo agente la settimana di benvenuto non vale (es. lavorava già prima)
alter table public.pr_agenti add column if not exists bonus boolean not null default true;
-- per quante sere vale il buono dei suoi clienti: 1 = solo la sera stessa, 3 = stasera e le due dopo
alter table public.pr_agenti add column if not exists validita int not null default 1 check (validita between 1 and 7);

create table if not exists public.pr_premi (
  id     text primary key,
  ordine int  not null default 0,
  emoji  text not null default '🎁',
  peso   int  not null default 10 check (peso >= 0),
  attivo boolean not null default true,
  nome   jsonb not null default '{}',          -- {"it": "...", "en": "..."}
  descr  jsonb not null default '{}'
);

create table if not exists public.pr_buoni (
  codice      text primary key,
  agente      uuid not null references public.pr_agenti(id),
  premio      jsonb not null,                  -- copia del premio com'era quando è uscito
  creato      timestamptz not null default now(),
  sera        date not null,
  scade       timestamptz not null,
  dispositivo text not null,
  stato       text not null default 'attivo' check (stato in ('attivo', 'riscattato')),
  riscattato  timestamptz,
  persone     int,
  euro        numeric(8,2),
  notificato  boolean not null default false
);
create index if not exists pr_buoni_agente_sera on public.pr_buoni (agente, sera);
create index if not exists pr_buoni_disp_sera   on public.pr_buoni (dispositivo, sera);
create index if not exists pr_buoni_sera        on public.pr_buoni (sera);
-- la sera in cui il tavolo si è seduto (può essere dopo quella del gioco, se il buono vale più giorni):
-- è quella che conta per gli scaglioni e per i guadagni della serata
alter table public.pr_buoni add column if not exists sera_riscatto date;
update public.pr_buoni set sera_riscatto = ((riscattato at time zone 'Europe/Rome') - interval '6 hours')::date
 where stato = 'riscattato' and sera_riscatto is null;
create index if not exists pr_buoni_agente_riscatto on public.pr_buoni (agente, sera_riscatto);

create table if not exists public.pr_pagamenti (
  id      uuid primary key default gen_random_uuid(),
  agente  uuid not null references public.pr_agenti(id),
  importo numeric(8,2) not null check (importo > 0),
  data    timestamptz not null default now(),
  nota    text not null default ''
);

create table if not exists public.pr_push (
  endpoint text primary key,
  agente   uuid not null references public.pr_agenti(id) on delete cascade,
  sub      jsonb not null,
  creato   timestamptz not null default now()
);

-- chiavi delle notifiche: le crea e le legge solo la funzione pr-notifica
create table if not exists public.pr_config (
  chiave text primary key,
  valore text not null
);

alter table public.pr_impostazioni enable row level security;
alter table public.pr_agenti       enable row level security;
alter table public.pr_premi        enable row level security;
alter table public.pr_buoni        enable row level security;
alter table public.pr_pagamenti    enable row level security;
alter table public.pr_push         enable row level security;
alter table public.pr_config       enable row level security;

-- premi di partenza (gli stessi della slot di oggi), solo se la tabella è vuota
insert into public.pr_premi (id, ordine, emoji, peso, nome, descr)
select * from (values
  ('DOLCE',    1, '🍰', 15, '{"it":"DOLCE OMAGGIO!","en":"FREE DESSERT!"}'::jsonb,
                            '{"it":"Un dolce della casa offerto da noi!","en":"A homemade dessert on the house!"}'::jsonb),
  ('VENTI',    2, '🔥',  8, '{"it":"-20% SUL CONTO!","en":"20% OFF!"}'::jsonb,
                            '{"it":"Sconto del 20% sul conto totale di stasera!","en":"20% off your total bill tonight!"}'::jsonb),
  ('DIECI',    3, '🍕', 25, '{"it":"-10% SUL CONTO!","en":"10% OFF!"}'::jsonb,
                            '{"it":"Sconto del 10% sul conto totale di stasera!","en":"10% off your total bill tonight!"}'::jsonb),
  ('BOLLE',    4, '🥂', 15, '{"it":"PROSECCO OMAGGIO!","en":"FREE PROSECCO!"}'::jsonb,
                            '{"it":"Un calice di prosecco offerto dalla casa!","en":"A glass of prosecco on the house!"}'::jsonb),
  ('SPRITZ',   5, '🍹', 10, '{"it":"SPRITZ OMAGGIO!","en":"FREE SPRITZ!"}'::jsonb,
                            '{"it":"Uno Spritz Aperol o Hugo offerto da noi!","en":"A free Aperol or Hugo Spritz!"}'::jsonb),
  ('CAFFE',    6, '🧁', 20, '{"it":"CAFFÈ + DOLCETTO!","en":"COFFEE + SWEET!"}'::jsonb,
                            '{"it":"Caffè e un dolcetto della casa offerti!","en":"Coffee and a sweet treat on the house!"}'::jsonb),
  ('QUINDICI', 7, '⭐',  7, '{"it":"-15% SUL CONTO!","en":"15% OFF!"}'::jsonb,
                            '{"it":"Sconto del 15% sul conto totale di stasera!","en":"15% off your total bill tonight!"}'::jsonb)
) as v(id, ordine, emoji, peso, nome, descr)
where not exists (select 1 from public.pr_premi);


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- la "sera" di un momento: fino alle 6 del mattino conta ancora la sera prima (ora di Firenze)
create or replace function public.pr_sera(t timestamptz default now()) returns date
language sql stable set search_path = public as $$
  select ((t at time zone 'Europe/Rome') - interval '6 hours')::date
$$;

-- quando scadono i buoni di quella sera ("23:30"; "01:00" = dopo mezzanotte)
create or replace function public.pr_scadenza(s date, chiusura text) returns timestamptz
language sql stable set search_path = public as $$
  select ((s + case when split_part(chiusura, ':', 1)::int < 6 then 1 else 0 end) + chiusura::time)
         at time zone 'Europe/Rome'
$$;

-- euro per la persona n-esima della serata
create or replace function public.pr_tariffa(fasce jsonb, persona int) returns numeric
language sql immutable set search_path = public as $$
  select coalesce(
    (select (f->>'euro')::numeric
       from jsonb_array_elements(fasce) with ordinality as x(f, i)
      where f->>'fino' is null or persona <= (f->>'fino')::int
      order by i limit 1),
    (fasce->-1->>'euro')::numeric)
$$;

-- provvigione a scaglioni: gia = persone già portate stasera, n = persone del tavolo
create or replace function public.pr_provvigione(fasce jsonb, gia int, n int) returns numeric
language sql immutable set search_path = public as $$
  select coalesce(sum(public.pr_tariffa(fasce, k)), 0) from generate_series(gia + 1, gia + n) as k
$$;

-- ultima sera della settimana di benvenuto, contata da quando l'agente è stato creato (null = niente bonus)
create or replace function public.pr_bonus_periodo(a public.pr_agenti) returns date
language sql stable set search_path = public as $$
  select case when i.bonus_giorni > 0 and i.bonus_per > 1 then public.pr_piu_sere(public.pr_sera(a.creato), i.bonus_giorni) end
    from public.pr_impostazioni i where i.id = 1
$$;

-- come sopra, ma solo se per quell'agente il bonus è acceso
create or replace function public.pr_bonus_ultima(a public.pr_agenti) returns date
language sql stable set search_path = public as $$
  select case when a.bonus then public.pr_bonus_periodo(a) end
$$;

-- tariffe che valgono per quell'agente in quella sera (in settimana di benvenuto: moltiplicate)
create or replace function public.pr_fasce_sera(a public.pr_agenti, s date) returns jsonb
language sql stable set search_path = public as $$
  select case when s <= public.pr_bonus_ultima(a) then (
           select jsonb_agg(jsonb_build_object('fino', x.f->'fino',
                                               'euro', round((x.f->>'euro')::numeric * i.bonus_per, 2)) order by x.n)
             from jsonb_array_elements(a.fasce) with ordinality as x(f, n), public.pr_impostazioni i
            where i.id = 1)
         else a.fasce end
$$;

-- quella sera il servizio è in pausa? (es. il sabato: siamo già al completo)
create or replace function public.pr_in_pausa(s date) returns boolean
language sql stable set search_path = public as $$
  select extract(dow from s)::int = any(giorni_pausa) from public.pr_impostazioni where id = 1
$$;

-- la n-esima sera di servizio a partire da s compresa, SALTANDO i giorni di pausa (il sabato non si conta mai)
create or replace function public.pr_piu_sere(s date, n int) returns date
language plpgsql stable set search_path = public as $$
declare d date := s; contate int := 0;
begin
  if n < 1 then return s; end if;
  for i in 1 .. n + 60 loop
    if not public.pr_in_pausa(d) then
      contate := contate + 1;
      if contate = n then return d; end if;
    end if;
    d := d + 1;
  end loop;
  return s + n - 1;   -- tutti i giorni in pausa: conto normale
end $$;

create or replace function public.pr_casuale(n int) returns text
language plpgsql volatile set search_path = public as $$
declare
  alfabeto text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  b bytea := extensions.gen_random_bytes(n);
  s text := '';
begin
  for i in 0 .. n - 1 loop
    s := s || substr(alfabeto, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return s;
end $$;

-- il buono come lo vede il cliente
create or replace function public.pr_vista(b public.pr_buoni) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'codice', b.codice, 'premio', b.premio, 'creato', b.creato, 'scade', b.scade,
    'stato', case when b.stato = 'attivo' and now() >= b.scade then 'scaduto' else b.stato end,
    'persone', b.persone, 'euro', b.euro, 'riscattato', b.riscattato)
$$;

-- si può annullare solo l'ultimo tavolo della sera di un agente (così i conti a scaglioni restano giusti)
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

-- fasce scritte dal titolare → controllate e pulite (accetta "2,5" o 2.5)
create or replace function public.pr_valida_fasce(f jsonb) returns jsonb
language plpgsql immutable set search_path = public as $$
declare
  n int := coalesce(jsonb_array_length(f), 0);
  fuori jsonb := '[]';
  prima int := 0;
  fino int;
  e text;
begin
  if n < 1 or n > 6 then raise exception 'Fasce non valide' using hint = 'fasce'; end if;
  for i in 0 .. n - 1 loop
    e := trim(f->i->>'euro');
    if e is null or e !~ '^\d+([.,]\d{1,2})?$' then raise exception 'Importo non valido' using hint = 'fasce'; end if;
    if i = n - 1 then
      fino := null;
    else
      if coalesce(trim(f->i->>'fino'), '') !~ '^\d+$' then raise exception 'Numero di persone non valido' using hint = 'fasce'; end if;
      fino := (f->i->>'fino')::int;
      if fino <= prima then raise exception 'Le fasce devono salire (es. 10, poi 20)' using hint = 'fasce'; end if;
      prima := fino;
    end if;
    fuori := fuori || jsonb_build_array(jsonb_build_object('fino', fino, 'euro', replace(e, ',', '.')::numeric));
  end loop;
  return fuori;
end $$;

-- PIN del titolare: è lo stesso PIN da titolare del menu
create or replace function public.pr_controlla_pin(p_pin text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if p_pin is null or p_pin = '' or not exists (
       select 1 from public.app_secrets where pw_titolare = p_pin) then
    raise exception 'PIN sbagliato' using hint = 'pin';
  end if;
end $$;

revoke execute on function public.pr_riepilogo(uuid)       from public, anon, authenticated;
revoke execute on function public.pr_controlla_pin(text)   from public, anon, authenticated;
revoke execute on function public.pr_casuale(int)          from public, anon, authenticated;
revoke execute on function public.pr_vista(public.pr_buoni)            from public, anon, authenticated;
revoke execute on function public.pr_ultimo_della_sera(public.pr_buoni) from public, anon, authenticated;
revoke execute on function public.pr_bonus_periodo(public.pr_agenti)      from public, anon, authenticated;
revoke execute on function public.pr_bonus_ultima(public.pr_agenti)       from public, anon, authenticated;
revoke execute on function public.pr_fasce_sera(public.pr_agenti, date)   from public, anon, authenticated;


-- ================= CLIENTE (pagina del gioco) =================

create or replace function public.pr_agente_pubblico(p_codice text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.pr_agenti;
begin
  select * into a from public.pr_agenti where codice = upper(p_codice);
  if not found then raise exception 'QR non valido' using hint = 'agente'; end if;
  return jsonb_build_object('attivo', a.attivo, 'pausa', public.pr_in_pausa(public.pr_sera(now())));
end $$;

-- gira la slot: il premio lo sceglie il server, il telefono non può barare
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
  -- il buono vale fino alla chiusura dell'ultima sera di validità di quell'agente (il sabato non si conta)
  sc := public.pr_scadenza(public.pr_piu_sere(s, a.validita), imp.chiusura);
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

create or replace function public.pr_buono(p_codice text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b public.pr_buoni;
begin
  select * into b from public.pr_buoni where codice = upper(p_codice);
  if not found then raise exception 'Buono non trovato' using hint = 'buono'; end if;
  return public.pr_vista(b);
end $$;


-- ================= AGENTE =================

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

create or replace function public.pr_salva_push(p_chiave text, p_sub jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare a public.pr_agenti;
begin
  select * into a from public.pr_agenti where chiave = p_chiave;
  if not found then raise exception 'Link non valido' using hint = 'chiave'; end if;
  if coalesce(p_sub->>'endpoint', '') !~ '^https://' then raise exception 'Abbonamento non valido' using hint = 'push'; end if;
  insert into public.pr_push (endpoint, agente, sub) values (p_sub->>'endpoint', a.id, p_sub)
  on conflict (endpoint) do update set agente = excluded.agente, sub = excluded.sub, creato = now();
  return true;
end $$;


-- ================= TITOLARE =================

create or replace function public.pr_entra(p_pin text) returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return true;
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

-- elimina un agente con tutto il suo storico (buoni, pagamenti, notifiche): non si torna indietro
create or replace function public.pr_elimina_agente(p_pin text, p_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a public.pr_agenti; tavoli int;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into a from public.pr_agenti where id = p_id for update;
  if not found then raise exception 'Agente non trovato' using hint = 'agente'; end if;
  select count(*) into tavoli from public.pr_buoni where agente = a.id and stato = 'riscattato';
  delete from public.pr_pagamenti where agente = a.id;
  delete from public.pr_buoni where agente = a.id;
  delete from public.pr_agenti where id = a.id;          -- pr_push se ne va da sola (on delete cascade)
  return jsonb_build_object('nome', a.nome, 'tavoli', tavoli);
end $$;

-- nuovo link per l'agente (es. ha perso il telefono): il vecchio smette di funzionare
create or replace function public.pr_nuova_chiave(p_pin text, p_id uuid) returns text
language plpgsql volatile security definer set search_path = public as $$
declare k text := public.pr_casuale(20);
begin
  perform public.pr_controlla_pin(p_pin);
  update public.pr_agenti set chiave = k where id = p_id;
  if not found then raise exception 'Agente non trovato' using hint = 'agente'; end if;
  delete from public.pr_push where agente = p_id;
  return k;
end $$;

create or replace function public.pr_pagamento(p_pin text, p_agente uuid, p_importo text, p_nota text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare v text := trim(coalesce(p_importo, ''));
begin
  perform public.pr_controlla_pin(p_pin);
  if v !~ '^\d+([.,]\d{1,2})?$' or replace(v, ',', '.')::numeric <= 0 then
    raise exception 'Importo non valido' using hint = 'importo';
  end if;
  if not exists (select 1 from public.pr_agenti where id = p_agente) then
    raise exception 'Agente non trovato' using hint = 'agente';
  end if;
  insert into public.pr_pagamenti (agente, importo, nota)
  values (p_agente, replace(v, ',', '.')::numeric, left(coalesce(trim(p_nota), ''), 120));
  return true;
end $$;

create or replace function public.pr_premi(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'emoji', emoji, 'peso', peso, 'attivo', attivo,
                                        'nome', nome, 'desc', descr) order by ordine, id)
      from public.pr_premi), '[]'::jsonb);
end $$;

create or replace function public.pr_salva_premi(p_pin text, p_lista jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare x jsonb; i int := 0; nuovo text;
begin
  perform public.pr_controlla_pin(p_pin);
  if jsonb_typeof(p_lista) <> 'array' or jsonb_array_length(p_lista) > 40 then
    raise exception 'Elenco premi non valido' using hint = 'premi';
  end if;
  if not exists (select 1 from jsonb_array_elements(p_lista) e
                  where (e->>'attivo')::boolean and coalesce((e->>'peso')::int, 0) > 0
                    and trim(coalesce(e->'nome'->>'it', '')) <> '') then
    raise exception 'Serve almeno un premio attivo' using hint = 'premi';
  end if;
  delete from public.pr_premi where true;   -- i buoni già usciti hanno la loro copia del premio
  for x in select value from jsonb_array_elements(p_lista) loop
    i := i + 1;
    nuovo := coalesce(nullif(x->>'id', ''), public.pr_casuale(6));
    insert into public.pr_premi (id, ordine, emoji, peso, attivo, nome, descr)
    values (nuovo, i, left(coalesce(nullif(trim(x->>'emoji'), ''), '🎁'), 8),
            greatest(0, least(1000, coalesce((x->>'peso')::int, 0))),
            coalesce((x->>'attivo')::boolean, true),
            jsonb_build_object('it', left(trim(coalesce(x->'nome'->>'it', '')), 60),
                               'en', left(trim(coalesce(x->'nome'->>'en', '')), 60)),
            jsonb_build_object('it', left(trim(coalesce(x->'desc'->>'it', '')), 160),
                               'en', left(trim(coalesce(x->'desc'->>'en', '')), 160)))
    on conflict (id) do nothing;
  end loop;
  return public.pr_premi(p_pin);
end $$;

create or replace function public.pr_impostazioni(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return (select jsonb_build_object('chiusura', chiusura, 'fasce', fasce, 'bonusGiorni', bonus_giorni,
                                     'bonusPer', bonus_per, 'giorniPausa', to_jsonb(giorni_pausa))
            from public.pr_impostazioni where id = 1);
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

-- le funzioni pubbliche si chiamano con la chiave publishable del sito
grant execute on function
  public.pr_agente_pubblico(text), public.pr_gioca(text, text), public.pr_buono(text),
  public.pr_agente(text), public.pr_salva_push(text, jsonb),
  public.pr_entra(text), public.pr_leggi_buono(text, text), public.pr_riscatta(text, text, int),
  public.pr_annulla(text, text), public.pr_panoramica(text), public.pr_dettaglio_agente(text, uuid),
  public.pr_salva_agente(text, jsonb), public.pr_nuova_chiave(text, uuid), public.pr_elimina_agente(text, uuid),
  public.pr_pagamento(text, uuid, text, text), public.pr_premi(text), public.pr_salva_premi(text, jsonb),
  public.pr_impostazioni(text), public.pr_salva_impostazioni(text, jsonb)
to anon, authenticated;
