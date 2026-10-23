-- =============================================================================
-- ASPORTO — ordini dal menu, ritiro al locale, pagamento al ritiro
-- Si esegue DOPO 10-prenotazioni.sql (usa pren_oggi e i dati del Club).
-- Il cliente apre il menu dal sito in modalità asporto (menu/?asporto=1), riempie lo
-- stesso carrello dell'ordine al tavolo, sceglie l'ora di ritiro di stasera e lascia
-- i dati del Club (chi è già socio viene riconosciuto). La cucina regge al massimo
-- N piatti per ogni quarto d'ora di ritiro (bevande e dolci non contano).
-- Gli ordini compaiono sul Banco (stessa password del menu) a parte dai tavoli:
-- ricevuto → in preparazione → pronto → ritirato. Il titolare regola tutto dalla
-- dashboard (scheda Prenota).
-- Tutto ha il prefisso asp_ : NON tocca ordini al tavolo, menu, agenti, prenotazioni.
-- Le tabelle non sono leggibili dall'esterno (RLS senza regole).
-- Si può rieseguire: non cancella niente.
-- =============================================================================

-- ---------- tabelle ----------
create table if not exists public.asp_impostazioni (
  id            int primary key default 1 check (id = 1),
  attive        boolean not null default true,
  dalle         text    not null default '19:00',         -- primo ritiro
  alle          text    not null default '22:30',         -- ultimo ritiro
  passo_min     int     not null default 15  check (passo_min in (10, 15, 20, 30)),
  piatti_slot   int     not null default 15  check (piatti_slot between 1 and 200),  -- per ogni orario di ritiro
  anticipo_min  int     not null default 30  check (anticipo_min between 0 and 240), -- tempo minimo per prepararlo
  giorni_no     int[]   not null default '{6}',            -- sere senza asporto (0 = domenica … 6 = sabato)
  non_contano   text[]  not null default '{dolci,birre,cocktail,bevande,vini}'  -- categorie fuori dal conto della cucina
);
insert into public.asp_impostazioni (id) values (1) on conflict (id) do nothing;

create table if not exists public.asp_ordini (
  id          uuid primary key default gen_random_uuid(),
  codice      text unique not null,          -- 4 caratteri: si dice al banco al ritiro
  segreto     text unique not null,          -- sta solo nel telefono del cliente (per seguirlo e annullarlo)
  sera        date not null,
  ritiro      text not null,                 -- "20:30"
  righe       jsonb not null,                -- [{id, nome, prezzo, qta, nota, categoria, slug}]
  pezzi       int  not null default 0,       -- piatti che contano per la cucina
  totale      numeric,                       -- calcolato dal menu: si incassa al ritiro
  nota        text not null default '',
  nome        text not null,
  telefono    text not null,
  iscritto    uuid references public.club_iscritti(id) on delete set null,
  stato       text not null default 'ricevuto'
              check (stato in ('ricevuto', 'preparazione', 'pronto', 'ritirato', 'annullato')),
  lingua      text not null default 'it',
  dispositivo text not null default '',
  creato      timestamptz not null default now(),
  visto       timestamptz,
  pronto      timestamptz,
  chiuso      timestamptz                    -- ritirato o annullato
);
create index if not exists asp_ordini_sera on public.asp_ordini (sera, ritiro);
create index if not exists asp_ordini_disp on public.asp_ordini (dispositivo, creato);

alter table public.asp_impostazioni enable row level security;
alter table public.asp_ordini       enable row level security;


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- gli orari di ritiro della sera: dalle … alle, uno ogni passo minuti
create or replace function public.asp_orari() returns text[]
language sql stable set search_path = public as $$
  select coalesce(array_agg(to_char(o.t, 'HH24:MI') order by o.t), '{}')
    from public.asp_impostazioni i,
         generate_series(('2000-01-01 ' || i.dalle)::timestamp, ('2000-01-01 ' || i.alle)::timestamp,
                         make_interval(mins => i.passo_min)) o(t)
   where i.id = 1
$$;

-- stasera c'è l'asporto? (interruttore, sere senza asporto, giorno di chiusura del Club)
create or replace function public.asp_aperto(s date) returns boolean
language sql stable set search_path = public as $$
  select i.attive
     and not (extract(dow from s)::int = any(i.giorni_no))
     and not (extract(dow from s)::int = any(coalesce((select giorni_chiusura from public.club_impostazioni where id = 1), '{}'::int[])))
    from public.asp_impostazioni i where i.id = 1
$$;

-- piatti già presi per un orario di ritiro
create or replace function public.asp_occupati(s date, r text) returns int
language sql stable set search_path = public as $$
  select coalesce(sum(pezzi), 0)::int from public.asp_ordini
   where sera = s and ritiro = r and stato <> 'annullato'
$$;

create or replace function public.asp_vista(o public.asp_ordini) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('codice', o.codice, 'sera', o.sera, 'ritiro', o.ritiro, 'righe', o.righe,
                            'totale', o.totale, 'nota', o.nota, 'nome', o.nome, 'stato', o.stato,
                            'creato', o.creato, 'pronto', o.pronto)
$$;

create or replace function public.asp_nuovo_codice(s date) returns text
language plpgsql volatile set search_path = public as $$
declare c text;
begin
  loop
    c := public.pr_casuale(4);
    exit when not exists (select 1 from public.asp_ordini where codice = c);
  end loop;
  return c;
end $$;

revoke execute on function public.asp_orari()                      from public, anon, authenticated;
revoke execute on function public.asp_aperto(date)                 from public, anon, authenticated;
revoke execute on function public.asp_occupati(date, text)         from public, anon, authenticated;
revoke execute on function public.asp_vista(public.asp_ordini)     from public, anon, authenticated;
revoke execute on function public.asp_nuovo_codice(date)           from public, anon, authenticated;


-- ================= CLIENTE (menu in modalità asporto) =================

-- stasera: aperto o no, e gli orari di ritiro con quanti piatti si possono ancora ordinare
create or replace function public.asp_info() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  imp   public.asp_impostazioni;
  oggi  date := public.pren_oggi();
  r     text;
  liste jsonb := '[]'::jsonb;
  liberi int;
begin
  select * into imp from public.asp_impostazioni where id = 1;
  foreach r in array public.asp_orari() loop
    -- gli orari che non facciamo più in tempo a preparare non si mostrano proprio
    continue when public.pren_inizio(oggi, r) - make_interval(mins => imp.anticipo_min) < now();
    if not public.asp_aperto(oggi) then
      liberi := 0;
    else
      liberi := greatest(0, imp.piatti_slot - public.asp_occupati(oggi, r));
    end if;
    liste := liste || jsonb_build_object('ora', r, 'liberi', liberi);
  end loop;
  return jsonb_build_object('attive', imp.attive, 'aperto', public.asp_aperto(oggi), 'sera', oggi,
                            'dalle', imp.dalle, 'alle', imp.alle, 'orari', liste,
                            'nonContano', to_jsonb(imp.non_contano));
end $$;

-- un ordine nuovo. Le righe arrivano dal carrello del menu; il totale è quello del menu
-- e si paga al ritiro. Chi è riconosciuto (chiave del Club su questo telefono, oppure
-- telefono + email di un iscritto) ordina e basta; gli altri entrano nel Club.
create or replace function public.asp_nuovo(p_ritiro text, p_righe jsonb, p_totale numeric, p_nota text,
                                            p_chiave text, p_nome text, p_email text, p_telefono text,
                                            p_nascita text, p_promo boolean, p_lingua text,
                                            p_dispositivo text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  imp   public.asp_impostazioni;
  oggi  date := public.pren_oggi();
  r     text := trim(coalesce(p_ritiro, ''));
  disp  text := left(coalesce(p_dispositivo, ''), 64);
  e     text := lower(trim(coalesce(p_email, '')));
  tel   text := public.club_telefono(p_telefono);
  ling  text := left(coalesce(nullif(trim(p_lingua), ''), 'it'), 5);
  righe jsonb;
  pezzi int;
  i     public.club_iscritti;
  nuovo jsonb;
  o     public.asp_ordini;
begin
  select * into imp from public.asp_impostazioni where id = 1;
  if not public.asp_aperto(oggi) then raise exception 'Stasera l''asporto è chiuso' using hint = 'chiuso'; end if;
  if not (r = any(public.asp_orari())) then raise exception 'Orario di ritiro non valido' using hint = 'ritiro'; end if;
  if public.pren_inizio(oggi, r) - make_interval(mins => imp.anticipo_min) < now() then
    raise exception 'Per le % non facciamo più in tempo: scegli un orario più tardi', r using hint = 'tardi';
  end if;

  -- le righe: solo i campi che servono, lunghezze limitate
  if jsonb_typeof(p_righe) is distinct from 'array' or jsonb_array_length(p_righe) < 1 or jsonb_array_length(p_righe) > 60 then
    raise exception 'Il carrello è vuoto' using hint = 'vuoto';
  end if;
  select jsonb_agg(jsonb_build_object(
           'id', left(coalesce(x.v->>'id', ''), 80), 'nome', left(coalesce(x.v->>'nome', ''), 80),
           'prezzo', x.v->'prezzo', 'qta', greatest(1, least(30, coalesce((x.v->>'qta')::int, 1))),
           'nota', left(coalesce(x.v->>'nota', ''), 120), 'categoria', left(coalesce(x.v->>'categoria', ''), 40),
           'slug', left(coalesce(x.v->>'slug', ''), 40))),
         coalesce(sum(greatest(1, least(30, coalesce((x.v->>'qta')::int, 1))))
                  filter (where not (coalesce(x.v->>'slug', '') = any(imp.non_contano))), 0)
    into righe, pezzi
    from jsonb_array_elements(p_righe) x(v);
  if pezzi > imp.piatti_slot then
    raise exception 'Per un ordine così grande chiamaci' using hint = 'grande';
  end if;

  if (disp <> '' and (select count(*) from public.asp_ordini
                       where dispositivo = disp and creato > now() - interval '1 day') >= 5)
     or (select count(*) from public.asp_ordini where creato > now() - interval '1 day') >= 200 then
    raise exception 'Troppi ordini: chiamaci' using hint = 'troppi';
  end if;
  if pezzi > imp.piatti_slot - public.asp_occupati(oggi, r) then
    raise exception 'Alle % la cucina è piena: scegli un altro orario', r using hint = 'pieno';
  end if;

  -- chi ordina
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
  if (select count(*) from public.asp_ordini
       where iscritto = i.id and sera = oggi and stato in ('ricevuto', 'preparazione', 'pronto')) >= 2 then
    raise exception 'Hai già 2 ordini in corso stasera: chiamaci' using hint = 'tanti';
  end if;

  -- un orario alla volta: due ordini nello stesso istante non possono superare la cucina
  perform pg_advisory_xact_lock(hashtext('asp:' || oggi || ':' || r));
  if pezzi > imp.piatti_slot - public.asp_occupati(oggi, r) then
    raise exception 'Alle % la cucina è piena: scegli un altro orario', r using hint = 'pieno';
  end if;

  insert into public.asp_ordini (codice, segreto, sera, ritiro, righe, pezzi, totale, nota, nome, telefono,
                                 iscritto, lingua, dispositivo)
  values (public.asp_nuovo_codice(oggi), public.pr_casuale(24), oggi, r, righe, pezzi,
          case when p_totale between 0 and 100000 then round(p_totale, 2) end,
          left(trim(coalesce(p_nota, '')), 300), i.nome, i.telefono, i.id, ling, disp)
  returning * into o;
  return public.asp_vista(o) || jsonb_build_object('segreto', o.segreto, 'nuovo', nuovo is not null,
                                                   'chiave', nuovo->>'chiave');
end $$;

-- il cliente segue il suo ordine
create or replace function public.asp_ordine(p_segreto text) returns jsonb
language sql stable security definer set search_path = public as $$
  select public.asp_vista(o) from public.asp_ordini o where o.segreto = p_segreto and coalesce(p_segreto, '') <> ''
$$;

-- il cliente annulla, finché la cucina non l'ha preso in carico
create or replace function public.asp_annulla(p_segreto text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare o public.asp_ordini;
begin
  select * into o from public.asp_ordini where segreto = p_segreto and coalesce(p_segreto, '') <> '' for update;
  if o.id is null then raise exception 'Ordine non trovato' using hint = 'nonc'; end if;
  if o.stato <> 'ricevuto' then raise exception 'È già in preparazione: chiamaci' using hint = 'stato'; end if;
  update public.asp_ordini set stato = 'annullato', chiuso = now() where id = o.id returning * into o;
  return public.asp_vista(o);
end $$;


-- ================= BANCO (password del menu, come gli ordini al tavolo) =================

-- gli ordini di stasera (anche quelli chiusi, per il conto della serata)
create or replace function public.asp_aperti(pwd text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if public.verify_pw(pwd) is null then raise exception 'password non valida'; end if;
  return coalesce((select jsonb_agg(public.asp_vista(o) || jsonb_build_object('id', o.id, 'telefono', o.telefono,
                                    'pezzi', o.pezzi, 'socio', o.iscritto is not null, 'visto', o.visto)
                                    order by o.ritiro, o.creato)
                     from public.asp_ordini o where o.sera = public.pren_oggi()), '[]'::jsonb);
end $$;

create or replace function public.asp_segna(p_id uuid, p_stato text, pwd text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare o public.asp_ordini;
begin
  if public.verify_pw(pwd) is null then raise exception 'password non valida'; end if;
  if p_stato not in ('ricevuto', 'preparazione', 'pronto', 'ritirato', 'annullato') then
    raise exception 'stato non valido';
  end if;
  update public.asp_ordini set
    stato  = p_stato,
    visto  = case when p_stato = 'preparazione' then coalesce(visto, now()) else visto end,
    pronto = case when p_stato = 'pronto' then now() when p_stato in ('ricevuto', 'preparazione') then null else pronto end,
    chiuso = case when p_stato in ('ritirato', 'annullato') then now() else null end
   where id = p_id returning * into o;
  if o.id is null then raise exception 'ordine non trovato'; end if;
  return public.asp_vista(o) || jsonb_build_object('id', o.id);
end $$;


-- ================= TITOLARE (dashboard, col PIN) =================

create or replace function public.asp_impostazioni(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare imp public.asp_impostazioni;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into imp from public.asp_impostazioni where id = 1;
  return jsonb_build_object(
    'attive', imp.attive, 'dalle', imp.dalle, 'alle', imp.alle, 'passo', imp.passo_min,
    'piatti', imp.piatti_slot, 'anticipoMin', imp.anticipo_min, 'giorniNo', to_jsonb(imp.giorni_no),
    'nonContano', to_jsonb(imp.non_contano), 'orari', to_jsonb(public.asp_orari()),
    'stasera', (select jsonb_build_object(
                  'ordini', count(*) filter (where stato <> 'annullato'),
                  'piatti', coalesce(sum(pezzi) filter (where stato <> 'annullato'), 0),
                  'incasso', coalesce(sum(totale) filter (where stato <> 'annullato'), 0),
                  'aperti', count(*) filter (where stato in ('ricevuto', 'preparazione', 'pronto')))
                  from public.asp_ordini where sera = public.pren_oggi()),
    'apertoStasera', public.asp_aperto(public.pren_oggi()));
end $$;

create or replace function public.asp_salva_impostazioni(p_pin text, p_dati jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  ora   text := '^([01][0-9]|2[0-3]):[0-5][0-9]$';
  v_no  int[];
begin
  perform public.pr_controlla_pin(p_pin);
  if (p_dati ? 'dalle' and coalesce(p_dati->>'dalle', '') !~ ora) or (p_dati ? 'alle' and coalesce(p_dati->>'alle', '') !~ ora)
     or coalesce(p_dati->>'dalle', (select dalle from public.asp_impostazioni where id = 1))
        > coalesce(p_dati->>'alle', (select alle from public.asp_impostazioni where id = 1)) then
    raise exception 'Orari non validi: il primo ritiro deve venire prima dell''ultimo' using hint = 'orari';
  end if;
  if p_dati ? 'giorniNo' then
    select coalesce(array_agg(distinct g order by g), '{}') into v_no
      from (select (x)::int as g from jsonb_array_elements_text(p_dati->'giorniNo') x) z where g between 0 and 6;
  end if;
  update public.asp_impostazioni set
    attive       = coalesce((p_dati->>'attive')::boolean, attive),
    dalle        = coalesce(p_dati->>'dalle', dalle),
    alle         = coalesce(p_dati->>'alle', alle),
    passo_min    = coalesce((p_dati->>'passo')::int, passo_min),
    piatti_slot  = coalesce((p_dati->>'piatti')::int, piatti_slot),
    anticipo_min = coalesce((p_dati->>'anticipoMin')::int, anticipo_min),
    giorni_no    = coalesce(v_no, giorni_no)
   where id = 1;
  return public.asp_impostazioni(p_pin);
exception when check_violation or invalid_text_representation or numeric_value_out_of_range then
  raise exception 'Numeri non validi' using hint = 'numeri';
end $$;

grant execute on function
  public.asp_info(), public.asp_nuovo(text, jsonb, numeric, text, text, text, text, text, text, boolean, text, text),
  public.asp_ordine(text), public.asp_annulla(text),
  public.asp_aperti(text), public.asp_segna(uuid, text, text),
  public.asp_impostazioni(text), public.asp_salva_impostazioni(text, jsonb)
to anon, authenticated;
