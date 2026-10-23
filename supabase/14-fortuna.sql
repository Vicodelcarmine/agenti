-- =============================================================================
-- TENTA LA FORTUNA (menu/fortuna.html) — il premio lo sceglie il server, si riscatta nel Club
-- Si esegue DOPO 07/08-club.sql. Chi apre il gioco vede un conto alla rovescia e
-- riceve un premio a caso (pesi in fortuna_premi). Per riscattarlo entra nel Club:
-- il premio diventa un premio del Club (tipo 'fortuna') che vale solo quella sera,
-- con il suo QR nella tessera; il titolare lo usa dalla dashboard come gli altri.
-- Regole: un premio a sera per telefono e per socio; nelle sere senza premi del Club
-- (sabato, giorno di chiusura) la fortuna riposa; dopo la chiusura il gioco è finito.
-- Si può rieseguire: non cancella niente (i premi già scritti restano come sono).
-- =============================================================================

-- ---------- tabelle ----------
create table if not exists public.fortuna_premi (
  id       text primary key,
  emoji    text not null,
  nome     jsonb not null,                 -- {it, en, de, es}
  descr    jsonb not null,
  persone  int  not null default 1,        -- 0 = sul conto (gli sconti)
  peso     int  not null check (peso >= 0),-- più alto = esce più spesso
  attivo   boolean not null default true,
  ordine   int  not null default 0
);
insert into public.fortuna_premi (id, emoji, nome, descr, persone, peso, ordine) values
  ('DOLCE', '🍰', '{"it":"Dolce della casa offerto","en":"Free homemade dessert","de":"Hausgemachtes Dessert gratis","es":"Postre casero gratis"}',
             '{"it":"Un dolce della casa offerto da noi!","en":"A homemade dessert on us!","de":"Ein hausgemachtes Dessert geht auf uns!","es":"¡Un postre casero invitado por nosotros!"}', 1, 15, 1),
  ('VENTI', '🔥', '{"it":"Sconto del 20% sul conto","en":"20% off your bill","de":"20% Rabatt auf die Rechnung","es":"20% de descuento en la cuenta"}',
             '{"it":"Sconto del 20% sul conto totale di stasera!","en":"20% off tonight''s total bill!","de":"20% Rabatt auf die heutige Gesamtrechnung!","es":"¡20% de descuento en la cuenta de esta noche!"}', 0, 8, 2),
  ('DIECI', '🍕', '{"it":"Sconto del 10% sul conto","en":"10% off your bill","de":"10% Rabatt auf die Rechnung","es":"10% de descuento en la cuenta"}',
             '{"it":"Sconto del 10% sul conto totale di stasera!","en":"10% off tonight''s total bill!","de":"10% Rabatt auf die heutige Gesamtrechnung!","es":"¡10% de descuento en la cuenta de esta noche!"}', 0, 25, 3),
  ('BOLLE', '🥂', '{"it":"Calice di prosecco offerto","en":"Free glass of prosecco","de":"Ein Glas Prosecco gratis","es":"Copa de prosecco gratis"}',
             '{"it":"Un calice di prosecco offerto dalla casa!","en":"A glass of prosecco on the house!","de":"Ein Glas Prosecco aufs Haus!","es":"¡Una copa de prosecco invitada por la casa!"}', 1, 15, 4),
  ('SPRITZ', '🍹', '{"it":"Spritz offerto","en":"Free Spritz","de":"Spritz gratis","es":"Spritz gratis"}',
             '{"it":"Uno Spritz Aperol o Hugo offerto da noi!","en":"An Aperol or Hugo Spritz on us!","de":"Ein Aperol oder Hugo Spritz geht auf uns!","es":"¡Un Spritz Aperol o Hugo invitado por nosotros!"}', 1, 10, 5),
  ('CAFFE', '🧁', '{"it":"Caffè e dolcetto offerti","en":"Free coffee and a sweet treat","de":"Kaffee und Süßes gratis","es":"Café y dulce gratis"}',
             '{"it":"Caffè e un dolcetto della casa offerti!","en":"Coffee and a homemade sweet treat on us!","de":"Kaffee und eine hausgemachte Süßigkeit gratis!","es":"¡Café y un dulce casero invitados!"}', 1, 20, 6),
  ('QUINDICI', '⭐', '{"it":"Sconto del 15% sul conto","en":"15% off your bill","de":"15% Rabatt auf die Rechnung","es":"15% de descuento en la cuenta"}',
             '{"it":"Sconto del 15% sul conto totale di stasera!","en":"15% off tonight''s total bill!","de":"15% Rabatt auf die heutige Gesamtrechnung!","es":"¡15% de descuento en la cuenta de esta noche!"}', 0, 7, 7)
on conflict (id) do nothing;

create table if not exists public.fortuna_giocate (
  id          uuid primary key default gen_random_uuid(),
  segreto     text unique not null,          -- sta nel telefono di chi ha giocato
  dispositivo text not null default '',
  sera        date not null,
  premio      text not null references public.fortuna_premi(id),
  emoji       text not null,                 -- copia del premio com'era quando è uscito
  nome        jsonb not null,
  descr       jsonb not null,
  persone     int  not null,
  creato      timestamptz not null default now(),
  iscritto    uuid references public.club_iscritti(id) on delete set null,
  codice      text                           -- il premio del Club, quando è riscattato
);
create index if not exists fortuna_giocate_disp     on public.fortuna_giocate (dispositivo, sera);
create index if not exists fortuna_giocate_iscritto on public.fortuna_giocate (iscritto, sera);
create index if not exists fortuna_giocate_sera     on public.fortuna_giocate (sera);

alter table public.fortuna_premi   enable row level security;
alter table public.fortuna_giocate enable row level security;

-- i premi del Club ora possono essere anche della Fortuna
do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.club_premi'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%tipo%'
  loop
    execute format('alter table public.club_premi drop constraint %I', c);
  end loop;
end $$;
alter table public.club_premi add constraint club_premi_tipo_check
  check (tipo in ('benvenuto', 'compleanno', 'promo', 'fortuna'));


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- la sera in cui si gioca adesso, oppure perché stasera non si gioca
create or replace function public.fortuna_sera() returns date
language plpgsql stable set search_path = public as $$
declare s date := public.pr_sera(now()); imp public.club_impostazioni;
begin
  select * into imp from public.club_impostazioni where id = 1;
  if extract(dow from s)::int = any(coalesce(imp.giorni_no, '{}') || coalesce(imp.giorni_chiusura, '{}')) then
    raise exception 'Stasera la fortuna riposa' using hint = 'riposo';
  end if;
  if now() >= public.pr_scadenza(s, public.club_chiusura()) then
    raise exception 'Per stasera il gioco è finito' using hint = 'chiuso';
  end if;
  return s;
end $$;

create or replace function public.fortuna_vista(g public.fortuna_giocate) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('segreto', g.segreto, 'sera', g.sera, 'premio', g.premio, 'emoji', g.emoji,
                            'nome', g.nome, 'descr', g.descr, 'persone', g.persone, 'codice', g.codice,
                            'scade', public.pr_scadenza(g.sera, public.club_chiusura()),
                            'chiusura', public.club_chiusura())
$$;

revoke execute on function public.fortuna_sera()                         from public, anon, authenticated;
revoke execute on function public.fortuna_vista(public.fortuna_giocate)  from public, anon, authenticated;


-- ================= CLIENTE (fortuna.html e Club del menu) =================

-- gioca: chi ha già giocato stasera (stesso telefono o stesso socio) ritrova il suo premio
create or replace function public.fortuna_gioca(p_dispositivo text, p_segreto text, p_chiave text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  s    date := public.fortuna_sera();
  disp text := left(coalesce(p_dispositivo, ''), 64);
  g    public.fortuna_giocate;
  i    public.club_iscritti;
  pr   public.fortuna_premi;
begin
  if coalesce(p_segreto, '') <> '' then
    select * into g from public.fortuna_giocate where segreto = p_segreto and sera = s;
  end if;
  if g.id is null and disp <> '' then
    select * into g from public.fortuna_giocate where dispositivo = disp and sera = s order by creato limit 1;
  end if;
  if g.id is null and coalesce(p_chiave, '') <> '' then
    select * into i from public.club_iscritti where chiave = p_chiave;
    if i.id is not null then
      select * into g from public.fortuna_giocate where iscritto = i.id and sera = s order by creato limit 1;
    end if;
  end if;
  if g.id is not null then return public.fortuna_vista(g) || jsonb_build_object('nuovo', false); end if;

  if (select count(*) from public.fortuna_giocate where sera = s) >= 1000 then
    raise exception 'Troppe giocate stasera: riprova più tardi' using hint = 'troppe';
  end if;
  -- estrazione pesata: ogni premio esce in proporzione al suo peso
  select * into pr from public.fortuna_premi where attivo and peso > 0
   order by power(random(), 1.0 / peso) desc limit 1;
  if pr.id is null then raise exception 'Nessun premio in palio' using hint = 'premi'; end if;
  insert into public.fortuna_giocate (segreto, dispositivo, sera, premio, emoji, nome, descr, persone)
  values (public.pr_casuale(24), disp, s, pr.id, pr.emoji, pr.nome, pr.descr, pr.persone)
  returning * into g;
  return public.fortuna_vista(g) || jsonb_build_object('nuovo', true);
end $$;

-- riscatta: il premio va nella tessera del socio (vale solo la sera in cui è uscito)
create or replace function public.fortuna_riscatta(p_segreto text, p_chiave text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare g public.fortuna_giocate; i public.club_iscritti; p public.club_premi; c text;
begin
  select * into g from public.fortuna_giocate where segreto = p_segreto and coalesce(p_segreto, '') <> '' for update;
  if g.id is null then raise exception 'Giocata non trovata' using hint = 'nonc'; end if;
  select * into i from public.club_iscritti where chiave = p_chiave and coalesce(p_chiave, '') <> '';
  if i.id is null then raise exception 'Tessera del Club non valida' using hint = 'chiave'; end if;
  if g.codice is not null then
    if g.iscritto = i.id then
      select * into p from public.club_premi where codice = g.codice;
      return public.fortuna_vista(g) || jsonb_build_object('premio', public.club_vista_premio(p));
    end if;
    raise exception 'Questo premio è già stato riscattato' using hint = 'preso';
  end if;
  if g.sera <> public.pr_sera(now()) or now() >= public.pr_scadenza(g.sera, public.club_chiusura()) then
    raise exception 'Il premio valeva solo quella sera' using hint = 'scaduto';
  end if;
  if exists (select 1 from public.club_premi where iscritto = i.id and tipo = 'fortuna' and dal = g.sera) then
    raise exception 'Stasera hai già riscattato un premio della Fortuna' using hint = 'gia';
  end if;
  loop
    c := public.pr_casuale(7);
    exit when not exists (select 1 from public.club_premi where codice = c);
  end loop;
  insert into public.club_premi (codice, iscritto, tipo, emoji, nome, persone, dal, al, giorni_no)
  values (c, i.id, 'fortuna', g.emoji, g.nome, g.persone, g.sera, g.sera, '{}')
  returning * into p;
  update public.fortuna_giocate set iscritto = i.id, codice = c where id = g.id returning * into g;
  return public.fortuna_vista(g) || jsonb_build_object('premio', public.club_vista_premio(p));
end $$;

grant execute on function
  public.fortuna_gioca(text, text, text), public.fortuna_riscatta(text, text)
to anon, authenticated;
