-- =============================================================================
-- PRENOTAZIONI — Club del Vico, fase 3
-- Il cliente prenota dal sito (vicodelcarmine.it): sceglie sera, turno e persone e
-- lascia i dati del Club. Se il turno ha posto la prenotazione è confermata subito.
-- Chi è già nel Club (iscritto dal menu) viene riconosciuto da telefono + email.
-- Il titolare le vede nella dashboard (scheda Prenota), aggiunge a mano quelle
-- arrivate per telefono, TheFork o Google, e riceve una notifica a ogni novità
-- (funzione "pren-avvisa").
-- Tutto ha il prefisso pren_ : NON tocca menu, ordini, agenti né i dati del Club
-- (usa solo club_iscriviti per i nuovi soci e le funzioni di servizio pr_*).
-- Le tabelle non sono leggibili dall'esterno (RLS senza regole).
-- Si può rieseguire: non cancella niente.
-- =============================================================================

-- ---------- tabelle ----------
create table if not exists public.pren_impostazioni (
  id            int primary key default 1 check (id = 1),
  attive        boolean not null default true,                -- prenotazioni dal sito accese
  turni         text[]  not null default '{19:30,21:30}',     -- orari dei turni della sera
  coperti       int     not null default 40  check (coperti between 1 and 500),     -- per turno
  max_persone   int     not null default 8   check (max_persone between 1 and 60),  -- per prenotazione dal sito
  giorni_avanti int     not null default 30  check (giorni_avanti between 1 and 180),
  anticipo_min  int     not null default 120 check (anticipo_min between 0 and 2880), -- fino a quanto prima del turno
  date_chiuse   date[]  not null default '{}'                 -- sere chiuse in più (ferie, eventi)
);
insert into public.pren_impostazioni (id) values (1) on conflict (id) do nothing;

create table if not exists public.pren_prenotazioni (
  id           uuid primary key default gen_random_uuid(),
  codice       text unique not null,          -- 6 caratteri: per ritrovarla al telefono
  segreto      text unique,                   -- sta solo nel browser di chi ha prenotato dal sito (per annullare)
  sera         date not null,
  turno        text not null,                 -- "19:30"
  persone      int  not null check (persone between 1 and 200),
  nome         text not null,
  telefono     text not null default '',
  nota         text not null default '',
  fonte        text not null default 'sito' check (fonte in ('sito', 'telefono', 'thefork', 'google', 'altro')),
  stato        text not null default 'confermata' check (stato in ('confermata', 'arrivati', 'noshow', 'annullata')),
  iscritto     uuid references public.club_iscritti(id) on delete set null,
  dispositivo  text not null default '',
  lingua       text not null default 'it',
  creato       timestamptz not null default now(),
  annullata    timestamptz,
  annullata_da text
);
create index if not exists pren_prenotazioni_sera     on public.pren_prenotazioni (sera, turno);
create index if not exists pren_prenotazioni_iscritto on public.pren_prenotazioni (iscritto);
create index if not exists pren_prenotazioni_disp     on public.pren_prenotazioni (dispositivo, creato);

-- coda delle notifiche al titolare (le manda la funzione "pren-avvisa", una volta sola)
create table if not exists public.pren_avvisi (
  id           bigserial primary key,
  prenotazione uuid not null references public.pren_prenotazioni(id) on delete cascade,
  tipo         text not null check (tipo in ('nuova', 'annullata')),
  creato       timestamptz not null default now(),
  inviato      timestamptz,
  esito        jsonb
);
create index if not exists pren_avvisi_coda on public.pren_avvisi (creato) where inviato is null;

-- i telefoni del titolare con le notifiche accese
create table if not exists public.pren_push (
  endpoint text primary key,
  sub      jsonb not null,
  creato   timestamptz not null default now()
);

alter table public.pren_impostazioni enable row level security;
alter table public.pren_prenotazioni enable row level security;
alter table public.pren_avvisi       enable row level security;
alter table public.pren_push         enable row level security;


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- oggi a Firenze (per le prenotazioni conta il giorno di calendario, non la "sera" degli agenti)
create or replace function public.pren_oggi() returns date
language sql stable set search_path = public as $$
  select (now() at time zone 'Europe/Rome')::date
$$;

-- quando comincia un turno ("19:30" della sera s, ora di Firenze)
create or replace function public.pren_inizio(s date, t text) returns timestamptz
language sql stable set search_path = public as $$
  select (s + t::time) at time zone 'Europe/Rome'
$$;

-- sera chiusa: giorno di chiusura del Club o una delle date chiuse delle prenotazioni
create or replace function public.pren_chiuso(s date) returns boolean
language sql stable set search_path = public as $$
  select extract(dow from s)::int = any((select giorni_chiusura from public.club_impostazioni where id = 1))
      or s = any((select date_chiuse from public.pren_impostazioni where id = 1))
$$;

-- coperti già presi in un turno (contano anche quelle aggiunte dal titolare)
create or replace function public.pren_occupati(s date, t text) returns int
language sql stable set search_path = public as $$
  select coalesce(sum(persone), 0)::int from public.pren_prenotazioni
   where sera = s and turno = t and stato in ('confermata', 'arrivati')
$$;

create or replace function public.pren_vista(p public.pren_prenotazioni) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('codice', p.codice, 'sera', p.sera, 'turno', p.turno, 'persone', p.persone,
                            'nome', p.nome, 'nota', p.nota, 'stato', p.stato)
$$;

create or replace function public.pren_vista_titolare(p public.pren_prenotazioni) returns jsonb
language sql stable set search_path = public as $$
  select public.pren_vista(p) || jsonb_build_object('id', p.id, 'telefono', p.telefono, 'fonte', p.fonte,
         'socio', p.iscritto is not null, 'iscritto', p.iscritto, 'creato', p.creato,
         'annullata', p.annullata, 'annullataDa', p.annullata_da)
$$;

create or replace function public.pren_nuovo_codice() returns text
language plpgsql volatile set search_path = public as $$
declare c text;
begin
  loop
    c := public.pr_casuale(6);
    exit when not exists (select 1 from public.pren_prenotazioni where codice = c);
  end loop;
  return c;
end $$;

-- la funzione "pren-avvisa" prende gli avvisi in coda (una volta sola) con il testo già pronto
create or replace function public.pren_prendi_avvisi(n int) returns jsonb
language sql volatile security definer set search_path = public as $$
  with presi as (
    update public.pren_avvisi a set inviato = now()
     where a.id in (select id from public.pren_avvisi where inviato is null order by creato limit n for update skip locked)
    returning a.*)
  select jsonb_build_object(
    'avvisi', coalesce(jsonb_agg(jsonb_build_object(
      'id', a.id, 'tipo', a.tipo, 'prenotazione', p.id,
      'titolo', case when a.tipo = 'nuova' then '📅 Nuova prenotazione' else '❌ Prenotazione annullata' end,
      'testo', p.nome || ' · ' || public.club_persone(p.persone, 'it') || ' · ' ||
               public.club_data(p.sera, 'it') || ' alle ' || p.turno ||
               case when p.nota <> '' and a.tipo = 'nuova' then ' · «' || left(p.nota, 60) || '»' else '' end)
      order by a.id) filter (where a.id is not null), '[]'::jsonb),
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', x.endpoint, 'sub', x.sub)) from public.pren_push x), '[]'::jsonb))
    from presi a join public.pren_prenotazioni p on p.id = a.prenotazione
$$;

revoke execute on function public.pren_oggi()                                  from public, anon, authenticated;
revoke execute on function public.pren_inizio(date, text)                      from public, anon, authenticated;
revoke execute on function public.pren_chiuso(date)                            from public, anon, authenticated;
revoke execute on function public.pren_occupati(date, text)                    from public, anon, authenticated;
revoke execute on function public.pren_vista(public.pren_prenotazioni)          from public, anon, authenticated;
revoke execute on function public.pren_vista_titolare(public.pren_prenotazioni) from public, anon, authenticated;
revoke execute on function public.pren_nuovo_codice()                          from public, anon, authenticated;
revoke execute on function public.pren_prendi_avvisi(int)                      from public, anon, authenticated;
grant execute on function public.pren_prendi_avvisi(int) to service_role;


-- ================= CLIENTE (sito) =================

-- i giorni e i turni prenotabili, con i posti liberi (al massimo quanti se ne possono prenotare insieme)
create or replace function public.pren_disponibilita() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  imp    public.pren_impostazioni;
  oggi   date := public.pren_oggi();
  s      date;
  t      text;
  liberi int;
  turni  jsonb;
  giorni jsonb := '[]'::jsonb;
begin
  select * into imp from public.pren_impostazioni where id = 1;
  for i in 0 .. imp.giorni_avanti loop
    s := oggi + i;
    turni := '[]'::jsonb;
    foreach t in array imp.turni loop
      if not imp.attive or public.pren_chiuso(s)
         or public.pren_inizio(s, t) - make_interval(mins => imp.anticipo_min) < now() then
        liberi := 0;
      else
        liberi := least(imp.max_persone, greatest(0, imp.coperti - public.pren_occupati(s, t)));
      end if;
      turni := turni || jsonb_build_object('ora', t, 'liberi', liberi);
    end loop;
    giorni := giorni || jsonb_build_object('sera', s, 'chiuso', public.pren_chiuso(s), 'turni', turni);
  end loop;
  return jsonb_build_object('attive', imp.attive, 'maxPersone', imp.max_persone, 'giorni', giorni);
end $$;

-- prenota. Chi è riconosciuto (chiave del Club salvata su questo sito, oppure telefono + email
-- di un iscritto) prenota e basta; gli altri entrano nel Club con questi dati e ricevono la chiave.
create or replace function public.pren_prenota(p_sera text, p_turno text, p_persone int, p_nota text, p_chiave text,
                                               p_nome text, p_email text, p_telefono text, p_nascita text,
                                               p_promo boolean, p_lingua text, p_dispositivo text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  imp   public.pren_impostazioni;
  oggi  date := public.pren_oggi();
  s     date;
  t     text := trim(coalesce(p_turno, ''));
  n     int  := coalesce(p_persone, 0);
  disp  text := left(coalesce(p_dispositivo, ''), 64);
  e     text := lower(trim(coalesce(p_email, '')));
  tel   text := public.club_telefono(p_telefono);
  ling  text := left(coalesce(nullif(trim(p_lingua), ''), 'it'), 5);
  i     public.club_iscritti;
  nuovo jsonb;
  p     public.pren_prenotazioni;
  liberi int;
begin
  select * into imp from public.pren_impostazioni where id = 1;
  if not imp.attive then raise exception 'Le prenotazioni online sono chiuse: chiamaci' using hint = 'chiuse'; end if;
  begin
    s := p_sera::date;
  exception when others then
    s := null;
  end;
  if s is null or not (t = any(imp.turni)) then raise exception 'Sera o turno non validi' using hint = 'turno'; end if;
  if s < oggi or s > oggi + imp.giorni_avanti or public.pren_chiuso(s) then
    raise exception 'Quella sera non si può prenotare' using hint = 'sera';
  end if;
  if public.pren_inizio(s, t) - make_interval(mins => imp.anticipo_min) < now() then
    raise exception 'È tardi per prenotare online questo turno: chiamaci' using hint = 'tardi';
  end if;
  if n < 1 then raise exception 'Quante persone siete?' using hint = 'persone'; end if;
  if n > imp.max_persone then raise exception 'Per gruppi più grandi chiamaci' using hint = 'gruppo'; end if;
  if (disp <> '' and (select count(*) from public.pren_prenotazioni
                       where dispositivo = disp and creato > now() - interval '1 day') >= 5)
     or (select count(*) from public.pren_prenotazioni
          where fonte = 'sito' and creato > now() - interval '1 day') >= 300 then
    raise exception 'Troppe prenotazioni: chiamaci' using hint = 'troppe';
  end if;
  -- c'è ancora posto? (si ricontrolla sotto, col lucchetto, prima di scrivere)
  if n > imp.coperti - public.pren_occupati(s, t) then
    raise exception 'Il turno delle % è pieno', t using hint = 'pieno';
  end if;

  -- chi prenota
  if coalesce(p_chiave, '') <> '' then
    select * into i from public.club_iscritti where chiave = p_chiave;
  end if;
  if i.id is null then
    if tel is null then raise exception 'Numero di telefono non valido' using hint = 'telefono'; end if;
    if length(e) > 120 or e !~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$' then
      raise exception 'Email non valida' using hint = 'email';
    end if;
    select * into i from public.club_iscritti where lower(email) = e and telefono = tel;
    if i.id is null then
      if exists (select 1 from public.club_iscritti where lower(email) = e or telefono = tel) then
        raise exception 'Questa email o questo numero sono già nel Club con altri dati: scrivili come quando ti sei iscritto'
          using hint = 'gia';
      end if;
      nuovo := public.club_iscriviti(p_nome, p_email, p_telefono, p_nascita, p_promo, ling, disp);
      select * into i from public.club_iscritti where chiave = nuovo->>'chiave';
    end if;
  end if;
  if exists (select 1 from public.pren_prenotazioni where iscritto = i.id and sera = s and stato = 'confermata') then
    raise exception 'Hai già una prenotazione per questa sera' using hint = 'doppia';
  end if;
  if (select count(*) from public.pren_prenotazioni
       where iscritto = i.id and stato = 'confermata' and sera >= oggi) >= 3 then
    raise exception 'Hai già 3 prenotazioni in arrivo: chiamaci' using hint = 'tante';
  end if;

  -- un turno alla volta: due prenotazioni nello stesso istante non possono superare i coperti
  perform pg_advisory_xact_lock(hashtext('pren:' || s || ':' || t));
  liberi := imp.coperti - public.pren_occupati(s, t);
  if n > liberi then
    raise exception 'Il turno delle % è pieno', t using hint = 'pieno';
  end if;

  insert into public.pren_prenotazioni (codice, segreto, sera, turno, persone, nome, telefono, nota, fonte,
                                        iscritto, dispositivo, lingua)
  values (public.pren_nuovo_codice(), public.pr_casuale(24), s, t, n, i.nome, i.telefono,
          left(trim(coalesce(p_nota, '')), 300), 'sito', i.id, disp, ling)
  returning * into p;
  insert into public.pren_avvisi (prenotazione, tipo) values (p.id, 'nuova');
  return public.pren_vista(p) || jsonb_build_object('segreto', p.segreto, 'nuovo', nuovo is not null,
                                                    'chiave', nuovo->>'chiave');
end $$;

-- le prenotazioni fatte da questo browser (il sito tiene i loro "segreti")
create or replace function public.pren_mie(p_segreti text[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(public.pren_vista(p) || jsonb_build_object('segreto', p.segreto)
                            order by p.sera, p.turno), '[]'::jsonb)
    from public.pren_prenotazioni p
   where p.segreto = any((coalesce(p_segreti, '{}'::text[]))[1:20])
     and p.sera >= public.pren_oggi() - 1
$$;

-- il cliente annulla dal sito (fino all'inizio del turno)
create or replace function public.pren_annulla(p_segreto text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare p public.pren_prenotazioni;
begin
  select * into p from public.pren_prenotazioni where segreto = p_segreto and coalesce(p_segreto, '') <> '' for update;
  if p.id is null then raise exception 'Prenotazione non trovata' using hint = 'nonc'; end if;
  if p.stato <> 'confermata' then raise exception 'Questa prenotazione non si può più annullare' using hint = 'stato'; end if;
  if public.pren_inizio(p.sera, p.turno) < now() then
    raise exception 'Il turno è già cominciato: chiamaci' using hint = 'passata';
  end if;
  update public.pren_prenotazioni set stato = 'annullata', annullata = now(), annullata_da = 'cliente'
   where id = p.id returning * into p;
  insert into public.pren_avvisi (prenotazione, tipo) values (p.id, 'annullata');
  return public.pren_vista(p);
end $$;


-- ================= TITOLARE (dashboard, col PIN) =================

-- una sera: i turni con le prenotazioni, più il riepilogo dei prossimi 14 giorni
create or replace function public.pren_giorno(p_pin text, p_sera text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  imp   public.pren_impostazioni;
  oggi  date := public.pren_oggi();
  s     date;
  orari text[];
  t     text;
  turni jsonb := '[]'::jsonb;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into imp from public.pren_impostazioni where id = 1;
  begin
    s := coalesce(nullif(p_sera, '')::date, oggi);
  exception when others then
    s := oggi;
  end;
  -- i turni impostati più quelli di eventuali prenotazioni messe a mano a un'altra ora
  select array_agg(x order by x) into orari from (
    select unnest(imp.turni) as x
    union select turno from public.pren_prenotazioni where sera = s) z;
  foreach t in array coalesce(orari, '{}'::text[]) loop
    turni := turni || jsonb_build_object(
      'ora', t, 'prenotati', public.pren_occupati(s, t), 'previsto', t = any(imp.turni),
      'lista', coalesce((select jsonb_agg(public.pren_vista_titolare(p)
                                          order by (p.stato = 'annullata'), p.creato)
                           from public.pren_prenotazioni p where p.sera = s and p.turno = t), '[]'::jsonb));
  end loop;
  return jsonb_build_object(
    'sera', s, 'oggi', oggi, 'coperti', imp.coperti, 'chiuso', public.pren_chiuso(s), 'turni', turni,
    'prossimi', (select coalesce(jsonb_agg(jsonb_build_object(
                    'sera', d, 'chiuso', public.pren_chiuso(d),
                    'prenotazioni', (select count(*) from public.pren_prenotazioni
                                      where sera = d and stato in ('confermata', 'arrivati')),
                    'persone', (select coalesce(sum(persone), 0) from public.pren_prenotazioni
                                 where sera = d and stato in ('confermata', 'arrivati'))) order by d), '[]'::jsonb)
                   from (select oggi + k as d from generate_series(0, 13) k) g),
    'nuove', (select count(*) from public.pren_prenotazioni
               where fonte = 'sito' and creato > now() - interval '1 day' and stato = 'confermata'));
end $$;

-- prenotazione messa a mano (telefono, TheFork, Google…): nessun limite di coperti, decide il titolare
create or replace function public.pren_aggiungi(p_pin text, p_dati jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  s     date;
  t     text := trim(coalesce(p_dati->>'turno', ''));
  n     int;
  v_nome  text := left(trim(coalesce(p_dati->>'nome', '')), 60);
  tel     text := trim(coalesce(p_dati->>'telefono', ''));
  v_fonte text := coalesce(nullif(p_dati->>'fonte', ''), 'telefono');
  p       public.pren_prenotazioni;
begin
  perform public.pr_controlla_pin(p_pin);
  begin
    s := (p_dati->>'sera')::date;
  exception when others then
    s := null;
  end;
  begin
    n := (p_dati->>'persone')::int;
  exception when others then
    n := null;
  end;
  if s is null or s < public.pren_oggi() - 1 then raise exception 'Sera non valida' using hint = 'sera'; end if;
  if t !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Orario non valido' using hint = 'turno'; end if;
  if n is null or n < 1 or n > 200 then raise exception 'Numero di persone non valido' using hint = 'persone'; end if;
  if length(v_nome) < 2 then raise exception 'Scrivi il nome' using hint = 'nome'; end if;
  if v_fonte not in ('telefono', 'thefork', 'google', 'altro') then raise exception 'Provenienza non valida' using hint = 'fonte'; end if;
  if tel <> '' then
    tel := public.club_telefono(tel);
    if tel is null then raise exception 'Numero di telefono non valido' using hint = 'telefono'; end if;
  end if;
  insert into public.pren_prenotazioni (codice, sera, turno, persone, nome, telefono, nota, fonte, iscritto)
  values (public.pren_nuovo_codice(), s, t, n, v_nome, tel, left(trim(coalesce(p_dati->>'nota', '')), 300), v_fonte,
          (select id from public.club_iscritti where telefono = tel and tel <> ''))
  returning * into p;
  return public.pren_vista_titolare(p);
end $$;

-- cambia una prenotazione: stato (arrivati, non venuti, annullata, di nuovo confermata), persone, sera, turno, nota
create or replace function public.pren_modifica(p_pin text, p_id uuid, p_dati jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  p  public.pren_prenotazioni;
  st text := p_dati->>'stato';
  n  int;
  s  date;
  t  text := p_dati->>'turno';
begin
  perform public.pr_controlla_pin(p_pin);
  select * into p from public.pren_prenotazioni where id = p_id for update;
  if p.id is null then raise exception 'Prenotazione non trovata' using hint = 'nonc'; end if;
  if st is not null and st not in ('confermata', 'arrivati', 'noshow', 'annullata') then
    raise exception 'Stato non valido' using hint = 'stato';
  end if;
  begin
    n := (p_dati->>'persone')::int;
    s := (p_dati->>'sera')::date;
  exception when others then
    raise exception 'Dati non validi' using hint = 'dati';
  end;
  if n is not null and (n < 1 or n > 200) then raise exception 'Numero di persone non valido' using hint = 'persone'; end if;
  if t is not null and t !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Orario non valido' using hint = 'turno'; end if;
  update public.pren_prenotazioni set
    stato        = coalesce(st, stato),
    annullata    = case when st = 'annullata' and stato <> 'annullata' then now()
                        when st is not null and st <> 'annullata' then null else annullata end,
    annullata_da = case when st = 'annullata' and stato <> 'annullata' then 'titolare'
                        when st is not null and st <> 'annullata' then null else annullata_da end,
    persone      = coalesce(n, persone),
    sera         = coalesce(s, sera),
    turno        = coalesce(t, turno),
    nota         = coalesce(left(trim(p_dati->>'nota'), 300), nota)
   where id = p.id returning * into p;
  return public.pren_vista_titolare(p);
end $$;

create or replace function public.pren_impostazioni(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare imp public.pren_impostazioni;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into imp from public.pren_impostazioni where id = 1;
  return jsonb_build_object(
    'attive', imp.attive, 'turni', to_jsonb(imp.turni), 'coperti', imp.coperti, 'maxPersone', imp.max_persone,
    'giorniAvanti', imp.giorni_avanti, 'anticipoMin', imp.anticipo_min,
    'dateChiuse', (select coalesce(jsonb_agg(d order by d), '[]'::jsonb)
                     from unnest(imp.date_chiuse) d where d >= public.pren_oggi()),
    'giorniChiusura', (select to_jsonb(giorni_chiusura) from public.club_impostazioni where id = 1),
    'telefoni', (select count(*) from public.pren_push));
end $$;

create or replace function public.pren_salva_impostazioni(p_pin text, p_dati jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_turni text[];
  v_date  date[];
begin
  perform public.pr_controlla_pin(p_pin);
  if p_dati ? 'turni' then
    select array_agg(distinct x order by x) into v_turni from jsonb_array_elements_text(p_dati->'turni') x;
    if v_turni is null or array_length(v_turni, 1) > 4
       or exists (select 1 from unnest(v_turni) x where x !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$') then
      raise exception 'Turni non validi: da 1 a 4 orari' using hint = 'turni';
    end if;
  end if;
  if p_dati ? 'dateChiuse' then
    select coalesce(array_agg(distinct x::date order by x::date), '{}') into v_date
      from jsonb_array_elements_text(p_dati->'dateChiuse') x where x::date >= public.pren_oggi();
    if array_length(v_date, 1) > 60 then raise exception 'Troppe date chiuse' using hint = 'date'; end if;
  end if;
  update public.pren_impostazioni set
    attive        = coalesce((p_dati->>'attive')::boolean, attive),
    turni         = coalesce(v_turni, turni),
    coperti       = coalesce((p_dati->>'coperti')::int, coperti),
    max_persone   = coalesce((p_dati->>'maxPersone')::int, max_persone),
    giorni_avanti = coalesce((p_dati->>'giorniAvanti')::int, giorni_avanti),
    anticipo_min  = coalesce((p_dati->>'anticipoMin')::int, anticipo_min),
    date_chiuse   = coalesce(v_date, date_chiuse)
   where id = 1;
  return public.pren_impostazioni(p_pin);
exception when check_violation or invalid_text_representation or numeric_value_out_of_range
                    or invalid_datetime_format or datetime_field_overflow then
  raise exception 'Numeri non validi' using hint = 'numeri';
end $$;

-- notifiche sul telefono del titolare (al massimo 10 telefoni: i più vecchi escono)
create or replace function public.pren_salva_push(p_pin text, p_sub jsonb) returns int
language plpgsql volatile security definer set search_path = public as $$
declare ep text := p_sub->>'endpoint';
begin
  perform public.pr_controlla_pin(p_pin);
  if ep is null or ep !~ '^https://' or length(ep) > 1000 then raise exception 'Iscrizione non valida' using hint = 'push'; end if;
  insert into public.pren_push (endpoint, sub) values (ep, p_sub)
  on conflict (endpoint) do update set sub = excluded.sub, creato = now();
  delete from public.pren_push where endpoint in (select endpoint from public.pren_push order by creato desc offset 10);
  return (select count(*) from public.pren_push);
end $$;

create or replace function public.pren_togli_push(p_pin text, p_endpoint text) returns int
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  delete from public.pren_push where endpoint = p_endpoint;
  return (select count(*) from public.pren_push);
end $$;

-- prova: una notifica finta al titolare (usa l'ultima prenotazione, o niente se non ce ne sono)
create or replace function public.pren_prova_avviso(p_pin text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare id uuid;
begin
  perform public.pr_controlla_pin(p_pin);
  select p.id into id from public.pren_prenotazioni p order by creato desc limit 1;
  if id is null then return false; end if;
  insert into public.pren_avvisi (prenotazione, tipo) values (id, 'nuova');
  return true;
end $$;


-- ================= OROLOGIO =================
-- se la chiamata del sito alla funzione "pren-avvisa" non è partita, ci pensa questo giro
-- ogni 5 minuti (solo se c'è qualcosa in coda). Si può rieseguire: il lavoro viene sostituito.
select cron.schedule('pren-avvisa', '*/5 * * * *', $avvisa$
  select net.http_post(
    url     := 'https://agbvmhpktilpaoabjkre.supabase.co/functions/v1/pren-avvisa',
    body    := '{"azione":"invia"}'::jsonb,
    headers := '{"Content-Type":"application/json","apikey":"sb_publishable_2O5l8ZbQqGnwDXwxZnsZ2Q_0Mt1V8T7"}'::jsonb)
   where exists (select 1 from public.pren_avvisi where inviato is null);
$avvisa$);
