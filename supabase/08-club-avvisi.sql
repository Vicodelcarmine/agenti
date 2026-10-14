-- =============================================================================
-- CLUB DEL VICO — fase 2: avvisi (notifiche e, quando le accendi, email),
-- regalo di compleanno e offerte "ci manchi". Si esegue DOPO 07-club.sql.
--
-- Come gira:
--   · ogni mattina club_giro() (vedi 09-club-giro.sql) crea i regali di compleanno
--     e le offerte, e mette in coda gli avvisi nella tabella club_messaggi;
--   · la funzione Supabase "club-invia" manda gli avvisi in coda (notifiche sul
--     telefono e, se accese, email) e scrive com'è andata.
-- Scelte del titolare (15/10/2026): compleanno senza anzianità minima, l'avviso
-- del compleanno solo a chi ha accettato le offerte, email spente all'inizio.
-- Si può rieseguire: non cancella niente.
-- =============================================================================

-- ---------- impostazioni nuove ----------
alter table public.club_impostazioni
  add column if not exists compleanno_per    int     not null default 2  check (compleanno_per between 1 and 5),
  add column if not exists compleanno_giorni int     not null default 3  check (compleanno_giorni between 0 and 7),
  add column if not exists offerte_attive    boolean not null default true,
  add column if not exists offerte_settimane int     not null default 3  check (offerte_settimane between 1 and 12),
  add column if not exists offerte_persone   int     not null default 2  check (offerte_persone between 1 and 20),
  add column if not exists offerte_sere      int     not null default 2  check (offerte_sere between 1 and 14),
  add column if not exists offerte_pausa     int     not null default 15 check (offerte_pausa between 7 and 90),
  add column if not exists email_attive      boolean not null default false,
  add column if not exists ultimo_giro       timestamptz,
  add column if not exists ultimo_esito      jsonb;

-- le offerte che il titolare propone, una a giro, a chi non si vede da qualche settimana
create table if not exists public.club_offerte (
  id     text primary key,
  ordine int   not null default 0,
  emoji  text  not null default '🎁',
  nome   jsonb not null default '{}',
  attivo boolean not null default true
);
insert into public.club_offerte (id, ordine, emoji, nome)
select 'DOLCE', 1, '🍰', '{"it":"Dolce offerto","en":"Free dessert"}'::jsonb
 where not exists (select 1 from public.club_offerte);

alter table public.club_iscritti
  add column if not exists email_token      text,          -- segreto dei link nelle email (conferma, stop offerte)
  add column if not exists email_confermata timestamptz,
  add column if not exists codice           text,          -- codice a 6 cifre per ritrovare la tessera via email
  add column if not exists codice_scade     timestamptz,
  add column if not exists codice_tentativi int not null default 0,
  add column if not exists ultimo_contatto  timestamptz;   -- ultima offerta o avviso di compleanno
update public.club_iscritti set email_token = public.pr_casuale(24) where email_token is null;
alter table public.club_iscritti alter column email_token set default public.pr_casuale(24);
create unique index if not exists club_iscritti_email_token on public.club_iscritti (email_token);

-- i telefoni su cui il cliente ha acceso le notifiche
create table if not exists public.club_push (
  endpoint text primary key,
  iscritto uuid not null references public.club_iscritti(id) on delete cascade,
  sub      jsonb not null,
  creato   timestamptz not null default now()
);
create index if not exists club_push_iscritto on public.club_push (iscritto);

-- la coda degli avvisi: li scrive il database, li manda la funzione club-invia
create table if not exists public.club_messaggi (
  id       uuid primary key default gen_random_uuid(),
  iscritto uuid not null references public.club_iscritti(id) on delete cascade,
  tipo     text not null check (tipo in ('benvenuto', 'compleanno', 'promo', 'codice', 'prova')),
  titolo   text not null,
  testo    text not null,
  premio   text,
  push     boolean not null default true,
  email    boolean not null default true,
  creato   timestamptz not null default now(),
  inviato  timestamptz,                       -- quando la funzione l'ha preso
  esito    jsonb                              -- {"push": 2, "email": "ok" | "spente" | "non confermata" | "errore …"}
);
create index if not exists club_messaggi_coda     on public.club_messaggi (creato) where inviato is null;
create index if not exists club_messaggi_iscritto on public.club_messaggi (iscritto, creato);

alter table public.club_offerte  enable row level security;
alter table public.club_push     enable row level security;
alter table public.club_messaggi enable row level security;


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- "mar 20 ott" / "Tue 20 Oct" (chi non ha il menu in italiano riceve tutto in inglese)
create or replace function public.club_data(d date, lingua text) returns text
language sql immutable set search_path = public as $$
  select case when lingua = 'it'
    then (array['dom','lun','mar','mer','gio','ven','sab'])[extract(dow from d)::int + 1] || ' ' ||
         extract(day from d)::int || ' ' ||
         (array['gen','feb','mar','apr','mag','giu','lug','ago','set','ott','nov','dic'])[extract(month from d)::int]
    else (array['Sun','Mon','Tue','Wed','Thu','Fri','Sat'])[extract(dow from d)::int + 1] || ' ' ||
         extract(day from d)::int || ' ' ||
         (array['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'])[extract(month from d)::int] end
$$;

create or replace function public.club_periodo(d1 date, d2 date, lingua text) returns text
language sql immutable set search_path = public as $$
  select case when d1 = d2 then public.club_data(d1, lingua)
              when lingua = 'it' then 'dal ' || public.club_data(d1, lingua) || ' al ' || public.club_data(d2, lingua)
              else 'from ' || public.club_data(d1, lingua) || ' to ' || public.club_data(d2, lingua) end
$$;

create or replace function public.club_nome(nome jsonb, lingua text) returns text
language sql immutable set search_path = public as $$
  select case when lingua = 'it' then nome->>'it' else coalesce(nullif(nome->>'en', ''), nome->>'it') end
$$;

create or replace function public.club_persone(n int, lingua text) returns text
language sql immutable set search_path = public as $$
  select n || case when lingua = 'it' then (case when n = 1 then ' persona' else ' persone' end)
                   else (case when n = 1 then ' person' else ' people' end) end
$$;

create or replace function public.club_accoda(p_iscritto uuid, p_tipo text, p_titolo text, p_testo text,
                                              p_premio text, p_push boolean, p_email boolean) returns uuid
language sql volatile set search_path = public as $$
  insert into public.club_messaggi (iscritto, tipo, titolo, testo, premio, push, email)
  values (p_iscritto, p_tipo, p_titolo, p_testo, p_premio, p_push, p_email)
  returning id
$$;

-- il regalo di compleanno: per N persone (il premio di benvenuto × compleanno_per), dai giorni
-- prima ai giorni dopo il compleanno, VALE ANCHE DI SABATO (solo il giorno di chiusura no).
-- Uno all'anno. L'avviso parte solo a chi ha accettato le offerte. Torna il codice o null.
create or replace function public.club_dai_compleanno(i public.club_iscritti, s date) returns text
language plpgsql volatile set search_path = public as $$
declare imp public.club_impostazioni; b date; c text; d2 date; it boolean := i.lingua = 'it'; nome1 text;
begin
  select * into imp from public.club_impostazioni where id = 1;
  b := public.club_prossimo_compleanno(i.nascita, s - imp.compleanno_giorni);
  if s < b - imp.compleanno_giorni or s > b + imp.compleanno_giorni then return null; end if;
  if exists (select 1 from public.club_premi where iscritto = i.id and tipo = 'compleanno'
                                               and creato > now() - interval '300 days') then return null; end if;
  d2 := b + imp.compleanno_giorni;
  loop
    c := public.pr_casuale(7);
    exit when not exists (select 1 from public.club_premi where codice = c);
  end loop;
  insert into public.club_premi (codice, iscritto, tipo, emoji, nome, persone, dal, al, giorni_no)
  values (c, i.id, 'compleanno', '🎂', imp.premio_nome, imp.premio_persone * imp.compleanno_per, s, d2, imp.giorni_chiusura);
  if i.promo then
    nome1 := split_part(trim(i.nome), ' ', 1);
    perform public.club_accoda(i.id, 'compleanno',
      case when it then '🎂 Buon compleanno, ' || nome1 || '!' else '🎂 Happy birthday, ' || nome1 || '!' end,
      case when it
        then 'Per festeggiare ti offriamo ' || public.club_nome(imp.premio_nome, 'it') || ' per ' ||
             public.club_persone(imp.premio_persone * imp.compleanno_per, 'it') || ': vale ' || public.club_periodo(s, d2, 'it') ||
             ', anche di sabato. Mostra la tessera del Club appena arrivi.'
        else 'To celebrate, ' || public.club_nome(imp.premio_nome, 'en') || ' for ' ||
             public.club_persone(imp.premio_persone * imp.compleanno_per, 'en') || ' is on us: valid ' ||
             public.club_periodo(s, d2, 'en') || ', Saturdays included. Show your Club card when you arrive.' end,
      c, true, true);
    update public.club_iscritti set ultimo_contatto = now() where id = i.id;
  end if;
  return c;
end $$;

-- l'offerta "ci manchi": una delle offerte attive, a giro; vale per N sere da stasera (il sabato non si conta)
create or replace function public.club_dai_offerta(i public.club_iscritti, s date) returns text
language plpgsql volatile set search_path = public as $$
declare imp public.club_impostazioni; o public.club_offerte; n int; g int[]; d1 date; d2 date; c text;
        it boolean := i.lingua = 'it'; nome1 text;
begin
  select * into imp from public.club_impostazioni where id = 1;
  select count(*) into n from public.club_offerte where attivo;
  if n = 0 then return null; end if;
  select * into o from public.club_offerte where attivo order by ordine, id
   offset ((select count(*) from public.club_premi where iscritto = i.id and tipo = 'promo') % n) limit 1;
  g := imp.giorni_no || imp.giorni_chiusura;
  d1 := public.club_piu_sere(s, 1, g);
  d2 := public.club_piu_sere(d1, imp.offerte_sere, g);
  loop
    c := public.pr_casuale(7);
    exit when not exists (select 1 from public.club_premi where codice = c);
  end loop;
  insert into public.club_premi (codice, iscritto, tipo, emoji, nome, persone, dal, al, giorni_no)
  values (c, i.id, 'promo', o.emoji, o.nome, imp.offerte_persone, d1, d2, g);
  nome1 := split_part(trim(i.nome), ' ', 1);
  perform public.club_accoda(i.id, 'promo',
    case when it then '💌 Ci manchi, ' || nome1 || '!' else '💌 We miss you, ' || nome1 || '!' end,
    case when it
      then 'Per te ' || o.emoji || ' ' || public.club_nome(o.nome, 'it') || ' per ' || public.club_persone(imp.offerte_persone, 'it') ||
           ': vale ' || public.club_periodo(d1, d2, 'it') || '. Mostra la tessera del Club appena arrivi.'
      else 'Just for you: ' || o.emoji || ' ' || public.club_nome(o.nome, 'en') || ' for ' || public.club_persone(imp.offerte_persone, 'en') ||
           ', valid ' || public.club_periodo(d1, d2, 'en') || '. Show your Club card when you arrive.' end,
    c, true, true);
  update public.club_iscritti set ultimo_contatto = now() where id = i.id;
  return c;
end $$;

-- il giro di ogni mattina: regali di compleanno e offerte "ci manchi". Si può rifare: non raddoppia niente.
create or replace function public.club_giro() returns jsonb
language plpgsql volatile set search_path = public as $$
declare s date := public.pr_sera(now()); imp public.club_impostazioni; i public.club_iscritti;
        nc int := 0; nof int := 0; esito jsonb;
begin
  select * into imp from public.club_impostazioni where id = 1;
  -- 1) compleanni: il regalo lo trovano tutti nella tessera
  for i in select * from public.club_iscritti loop
    if public.club_dai_compleanno(i, s) is not null then nc := nc + 1; end if;
  end loop;
  -- 2) offerte: solo a chi le ha accettate, si può avvisare, non si vede da N settimane,
  --    non ha avuto un avviso negli ultimi giorni e non ha già un premio da usare
  if imp.offerte_attive then
    for i in
      select c.* from public.club_iscritti c
       where c.promo
         and (exists (select 1 from public.club_push x where x.iscritto = c.id)
              or (imp.email_attive and c.email_confermata is not null))
         and coalesce(c.ultimo_contatto, '-infinity'::timestamptz) < now() - make_interval(days => imp.offerte_pausa)
         and greatest(c.creato, coalesce((select max(p.usato) from public.club_premi p where p.iscritto = c.id), c.creato))
             < now() - make_interval(weeks => imp.offerte_settimane)
         and not exists (select 1 from public.club_premi p
                          where p.iscritto = c.id and public.club_stato(p) in ('valido', 'presto', 'oggi_no'))
       order by c.creato
       limit 200
    loop
      if public.club_dai_offerta(i, s) is not null then nof := nof + 1; end if;
    end loop;
  end if;
  esito := jsonb_build_object('compleanni', nc, 'offerte', nof);
  update public.club_impostazioni set ultimo_giro = now(), ultimo_esito = esito where id = 1;
  return esito;
end $$;

-- per la funzione club-invia: prende i messaggi in coda (al massimo n) e li segna come presi,
-- così due invii insieme non mandano lo stesso avviso due volte
create or replace function public.club_prendi_messaggi(n int) returns jsonb
language sql volatile security definer set search_path = public as $$
  with presi as (
    update public.club_messaggi m set inviato = now()
     where m.id in (select id from public.club_messaggi where inviato is null order by creato limit n for update skip locked)
    returning m.*)
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'tipo', p.tipo, 'titolo', p.titolo, 'testo', p.testo, 'premio', p.premio,
           'push', p.push, 'email', p.email,
           'nome', i.nome, 'indirizzo', i.email, 'lingua', i.lingua, 'token', i.email_token,
           'confermata', i.email_confermata is not null, 'promo', i.promo, 'codice', i.codice,
           'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', x.endpoint, 'sub', x.sub))
                               from public.club_push x where x.iscritto = i.id), '[]'::jsonb))), '[]'::jsonb)
    from presi p join public.club_iscritti i on i.id = p.iscritto
$$;

revoke execute on function public.club_data(date, text)                     from public, anon, authenticated;
revoke execute on function public.club_periodo(date, date, text)            from public, anon, authenticated;
revoke execute on function public.club_nome(jsonb, text)                    from public, anon, authenticated;
revoke execute on function public.club_persone(int, text)                   from public, anon, authenticated;
revoke execute on function public.club_accoda(uuid, text, text, text, text, boolean, boolean) from public, anon, authenticated;
revoke execute on function public.club_dai_compleanno(public.club_iscritti, date) from public, anon, authenticated;
revoke execute on function public.club_dai_offerta(public.club_iscritti, date)    from public, anon, authenticated;
revoke execute on function public.club_giro()                               from public, anon, authenticated;
revoke execute on function public.club_prendi_messaggi(int)                 from public, anon, authenticated;
grant execute on function public.club_prendi_messaggi(int) to service_role;

-- il cliente come si vede: in più le regole del compleanno, le email e gli avvisi attivi
create or replace function public.club_vista_iscritto(i public.club_iscritti) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object(
    'nome', i.nome, 'email', i.email, 'telefono', i.telefono, 'nascita', i.nascita,
    'promo', i.promo, 'creato', i.creato, 'emailConfermata', i.email_confermata is not null,
    'notifiche', (select count(*) from public.club_push x where x.iscritto = i.id),
    'regole', (select jsonb_build_object('compleannoPersone', premio_persone * compleanno_per,
                                          'compleannoGiorni', compleanno_giorni, 'email', email_attive)
                 from public.club_impostazioni where id = 1),
    'premi', coalesce((
      select jsonb_agg(public.club_vista_premio(p) order by (p.usato is not null), p.dal, p.creato)
        from public.club_premi p
       where p.iscritto = i.id and (p.usato is null or p.usato > now() - interval '60 days')), '[]'::jsonb))
$$;


-- ================= CLIENTE (dentro il menu) =================

create or replace function public.club_info() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('emoji', premio_emoji, 'nome', premio_nome, 'persone', premio_persone,
                            'sere', premio_sere, 'giorniNo', to_jsonb(giorni_no || giorni_chiusura),
                            'compleannoPersone', premio_persone * compleanno_per, 'email', email_attive)
    from public.club_impostazioni where id = 1
$$;

-- iscrizione: come prima, in più il regalo di compleanno (se cade in questi giorni) e,
-- con le email accese, l'email di benvenuto con il link per confermare l'indirizzo
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
  pb   text;
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
  pb := (public.club_dai_benvenuto(i.id)).codice;
  perform public.club_dai_compleanno(i, public.pr_sera(now()));
  if (select email_attive from public.club_impostazioni where id = 1) then
    perform public.club_accoda(i.id, 'benvenuto',
      case when i.lingua = 'it' then 'Sei nel Club del Vico, ' || split_part(n, ' ', 1) || '!'
           else 'You''re in the Vico Club, ' || split_part(n, ' ', 1) || '!' end,
      case when i.lingua = 'it'
        then 'Il tuo premio di benvenuto ti aspetta alla prossima visita. Conferma la tua email: così ti mandiamo anche le offerte e il regalo di compleanno.'
        else 'Your welcome gift is waiting for your next visit. Please confirm your email so we can also send you offers and your birthday gift.' end,
      pb, false, true);
  end if;
  return jsonb_build_object('chiave', i.chiave) || public.club_vista_iscritto(i);
exception when unique_violation then
  raise exception 'Questa email o questo numero sono già nel Club' using hint = 'gia';
end $$;

-- il cliente accende le notifiche su questo telefono (al massimo 5 telefoni per tessera)
create or replace function public.club_salva_push(p_chiave text, p_sub jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  select * into i from public.club_iscritti where chiave = p_chiave;
  if not found then raise exception 'Tessera non trovata' using hint = 'chiave'; end if;
  if coalesce(p_sub->>'endpoint', '') !~ '^https://' then raise exception 'Abbonamento non valido' using hint = 'push'; end if;
  insert into public.club_push (endpoint, iscritto, sub) values (p_sub->>'endpoint', i.id, p_sub)
  on conflict (endpoint) do update set iscritto = excluded.iscritto, sub = excluded.sub, creato = now();
  delete from public.club_push where iscritto = i.id and endpoint not in (
    select endpoint from public.club_push where iscritto = i.id order by creato desc limit 5);
  return public.club_vista_iscritto(i);
end $$;

create or replace function public.club_togli_push(p_chiave text, p_endpoint text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  select * into i from public.club_iscritti where chiave = p_chiave;
  if not found then raise exception 'Tessera non trovata' using hint = 'chiave'; end if;
  delete from public.club_push where iscritto = i.id and endpoint = p_endpoint;
  return public.club_vista_iscritto(i);
end $$;

-- link "Conferma la tua email" (dall'email di benvenuto)
create or replace function public.club_conferma_email(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  update public.club_iscritti set email_confermata = coalesce(email_confermata, now())
   where email_token = p_token returning * into i;
  if not found then raise exception 'Link non valido' using hint = 'token'; end if;
  return jsonb_build_object('nome', i.nome);
end $$;

-- link "Non voglio più le offerte" (in fondo a ogni email): funziona senza entrare
create or replace function public.club_stop_offerte(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  update public.club_iscritti set promo = false, promo_quando = now()
   where email_token = p_token returning * into i;
  if not found then raise exception 'Link non valido' using hint = 'token'; end if;
  return jsonb_build_object('nome', i.nome);
end $$;

-- rimanda l'email di conferma (al massimo 3 al giorno)
create or replace function public.club_rimanda_conferma(p_chiave text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  select * into i from public.club_iscritti where chiave = p_chiave;
  if not found then raise exception 'Tessera non trovata' using hint = 'chiave'; end if;
  if not (select email_attive from public.club_impostazioni where id = 1) then
    raise exception 'Le email del Club non sono ancora attive' using hint = 'email_spente';
  end if;
  if i.email_confermata is not null then return true; end if;
  if (select count(*) from public.club_messaggi where iscritto = i.id and tipo = 'benvenuto'
                                                  and creato > now() - interval '1 day') >= 3 then
    raise exception 'Troppe email: riprova domani' using hint = 'troppe';
  end if;
  perform public.club_accoda(i.id, 'benvenuto',
    case when i.lingua = 'it' then 'Conferma la tua email del Club del Vico' else 'Confirm your Vico Club email' end,
    case when i.lingua = 'it' then 'Tocca il tasto qui sotto per confermare la tua email.' else 'Tap the button below to confirm your email.' end,
    null, false, true);
  return true;
end $$;

-- "Ho cambiato telefono": codice a 6 cifre via email (vale 15 minuti, 3 richieste all'ora)
create or replace function public.club_chiedi_codice(p_email text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare i public.club_iscritti; c text;
begin
  if not (select email_attive from public.club_impostazioni where id = 1) then
    raise exception 'Le email del Club non sono ancora attive' using hint = 'email_spente';
  end if;
  select * into i from public.club_iscritti where lower(email) = lower(trim(coalesce(p_email, '')));
  if not found then return true; end if;     -- non diciamo a nessuno chi è iscritto e chi no
  if (select count(*) from public.club_messaggi where iscritto = i.id and tipo = 'codice'
                                                  and creato > now() - interval '1 hour') >= 3 then
    raise exception 'Troppe richieste: riprova fra un''ora' using hint = 'troppe';
  end if;
  c := lpad((abs(('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::int) % 1000000)::text, 6, '0');
  update public.club_iscritti set codice = c, codice_scade = now() + interval '15 minutes', codice_tentativi = 0
   where id = i.id;
  perform public.club_accoda(i.id, 'codice',
    case when i.lingua = 'it' then 'Il tuo codice del Club: ' || c else 'Your Club code: ' || c end,
    case when i.lingua = 'it' then 'Scrivi questo codice nel menu per ritrovare la tua tessera. Vale 15 minuti.'
         else 'Type this code in the menu to get your card back. It is valid for 15 minutes.' end,
    null, false, true);
  return true;
end $$;

-- il codice giusto riapre la tessera su questo telefono (e conferma l'email). Dopo 5 errori serve un codice nuovo.
create or replace function public.club_usa_codice(p_email text, p_codice text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  select * into i from public.club_iscritti where lower(email) = lower(trim(coalesce(p_email, '')));
  if not found or i.codice is null or now() > i.codice_scade or i.codice_tentativi >= 5 then
    return jsonb_build_object('errore', 'scaduto');
  end if;
  if i.codice <> regexp_replace(coalesce(p_codice, ''), '\D', '', 'g') then
    update public.club_iscritti set codice_tentativi = codice_tentativi + 1 where id = i.id;
    return jsonb_build_object('errore', 'codice');
  end if;
  update public.club_iscritti set codice = null, codice_scade = null, codice_tentativi = 0,
                                  email_confermata = coalesce(email_confermata, now())
   where id = i.id returning * into i;
  return jsonb_build_object('chiave', i.chiave) || public.club_vista_iscritto(i);
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
    'conNotifiche', (select count(distinct iscritto) from public.club_push),
    'attivi',   (select count(*) from public.club_premi p where public.club_stato(p) in ('valido', 'presto', 'oggi_no')),
    'usatiMese', (select count(*) from public.club_premi
                   where sera_uso is not null and date_trunc('month', sera_uso) = date_trunc('month', s)),
    'inCoda',   (select count(*) from public.club_messaggi where inviato is null),
    'ultimoGiro', (select ultimo_giro from public.club_impostazioni where id = 1),
    'ultimoEsito', (select ultimo_esito from public.club_impostazioni where id = 1),
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

create or replace function public.club_dettaglio(p_pin text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into i from public.club_iscritti where id = p_id;
  if not found then raise exception 'Iscritto non trovato' using hint = 'iscritto'; end if;
  return jsonb_build_object('id', i.id, 'chiave', i.chiave, 'nome', i.nome, 'email', i.email,
           'telefono', i.telefono, 'nascita', i.nascita, 'promo', i.promo, 'promoQuando', i.promo_quando,
           'lingua', i.lingua, 'creato', i.creato, 'emailConfermata', i.email_confermata is not null,
           'ultimoContatto', i.ultimo_contatto,
           'notifiche', (select count(*) from public.club_push x where x.iscritto = i.id),
           'premi', coalesce((select jsonb_agg(public.club_vista_premio(p) order by p.creato desc)
                                from public.club_premi p where p.iscritto = i.id), '[]'::jsonb));
end $$;

create or replace function public.club_impostazioni(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return (select jsonb_build_object('emoji', premio_emoji, 'nome', premio_nome, 'persone', premio_persone,
                                     'sere', premio_sere, 'giorniNo', to_jsonb(giorni_no),
                                     'giorniChiusura', to_jsonb(giorni_chiusura),
                                     'compleannoPer', compleanno_per, 'compleannoGiorni', compleanno_giorni,
                                     'offerteAttive', offerte_attive, 'offerteSettimane', offerte_settimane,
                                     'offertePersone', offerte_persone, 'offerteSere', offerte_sere,
                                     'offertePausa', offerte_pausa, 'emailAttive', email_attive)
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
  -- compleanno e offerte
  if p_dati ? 'compleannoPer' then
    v := trim(p_dati->>'compleannoPer');
    if coalesce(v, '') !~ '^[1-5]$' then raise exception 'Moltiplicatore non valido (da 1 a 5)' using hint = 'compleanno'; end if;
    update public.club_impostazioni set compleanno_per = v::int where id = 1;
  end if;
  if p_dati ? 'compleannoGiorni' then
    v := trim(p_dati->>'compleannoGiorni');
    if coalesce(v, '') !~ '^[0-7]$' then raise exception 'Giorni non validi (da 0 a 7)' using hint = 'compleanno'; end if;
    update public.club_impostazioni set compleanno_giorni = v::int where id = 1;
  end if;
  if p_dati ? 'offerteAttive' then
    update public.club_impostazioni set offerte_attive = coalesce((p_dati->>'offerteAttive')::boolean, true) where id = 1;
  end if;
  if p_dati ? 'offerteSettimane' then
    v := trim(p_dati->>'offerteSettimane');
    if coalesce(v, '') !~ '^\d{1,2}$' or v::int < 1 or v::int > 12 then
      raise exception 'Settimane non valide (da 1 a 12)' using hint = 'offerte';
    end if;
    update public.club_impostazioni set offerte_settimane = v::int where id = 1;
  end if;
  if p_dati ? 'offertePersone' then
    v := trim(p_dati->>'offertePersone');
    if coalesce(v, '') !~ '^\d{1,2}$' or v::int < 1 or v::int > 20 then
      raise exception 'Persone non valide (da 1 a 20)' using hint = 'offerte';
    end if;
    update public.club_impostazioni set offerte_persone = v::int where id = 1;
  end if;
  if p_dati ? 'offerteSere' then
    v := trim(p_dati->>'offerteSere');
    if coalesce(v, '') !~ '^\d{1,2}$' or v::int < 1 or v::int > 14 then
      raise exception 'Sere non valide (da 1 a 14)' using hint = 'offerte';
    end if;
    update public.club_impostazioni set offerte_sere = v::int where id = 1;
  end if;
  if p_dati ? 'offertePausa' then
    v := trim(p_dati->>'offertePausa');
    if coalesce(v, '') !~ '^\d{1,2}$' or v::int < 7 or v::int > 90 then
      raise exception 'Giorni fra due offerte non validi (da 7 a 90)' using hint = 'offerte';
    end if;
    update public.club_impostazioni set offerte_pausa = v::int where id = 1;
  end if;
  if p_dati ? 'emailAttive' then
    update public.club_impostazioni set email_attive = coalesce((p_dati->>'emailAttive')::boolean, false) where id = 1;
  end if;
  return public.club_impostazioni(p_pin);
end $$;

create or replace function public.club_offerte(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'emoji', emoji, 'nome', nome, 'attivo', attivo)
                                    order by ordine, id) from public.club_offerte), '[]'::jsonb);
end $$;

create or replace function public.club_salva_offerte(p_pin text, p_lista jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare x jsonb; k int := 0;
begin
  perform public.pr_controlla_pin(p_pin);
  if jsonb_typeof(p_lista) <> 'array' or jsonb_array_length(p_lista) > 20 then
    raise exception 'Elenco offerte non valido' using hint = 'offerte';
  end if;
  if exists (select 1 from jsonb_array_elements(p_lista) e
              where coalesce((e->>'attivo')::boolean, true) and trim(coalesce(e->'nome'->>'it', '')) = '') then
    raise exception 'Ogni offerta attiva ha bisogno di un nome' using hint = 'offerte';
  end if;
  delete from public.club_offerte where true;   -- i premi già dati hanno la loro copia dell'offerta
  for x in select value from jsonb_array_elements(p_lista) loop
    k := k + 1;
    insert into public.club_offerte (id, ordine, emoji, nome, attivo)
    values (coalesce(nullif(x->>'id', ''), public.pr_casuale(6)), k,
            left(coalesce(nullif(trim(x->>'emoji'), ''), '🎁'), 8),
            jsonb_build_object('it', left(trim(coalesce(x->'nome'->>'it', '')), 60),
                               'en', left(trim(coalesce(x->'nome'->>'en', '')), 60)),
            coalesce((x->>'attivo')::boolean, true))
    on conflict (id) do nothing;
  end loop;
  return public.club_offerte(p_pin);
end $$;

-- gli ultimi avvisi, per controllare cosa è partito e come
create or replace function public.club_messaggi(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', m.id, 'nome', i.nome, 'iscritto', i.id, 'tipo', m.tipo, 'titolo', m.titolo,
                                        'creato', m.creato, 'inviato', m.inviato, 'esito', m.esito)
                     order by m.creato desc)
      from (select * from public.club_messaggi order by creato desc limit 40) m
      join public.club_iscritti i on i.id = m.iscritto), '[]'::jsonb);
end $$;

-- "Fai il giro adesso": lo stesso controllo di ogni mattina, quando lo vuoi tu
create or replace function public.club_giro_ora(p_pin text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return public.club_giro();
end $$;

-- un avviso di prova a un iscritto (per vedere se le notifiche arrivano sul suo telefono)
create or replace function public.club_prova_avviso(p_pin text, p_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into i from public.club_iscritti where id = p_id;
  if not found then raise exception 'Iscritto non trovato' using hint = 'iscritto'; end if;
  perform public.club_accoda(i.id, 'prova',
    case when i.lingua = 'it' then '🔔 Prova del Club del Vico' else '🔔 Vico Club test' end,
    case when i.lingua = 'it' then 'Se leggi questo messaggio, gli avvisi del Club arrivano su questo telefono.'
         else 'If you can read this, Club alerts reach this phone.' end,
    null, true, true);
  return jsonb_build_object('notifiche', (select count(*) from public.club_push where iscritto = i.id));
end $$;

grant execute on function
  public.club_info(), public.club_iscriviti(text, text, text, text, boolean, text, text),
  public.club_salva_push(text, jsonb), public.club_togli_push(text, text),
  public.club_conferma_email(text), public.club_stop_offerte(text), public.club_rimanda_conferma(text),
  public.club_chiedi_codice(text), public.club_usa_codice(text, text),
  public.club_panoramica(text), public.club_dettaglio(text, uuid),
  public.club_impostazioni(text), public.club_salva_impostazioni(text, jsonb),
  public.club_offerte(text), public.club_salva_offerte(text, jsonb), public.club_messaggi(text),
  public.club_giro_ora(text), public.club_prova_avviso(text, uuid)
to anon, authenticated;

notify pgrst, 'reload schema';
