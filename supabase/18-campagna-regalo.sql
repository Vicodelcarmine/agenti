-- =============================================================================
-- CAMPAGNA "REGALO A SORPRESA" — si esegue DOPO 17-whatsapp-dialogo.sql
-- Ai clienti di una lista (es. TheFork, con il consenso alle comunicazioni) arriva un link
-- personale: vicodelcarmine.it/regalo/?c=CODICE (email con Brevo, poi WhatsApp).
-- · Dal link il cliente entra nel Club (nome, telefono ed email già scritti) e scopre un
--   premio a sorpresa: pesi e limiti in camp_premi (i premi "a numero chiuso" non sforano).
-- · Il premio è un premio del Club (tipo 'regalo', con il QR nella tessera) che vale solo
--   con una prenotazione dal sito (club_premi.solo_prenotati), per N sere da quando lo
--   scopre: il sabato e la chiusura non valgono e non si contano (club_piu_sere).
-- · Chi entra nel Club dalla campagna ha un regalo solo: questo prende il posto del
--   benvenuto del Club (camp_campagne.sostituisce_benvenuto).
-- · Allo staff il regalo compare nella prenotazione e nell'avviso; dal QR si usa come gli
--   altri premi del Club, ma senza prenotazione dal sito per quella sera chiede conferma.
-- I contatti si caricano dal Table Editor di Supabase (CSV preparato sul Mac).
-- Si può rieseguire: non cancella niente.
-- =============================================================================

-- ---------- tabelle ----------
create table if not exists public.camp_campagne (
  id           text primary key,
  nome         text not null,
  attiva       boolean not null default true,
  sere         int  not null default 14 check (sere between 1 and 90),  -- per quante sere vale il premio
  scopri_entro date,                                                    -- dopo questa sera il link non dà più premi
  sostituisce_benvenuto boolean not null default true,
  creato       timestamptz not null default now()
);

create table if not exists public.camp_premi (
  campagna text not null references public.camp_campagne(id) on delete cascade,
  id       text not null,
  emoji    text not null,
  nome     jsonb not null,                   -- {it, en}
  descr    jsonb not null,
  persone  int  not null default 0,          -- 0 = sul conto (gli sconti)
  peso     int  not null check (peso >= 0),  -- più alto = esce più spesso
  limite   int  check (limite is null or limite >= 0),   -- quanti in tutto; null = senza limite
  attivo   boolean not null default true,
  ordine   int  not null default 0,
  primary key (campagna, id)
);

create table if not exists public.camp_contatti (
  id            uuid primary key default gen_random_uuid(),
  campagna      text not null references public.camp_campagne(id) on delete cascade,
  codice        text unique not null,        -- nel link personale (10 caratteri)
  nome          text not null default '',
  telefono      text,                        -- col prefisso, come club_telefono()
  email         text,
  aperto        timestamptz,                 -- la prima volta che ha aperto il link
  aperture      int  not null default 0,
  premio        text,                        -- camp_premi.id uscito
  premio_quando timestamptz,
  iscritto      uuid references public.club_iscritti(id) on delete set null,
  club_codice   text,                        -- il premio nella tessera del Club
  disiscritto   timestamptz,                 -- si è tolto dalle email: niente WhatsApp
  wa_quando     timestamptz,                 -- quando gli è partito il WhatsApp della campagna
  creato        timestamptz not null default now()
);
create index if not exists camp_contatti_campagna on public.camp_contatti (campagna, premio);
create index if not exists camp_contatti_iscritto on public.camp_contatti (iscritto);

alter table public.camp_campagne enable row level security;
alter table public.camp_premi    enable row level security;
alter table public.camp_contatti enable row level security;

-- i premi del Club possono essere anche della campagna, e valere solo con una prenotazione dal sito
alter table public.club_premi add column if not exists solo_prenotati boolean not null default false;
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
  check (tipo in ('benvenuto', 'compleanno', 'promo', 'fortuna', 'regalo'));


-- ---------- la prima campagna: clienti TheFork (scelte del titolare, 25/10/2026) ----------
insert into public.camp_campagne (id, nome, sere, scopri_entro)
values ('regalo-thefork', 'Regalo a sorpresa · clienti TheFork', 14, date '2026-11-30')
on conflict (id) do nothing;

insert into public.camp_premi (campagna, id, emoji, nome, descr, persone, peso, limite, ordine) values
  ('regalo-thefork', 'CINQUANTA', '🎉', '{"it":"50% di sconto sul conto","en":"50% off your bill"}',
   '{"it":"Metà conto lo offriamo noi: 50% di sconto sul conto del tavolo, fino a 4 persone.","en":"Half the bill is on us: 50% off your table''s bill, up to 4 people."}', 0, 8, 15, 1),
  ('regalo-thefork', 'TRENTA', '🔥', '{"it":"30% di sconto sul conto","en":"30% off your bill"}',
   '{"it":"30% di sconto sul conto del tavolo, fino a 4 persone.","en":"30% off your table''s bill, up to 4 people."}', 0, 15, 30, 2),
  ('regalo-thefork', 'VENTI', '⭐', '{"it":"20% di sconto sul conto","en":"20% off your bill"}',
   '{"it":"20% di sconto sul conto del tavolo, fino a 4 persone.","en":"20% off your table''s bill, up to 4 people."}', 0, 25, null, 3),
  ('regalo-thefork', 'DIECI', '🍕', '{"it":"10% di sconto sul conto","en":"10% off your bill"}',
   '{"it":"10% di sconto sul conto del tavolo, fino a 4 persone.","en":"10% off your table''s bill, up to 4 people."}', 0, 12, null, 4),
  ('regalo-thefork', 'PROSECCO', '🥂', '{"it":"Prosecco di benvenuto per il tavolo","en":"Welcome prosecco for your table"}',
   '{"it":"Un calice di prosecco di benvenuto a testa, fino a 4 persone.","en":"A welcome glass of prosecco each, up to 4 people."}', 4, 15, null, 5),
  ('regalo-thefork', 'DOLCE', '🍰', '{"it":"Dolce della casa offerto","en":"Homemade dessert on us"}',
   '{"it":"Un dolce della casa a testa, per 2 persone.","en":"A homemade dessert each, for 2 people."}', 2, 15, null, 6),
  ('regalo-thefork', 'SPRITZ', '🍹', '{"it":"Spritz offerto","en":"Spritz on us"}',
   '{"it":"Uno Spritz Aperol o Hugo a testa, per 2 persone.","en":"An Aperol or Hugo Spritz each, for 2 people."}', 2, 10, null, 7)
on conflict (campagna, id) do nothing;


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- il premio della campagna come lo vede il cliente (null finché non l'ha scoperto)
create or replace function public.camp_vista_premio(c public.camp_contatti) returns jsonb
language sql stable set search_path = public as $$
  select public.club_vista_premio(p) || jsonb_build_object('descr', cp.descr, 'soloPrenotati', p.solo_prenotati)
    from public.club_premi p
    left join public.camp_premi cp on cp.campagna = c.campagna and cp.id = c.premio
   where c.club_codice is not null and p.codice = c.club_codice
$$;

-- stasera il socio del premio ha una prenotazione fatta dal sito?
create or replace function public.camp_prenotato(p public.club_premi) returns boolean
language sql stable set search_path = public as $$
  select exists (
    select 1 from public.pren_prenotazioni x
     where x.fonte = 'sito' and x.stato in ('confermata', 'arrivati') and x.sera = public.pr_sera(now())
       and (x.iscritto = p.iscritto or x.telefono = (select telefono from public.club_iscritti where id = p.iscritto)))
$$;

revoke execute on function public.camp_vista_premio(public.camp_contatti) from public, anon, authenticated;
revoke execute on function public.camp_prenotato(public.club_premi)       from public, anon, authenticated;


-- ================= CLIENTE (pagina vicodelcarmine.it/regalo) =================

-- apre il link: chi è (per scrivere già nome, telefono ed email), i premi in palio, il suo premio se l'ha già scoperto
create or replace function public.camp_vista(p_codice text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare c public.camp_contatti; k public.camp_campagne;
begin
  update public.camp_contatti set aperto = coalesce(aperto, now()), aperture = aperture + 1
   where codice = upper(trim(coalesce(p_codice, ''))) returning * into c;
  if c.id is null then raise exception 'Questo link non è valido' using hint = 'codice'; end if;
  select * into k from public.camp_campagne where id = c.campagna;
  return jsonb_build_object(
    'nome', c.nome, 'telefono', c.telefono, 'email', c.email,
    'socio', exists (select 1 from public.club_iscritti i
                      where i.telefono = c.telefono or (c.email is not null and lower(i.email) = lower(c.email))),
    'aperta', k.attiva and (k.scopri_entro is null or public.pr_sera(now()) <= k.scopri_entro),
    'sere', k.sere, 'scopriEntro', k.scopri_entro,
    'giorniNo', (select to_jsonb(giorni_no || giorni_chiusura) from public.club_impostazioni where id = 1),
    'premi', (select jsonb_agg(jsonb_build_object('emoji', p.emoji, 'nome', p.nome) order by p.ordine)
                from public.camp_premi p where p.campagna = c.campagna and p.attivo and p.peso > 0),
    'premio', public.camp_vista_premio(c));
end $$;

-- scopre il premio: serve essere nel Club (la tessera di questo telefono, oppure il numero o l'email del link)
create or replace function public.camp_scopri(p_codice text, p_chiave text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  c   public.camp_contatti;
  k   public.camp_campagne;
  i   public.club_iscritti;
  imp public.club_impostazioni;
  pr  public.camp_premi;
  g   int[];
  d1  date;
  d2  date;
  cod text;
begin
  select * into c from public.camp_contatti where codice = upper(trim(coalesce(p_codice, ''))) for update;
  if c.id is null then raise exception 'Questo link non è valido' using hint = 'codice'; end if;
  -- l'ha già scoperto: ritrova lo stesso
  if c.club_codice is not null and exists (select 1 from public.club_premi where codice = c.club_codice) then
    return jsonb_build_object('nome', c.nome, 'premio', public.camp_vista_premio(c), 'nuovo', false);
  end if;
  select * into k from public.camp_campagne where id = c.campagna;
  if not k.attiva or (k.scopri_entro is not null and public.pr_sera(now()) > k.scopri_entro) then
    raise exception 'La campagna è finita' using hint = 'finita';
  end if;
  if coalesce(p_chiave, '') <> '' then
    select * into i from public.club_iscritti where chiave = p_chiave;
  end if;
  if i.id is null then
    select * into i from public.club_iscritti
     where telefono = c.telefono or (c.email is not null and lower(email) = lower(c.email))
     order by creato limit 1;
  end if;
  if i.id is null then raise exception 'Prima entra nel Club' using hint = 'club'; end if;
  if exists (select 1 from public.camp_contatti x
              where x.campagna = c.campagna and x.iscritto = i.id and x.id <> c.id and x.club_codice is not null) then
    raise exception 'Hai già scoperto il tuo regalo' using hint = 'gia';
  end if;

  -- un'estrazione alla volta per campagna: i premi a numero chiuso non sforano
  perform pg_advisory_xact_lock(hashtext('camp:' || c.campagna));
  select * into pr from public.camp_premi p
   where p.campagna = c.campagna and p.attivo and p.peso > 0
     and (p.limite is null
          or (select count(*) from public.camp_contatti x where x.campagna = p.campagna and x.premio = p.id) < p.limite)
   order by power(random(), 1.0 / p.peso) desc limit 1;
  if pr.id is null then raise exception 'I regali sono finiti' using hint = 'finiti'; end if;

  -- vale da stasera (o dalla prima sera buona) per k.sere sere: sabato e chiusura non contano
  select * into imp from public.club_impostazioni where id = 1;
  g  := imp.giorni_no || imp.giorni_chiusura;
  d1 := public.club_piu_sere(public.pr_sera(now()), 1, g);
  d2 := public.club_piu_sere(d1, k.sere, g);
  loop
    cod := public.pr_casuale(7);
    exit when not exists (select 1 from public.club_premi where codice = cod);
  end loop;
  insert into public.club_premi (codice, iscritto, tipo, emoji, nome, persone, dal, al, giorni_no, solo_prenotati)
  values (cod, i.id, 'regalo', pr.emoji, pr.nome, pr.persone, d1, d2, g, true);
  -- entrato nel Club dalla campagna (nell'ultima ora): un regalo solo, questo al posto del benvenuto
  if k.sostituisce_benvenuto and i.creato > now() - interval '1 hour' then
    delete from public.club_premi where iscritto = i.id and tipo = 'benvenuto' and usato is null;
  end if;
  update public.camp_contatti set premio = pr.id, premio_quando = now(), iscritto = i.id, club_codice = cod
   where id = c.id returning * into c;
  return jsonb_build_object('nome', c.nome, 'premio', public.camp_vista_premio(c), 'nuovo', true);
end $$;

grant execute on function public.camp_vista(text), public.camp_scopri(text, text) to anon, authenticated;


-- ================= STAFF E TITOLARE =================

-- il premio inquadrato col QR: in più se vale solo con prenotazione e se stasera c'è
create or replace function public.club_leggi_premio(p_pin text, p_codice text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare p public.club_premi; i public.club_iscritti;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into p from public.club_premi where codice = upper(p_codice);
  if not found then raise exception 'Nessun premio del Club con questo codice' using hint = 'premio'; end if;
  select * into i from public.club_iscritti where id = p.iscritto;
  return public.club_vista_premio(p) || jsonb_build_object(
    'iscritto', jsonb_build_object('id', i.id, 'nome', i.nome, 'telefono', i.telefono, 'nascita', i.nascita),
    'annullabile', p.usato is not null and p.sera_uso = public.pr_sera(now()),
    'soloPrenotati', p.solo_prenotati, 'prenotato', public.camp_prenotato(p));
end $$;

-- il titolare usa il premio. p_forza = darlo lo stesso anche se stasera non varrebbe (mai se è già usato)
create or replace function public.club_usa(p_pin text, p_codice text, p_forza boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare p public.club_premi; st text;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into p from public.club_premi where codice = upper(p_codice) for update;
  if not found then raise exception 'Nessun premio del Club con questo codice' using hint = 'premio'; end if;
  st := public.club_stato(p);
  if st = 'usato' then raise exception 'Premio già usato' using hint = 'usato'; end if;
  if st <> 'valido' and not coalesce(p_forza, false) then
    raise exception 'Stasera questo premio non vale' using hint = st;
  end if;
  if p.solo_prenotati and not public.camp_prenotato(p) and not coalesce(p_forza, false) then
    raise exception 'Questo regalo vale solo con una prenotazione dal sito per stasera' using hint = 'prenota';
  end if;
  update public.club_premi set usato = clock_timestamp(), sera_uso = public.pr_sera(now()) where codice = p.codice;
  return public.club_leggi_premio(p_pin, p.codice);
end $$;

-- la prenotazione nella dashboard: in più il regalo della campagna che vale quella sera
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
                     order by r.creato limit 1))
$$;
revoke execute on function public.pren_vista_titolare(public.pren_prenotazioni) from public, anon, authenticated;

-- l'avviso al titolare dice anche il regalo della campagna
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
               case when a.tipo = 'nuova' then coalesce((
                 select ' · ' || r.emoji || ' regalo: ' || (r.nome->>'it')
                   from public.club_premi r
                  where p.iscritto is not null and p.fonte = 'sito' and r.iscritto = p.iscritto and r.tipo = 'regalo'
                    and r.usato is null and p.sera between r.dal and r.al
                  order by r.creato limit 1), '') else '' end ||
               case when p.nota <> '' and a.tipo = 'nuova' then ' · «' || left(p.nota, 60) || '»' else '' end))
      order by a.id) filter (where a.id is not null), '[]'::jsonb),
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', x.endpoint, 'sub', x.sub)) from public.pren_push x), '[]'::jsonb))
    from presi a left join public.pren_prenotazioni p on p.id = a.prenotazione
$$;
revoke execute on function public.pren_prendi_avvisi(int) from public, anon, authenticated;
grant execute on function public.pren_prendi_avvisi(int) to service_role;

-- come sta andando la campagna
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
                  from public.camp_premi p where p.campagna = k.id))
      order by k.creato desc)
      from public.camp_campagne k), '[]'::jsonb);
end $$;

grant execute on function public.camp_panoramica(text) to anon, authenticated;
