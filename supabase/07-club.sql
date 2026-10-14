-- =============================================================================
-- CLUB DEL VICO — fase 1: iscritti e premio di benvenuto
-- Tutto ha il prefisso club_ : NON tocca menu, ordini né agenti. Usa solo le
-- funzioni di servizio degli agenti (pr_sera, pr_scadenza, pr_casuale,
-- pr_controlla_pin) e il loro orario di chiusura.
-- Le tabelle non sono leggibili dall'esterno (RLS senza regole): si passa solo
-- dalle funzioni qui sotto, che controllano la chiave del cliente o il PIN del titolare.
-- Si può rieseguire: non cancella niente.
-- =============================================================================

-- ---------- tabelle ----------
create table if not exists public.club_impostazioni (
  id              int primary key default 1 check (id = 1),
  premio_emoji    text  not null default '🍹',
  premio_nome     jsonb not null default '{"it":"Spritz o dolce offerto","en":"Free spritz or dessert"}',
  premio_persone  int   not null default 2  check (premio_persone between 1 and 20),
  premio_sere     int   not null default 14 check (premio_sere between 1 and 90),
  -- sere della settimana (0 = domenica … 6 = sabato) in cui i premi non valgono e non si contano
  giorni_no       int[] not null default '{6}',
  -- giorno di chiusura settimanale: non si conta mai
  giorni_chiusura int[] not null default '{}'
);
insert into public.club_impostazioni (id) values (1) on conflict (id) do nothing;

create table if not exists public.club_iscritti (
  id           uuid primary key default gen_random_uuid(),
  chiave       text unique not null,          -- segreto: sta solo sul telefono del cliente
  nome         text not null,
  email        text not null,
  telefono     text not null,                 -- sempre col prefisso, es. +393331234567
  nascita      date not null,
  promo        boolean not null default false, -- consenso a ricevere offerte
  promo_quando timestamptz,                    -- quando l'ha dato o tolto
  lingua       text not null default 'it',
  dispositivo  text not null default '',
  creato       timestamptz not null default now()
);
create unique index if not exists club_iscritti_email on public.club_iscritti (lower(email));
create unique index if not exists club_iscritti_tel   on public.club_iscritti (telefono);
create index if not exists club_iscritti_disp         on public.club_iscritti (dispositivo, creato);

create table if not exists public.club_premi (
  codice    text primary key,                 -- 7 caratteri (i buoni degli agenti ne hanno 6)
  iscritto  uuid not null references public.club_iscritti(id) on delete cascade,
  tipo      text not null default 'benvenuto' check (tipo in ('benvenuto', 'compleanno', 'promo')),
  emoji     text not null,
  nome      jsonb not null,                   -- copia del premio com'era quando è uscito
  persone   int  not null,
  dal       date not null,                    -- prima sera in cui vale
  al        date not null,                    -- ultima sera in cui vale (fino alla chiusura)
  giorni_no int[] not null default '{}',      -- sere della settimana in cui non vale (copia di quando è uscito)
  creato    timestamptz not null default now(),
  usato     timestamptz,
  sera_uso  date
);
create index if not exists club_premi_iscritto on public.club_premi (iscritto);
create index if not exists club_premi_uso      on public.club_premi (sera_uso);

alter table public.club_impostazioni enable row level security;
alter table public.club_iscritti     enable row level security;
alter table public.club_premi        enable row level security;


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- orario di chiusura: lo stesso degli agenti
create or replace function public.club_chiusura() returns text
language sql stable set search_path = public as $$
  select coalesce((select chiusura from public.pr_impostazioni where id = 1), '23:30')
$$;

-- la n-esima sera a partire da s compresa, SALTANDO i giorni esclusi (il sabato non si conta mai)
create or replace function public.club_piu_sere(s date, n int, g int[]) returns date
language plpgsql immutable set search_path = public as $$
declare d date := s; contate int := 0;
begin
  if n < 1 then return s; end if;
  for i in 1 .. n * 7 + 7 loop
    if not (extract(dow from d)::int = any(coalesce(g, '{}'))) then
      contate := contate + 1;
      if contate = n then return d; end if;
    end if;
    d := d + 1;
  end loop;
  return s + n - 1;   -- tutti i giorni esclusi: conto normale
end $$;

-- "+39 333 123 4567", "0039…", "3331234567" → "+393331234567" (null se non è un numero)
create or replace function public.club_telefono(p text) returns text
language plpgsql immutable set search_path = public as $$
declare t text := regexp_replace(coalesce(p, ''), '[^0-9+]', '', 'g');
begin
  if t like '00%' then t := '+' || substr(t, 3); end if;
  t := case when left(t, 1) = '+' then '+' || replace(substr(t, 2), '+', '') else '+39' || replace(t, '+', '') end;
  if length(t) - 1 < 8 or length(t) - 1 > 15 then return null; end if;
  return t;
end $$;

-- il prossimo compleanno a partire dalla sera s (chi è nato il 29 febbraio lo festeggia il 28)
create or replace function public.club_prossimo_compleanno(n date, s date) returns date
language plpgsql immutable set search_path = public as $$
declare y int := extract(year from s)::int; d date;
begin
  for k in 0 .. 1 loop
    begin
      d := make_date(y + k, extract(month from n)::int, extract(day from n)::int);
    exception when others then
      d := make_date(y + k, 2, 28);
    end;
    if d >= s then return d; end if;
  end loop;
  return d;
end $$;

-- a che punto è un premio, adesso
create or replace function public.club_stato(p public.club_premi) returns text
language sql stable set search_path = public as $$
  select case
    when p.usato is not null then 'usato'
    when now() >= public.pr_scadenza(p.al, public.club_chiusura()) then 'scaduto'
    when public.pr_sera(now()) < p.dal then 'presto'
    when extract(dow from public.pr_sera(now()))::int = any(p.giorni_no) then 'oggi_no'
    else 'valido' end
$$;

create or replace function public.club_vista_premio(p public.club_premi) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'codice', p.codice, 'tipo', p.tipo, 'emoji', p.emoji, 'nome', p.nome, 'persone', p.persone,
    'dal', p.dal, 'al', p.al, 'scade', public.pr_scadenza(p.al, public.club_chiusura()),
    'giorniNo', to_jsonb(p.giorni_no), 'creato', p.creato, 'usato', p.usato,
    'stato', public.club_stato(p))
$$;

-- l'iscritto come lo vede lui: i suoi dati e i suoi premi (quelli usati restano visibili 60 giorni)
create or replace function public.club_vista_iscritto(i public.club_iscritti) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'nome', i.nome, 'email', i.email, 'telefono', i.telefono, 'nascita', i.nascita,
    'promo', i.promo, 'creato', i.creato,
    'premi', coalesce((
      select jsonb_agg(public.club_vista_premio(p) order by (p.usato is not null), p.dal, p.creato)
        from public.club_premi p
       where p.iscritto = i.id and (p.usato is null or p.usato > now() - interval '60 days')), '[]'::jsonb))
$$;

-- il premio di benvenuto: vale dalla sera DOPO l'iscrizione, per N sere (sabato e chiusura non contano)
create or replace function public.club_dai_benvenuto(p_iscritto uuid) returns public.club_premi
language plpgsql volatile set search_path = public as $$
declare imp public.club_impostazioni; g int[]; d1 date; d2 date; c text; p public.club_premi;
begin
  select * into imp from public.club_impostazioni where id = 1;
  g := imp.giorni_no || imp.giorni_chiusura;
  d1 := public.club_piu_sere(public.pr_sera(now()) + 1, 1, g);
  d2 := public.club_piu_sere(d1, imp.premio_sere, g);
  loop
    c := public.pr_casuale(7);
    exit when not exists (select 1 from public.club_premi where codice = c);
  end loop;
  insert into public.club_premi (codice, iscritto, tipo, emoji, nome, persone, dal, al, giorni_no)
  values (c, p_iscritto, 'benvenuto', imp.premio_emoji, imp.premio_nome, imp.premio_persone, d1, d2, g)
  returning * into p;
  return p;
end $$;

revoke execute on function public.club_chiusura()                          from public, anon, authenticated;
revoke execute on function public.club_piu_sere(date, int, int[])         from public, anon, authenticated;
revoke execute on function public.club_telefono(text)                      from public, anon, authenticated;
revoke execute on function public.club_prossimo_compleanno(date, date)     from public, anon, authenticated;
revoke execute on function public.club_stato(public.club_premi)            from public, anon, authenticated;
revoke execute on function public.club_vista_premio(public.club_premi)     from public, anon, authenticated;
revoke execute on function public.club_vista_iscritto(public.club_iscritti) from public, anon, authenticated;
revoke execute on function public.club_dai_benvenuto(uuid)                 from public, anon, authenticated;


-- ================= CLIENTE (dentro il menu) =================

-- il premio di benvenuto di adesso, per l'invito a iscriversi (dati pubblici)
create or replace function public.club_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('emoji', premio_emoji, 'nome', premio_nome, 'persone', premio_persone,
                            'sere', premio_sere, 'giorniNo', to_jsonb(giorni_no || giorni_chiusura))
    from public.club_impostazioni where id = 1
$$;

-- iscrizione: crea l'iscritto e il suo premio di benvenuto. Torna la chiave da tenere sul telefono.
create or replace function public.club_iscriviti(p_nome text, p_email text, p_telefono text, p_nascita text,
                                                 p_promo boolean, p_lingua text, p_dispositivo text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  n    text := left(trim(coalesce(p_nome, '')), 60);
  e    text := lower(trim(coalesce(p_email, '')));
  t    text := public.club_telefono(p_telefono);
  disp text := left(coalesce(p_dispositivo, ''), 64);
  d    date;
  i    public.club_iscritti;
begin
  if length(n) < 2 then raise exception 'Scrivi il tuo nome' using hint = 'nome'; end if;
  if length(e) > 120 or e !~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$' then
    raise exception 'Email non valida' using hint = 'email';
  end if;
  if t is null then raise exception 'Numero di telefono non valido' using hint = 'telefono'; end if;
  begin
    d := p_nascita::date;
  exception when others then
    d := null;
  end;
  if d is null or d > (current_date - interval '14 years')::date or d < (current_date - interval '110 years')::date then
    raise exception 'Data di nascita non valida' using hint = 'nascita';
  end if;
  if (disp <> '' and (select count(*) from public.club_iscritti
                       where dispositivo = disp and creato > now() - interval '1 day') >= 3)
     or (select count(*) from public.club_iscritti where creato > now() - interval '1 day') >= 300 then
    raise exception 'Troppe iscrizioni: riprova domani' using hint = 'troppe';
  end if;
  if exists (select 1 from public.club_iscritti where lower(email) = e or telefono = t) then
    raise exception 'Questa email o questo numero sono già nel Club' using hint = 'gia';
  end if;
  insert into public.club_iscritti (chiave, nome, email, telefono, nascita, promo, promo_quando, lingua, dispositivo)
  values (public.pr_casuale(24), n, e, t, d, coalesce(p_promo, false), case when p_promo then now() end,
          left(coalesce(nullif(trim(p_lingua), ''), 'it'), 5), disp)
  returning * into i;
  perform public.club_dai_benvenuto(i.id);
  return jsonb_build_object('chiave', i.chiave) || public.club_vista_iscritto(i);
exception when unique_violation then
  raise exception 'Questa email o questo numero sono già nel Club' using hint = 'gia';
end $$;

create or replace function public.club_profilo(p_chiave text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  select * into i from public.club_iscritti where chiave = p_chiave;
  if not found then raise exception 'Tessera non trovata' using hint = 'chiave'; end if;
  return public.club_vista_iscritto(i);
end $$;

-- il cliente accende o spegne le offerte
create or replace function public.club_promo(p_chiave text, p_promo boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  update public.club_iscritti set promo = coalesce(p_promo, false), promo_quando = now()
   where chiave = p_chiave returning * into i;
  if not found then raise exception 'Tessera non trovata' using hint = 'chiave'; end if;
  return public.club_vista_iscritto(i);
end $$;

-- il cliente esce dal Club: i suoi dati e i suoi premi si cancellano subito
create or replace function public.club_cancellami(p_chiave text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  delete from public.club_iscritti where chiave = p_chiave;
  if not found then raise exception 'Tessera non trovata' using hint = 'chiave'; end if;
  return true;
end $$;


-- ================= TITOLARE (dashboard) =================

create or replace function public.club_panoramica(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s date := public.pr_sera(now());
begin
  perform public.pr_controlla_pin(p_pin);
  return jsonb_build_object(
    'iscritti', (select count(*) from public.club_iscritti),
    'nuovi',    (select count(*) from public.club_iscritti where creato > now() - interval '7 days'),
    'promo',    (select count(*) from public.club_iscritti where promo),
    'attivi',   (select count(*) from public.club_premi p where public.club_stato(p) in ('valido', 'presto', 'oggi_no')),
    'usatiMese', (select count(*) from public.club_premi
                   where sera_uso is not null and date_trunc('month', sera_uso) = date_trunc('month', s)),
    'stasera', coalesce((
      select jsonb_agg(jsonb_build_object('codice', p.codice, 'nome', i.nome, 'emoji', p.emoji, 'premio', p.nome,
                                          'persone', p.persone, 'tipo', p.tipo, 'quando', p.usato) order by p.usato desc)
        from public.club_premi p join public.club_iscritti i on i.id = p.iscritto
       where p.sera_uso = s), '[]'::jsonb),
    'compleanni', coalesce((
      select jsonb_agg(jsonb_build_object('id', x.id, 'nome', x.nome, 'telefono', x.telefono,
                                          'nascita', x.nascita, 'giorno', x.prossimo) order by x.prossimo, x.nome)
        from (select i.id, i.nome, i.telefono, i.nascita, public.club_prossimo_compleanno(i.nascita, s) as prossimo
                from public.club_iscritti i) x
       where x.prossimo <= s + 7), '[]'::jsonb));
end $$;

-- elenco degli iscritti (i più recenti per primi), con ricerca per nome, email o telefono
create or replace function public.club_elenco(p_pin text, p_cerca text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text := trim(coalesce(p_cerca, '')); cifre text := regexp_replace(coalesce(p_cerca, ''), '\D', '', 'g');
begin
  perform public.pr_controlla_pin(p_pin);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', i.id, 'nome', i.nome, 'telefono', i.telefono, 'email', i.email, 'nascita', i.nascita,
             'creato', i.creato, 'promo', i.promo,
             'premi', (select count(*) from public.club_premi p
                        where p.iscritto = i.id and public.club_stato(p) in ('valido', 'presto', 'oggi_no')))
           order by i.creato desc)
      from (select * from public.club_iscritti c
             where q = '' or c.nome ilike '%' || q || '%' or c.email ilike '%' || q || '%'
                or (length(cifre) >= 3 and c.telefono like '%' || cifre || '%')
             order by c.creato desc limit 300) i), '[]'::jsonb);
end $$;

create or replace function public.club_dettaglio(p_pin text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into i from public.club_iscritti where id = p_id;
  if not found then raise exception 'Iscritto non trovato' using hint = 'iscritto'; end if;
  return jsonb_build_object('id', i.id, 'chiave', i.chiave, 'nome', i.nome, 'email', i.email,
           'telefono', i.telefono, 'nascita', i.nascita, 'promo', i.promo, 'promoQuando', i.promo_quando,
           'lingua', i.lingua, 'creato', i.creato,
           'premi', coalesce((select jsonb_agg(public.club_vista_premio(p) order by p.creato desc)
                                from public.club_premi p where p.iscritto = i.id), '[]'::jsonb));
end $$;

-- il premio inquadrato col QR (o scritto a mano)
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
    'annullabile', p.usato is not null and p.sera_uso = public.pr_sera(now()));
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
  update public.club_premi set usato = clock_timestamp(), sera_uso = public.pr_sera(now()) where codice = p.codice;
  return public.club_leggi_premio(p_pin, p.codice);
end $$;

-- ho sbagliato: il premio torna da usare (solo la sera stessa)
create or replace function public.club_annulla(p_pin text, p_codice text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare p public.club_premi;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into p from public.club_premi where codice = upper(p_codice) for update;
  if not found or p.usato is null then raise exception 'Niente da annullare' using hint = 'premio'; end if;
  if p.sera_uso <> public.pr_sera(now()) then
    raise exception 'Si può annullare solo la sera stessa' using hint = 'tardi';
  end if;
  update public.club_premi set usato = null, sera_uso = null where codice = p.codice;
  return true;
end $$;

create or replace function public.club_impostazioni(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return (select jsonb_build_object('emoji', premio_emoji, 'nome', premio_nome, 'persone', premio_persone,
                                     'sere', premio_sere, 'giorniNo', to_jsonb(giorni_no),
                                     'giorniChiusura', to_jsonb(giorni_chiusura))
            from public.club_impostazioni where id = 1);
end $$;

-- valgono per i premi che escono da adesso in poi: quelli già dati restano come sono stati promessi
create or replace function public.club_salva_impostazioni(p_pin text, p_dati jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v text;
begin
  perform public.pr_controlla_pin(p_pin);
  if p_dati ? 'emoji' then
    update public.club_impostazioni set premio_emoji = left(coalesce(nullif(trim(p_dati->>'emoji'), ''), '🎁'), 8) where id = 1;
  end if;
  if p_dati ? 'nome' then
    if trim(coalesce(p_dati->'nome'->>'it', '')) = '' then
      raise exception 'Scrivi il nome del premio' using hint = 'nome';
    end if;
    update public.club_impostazioni
       set premio_nome = jsonb_build_object('it', left(trim(p_dati->'nome'->>'it'), 60),
                                            'en', left(trim(coalesce(p_dati->'nome'->>'en', '')), 60))
     where id = 1;
  end if;
  if p_dati ? 'persone' then
    v := trim(p_dati->>'persone');
    if coalesce(v, '') !~ '^\d{1,2}$' or v::int < 1 or v::int > 20 then
      raise exception 'Persone non valide (da 1 a 20)' using hint = 'persone';
    end if;
    update public.club_impostazioni set premio_persone = v::int where id = 1;
  end if;
  if p_dati ? 'sere' then
    v := trim(p_dati->>'sere');
    if coalesce(v, '') !~ '^\d{1,2}$' or v::int < 1 or v::int > 90 then
      raise exception 'Durata non valida (da 1 a 90 sere)' using hint = 'sere';
    end if;
    update public.club_impostazioni set premio_sere = v::int where id = 1;
  end if;
  if p_dati ? 'giorniNo' then
    if jsonb_typeof(p_dati->'giorniNo') <> 'array' then raise exception 'Giorni non validi' using hint = 'giorni'; end if;
    update public.club_impostazioni
       set giorni_no = coalesce((select array_agg(distinct g::int order by g::int)
                                   from jsonb_array_elements_text(p_dati->'giorniNo') g where g ~ '^[0-6]$'), '{}')
     where id = 1;
  end if;
  if p_dati ? 'giorniChiusura' then
    if jsonb_typeof(p_dati->'giorniChiusura') <> 'array' then raise exception 'Giorni non validi' using hint = 'giorni'; end if;
    update public.club_impostazioni
       set giorni_chiusura = coalesce((select array_agg(distinct g::int order by g::int)
                                         from jsonb_array_elements_text(p_dati->'giorniChiusura') g where g ~ '^[0-6]$'), '{}')
     where id = 1;
  end if;
  if (select cardinality(giorni_no || giorni_chiusura) from public.club_impostazioni where id = 1) >= 7 then
    raise exception 'Almeno una sera della settimana deve restare valida' using hint = 'giorni';
  end if;
  return public.club_impostazioni(p_pin);
end $$;

-- elimina un iscritto con tutti i suoi premi (es. lo chiede lui): non si torna indietro
create or replace function public.club_elimina_iscritto(p_pin text, p_id uuid) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  delete from public.club_iscritti where id = p_id;     -- club_premi se ne va da sola (on delete cascade)
  if not found then raise exception 'Iscritto non trovato' using hint = 'iscritto'; end if;
  return true;
end $$;

-- le funzioni pubbliche si chiamano con la chiave publishable del sito
grant execute on function
  public.club_info(), public.club_iscriviti(text, text, text, text, boolean, text, text), public.club_profilo(text),
  public.club_promo(text, boolean), public.club_cancellami(text),
  public.club_panoramica(text), public.club_elenco(text, text), public.club_dettaglio(text, uuid),
  public.club_leggi_premio(text, text), public.club_usa(text, text, boolean), public.club_annulla(text, text),
  public.club_impostazioni(text), public.club_salva_impostazioni(text, jsonb), public.club_elimina_iscritto(text, uuid)
to anon, authenticated;

notify pgrst, 'reload schema';
