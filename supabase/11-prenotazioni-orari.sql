-- =============================================================================
-- PRENOTAZIONI — orari di arrivo liberi, coperti per turno
-- Si esegue DOPO 10-prenotazioni.sql.
-- Il cliente non sceglie più "il turno delle 19:30 o delle 21:30" ma l'ora in cui arriva
-- (19:00, 19:30, 20:00, 20:30…). Ogni ora appartiene a un turno (es. 19:00–20:30 il primo,
-- 21:00–22:30 il secondo) e i coperti si contano per turno: chi arriva alle 20:30 non
-- teme di dover lasciare il tavolo alle 21:30, e la sala non si riempie oltre il previsto.
-- La colonna "turno" delle prenotazioni ora contiene l'ora di arrivo ("20:30").
-- Si può rieseguire: non cancella niente.
-- =============================================================================

alter table public.pren_impostazioni add column if not exists
  fasce jsonb not null default '[{"dalle":"19:00","alle":"20:30"},{"dalle":"21:00","alle":"22:30"}]';
alter table public.pren_impostazioni add column if not exists
  passo_min int not null default 30 check (passo_min in (15, 30, 60));


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- gli orari che il cliente può scegliere: dentro ogni turno, uno ogni "passo" minuti
create or replace function public.pren_orari() returns text[]
language sql stable set search_path = public as $$
  select coalesce(array_agg(to_char(o.t, 'HH24:MI') order by o.t), '{}')
    from public.pren_impostazioni i,
         jsonb_array_elements(i.fasce) f(v),
         generate_series(('2000-01-01 ' || (f.v->>'dalle'))::timestamp, ('2000-01-01 ' || (f.v->>'alle'))::timestamp,
                         make_interval(mins => i.passo_min)) o(t)
   where i.id = 1
$$;

-- il turno (1, 2, …) a cui appartiene un'ora di arrivo; null = fuori dai turni
create or replace function public.pren_fascia(t text) returns int
language sql stable set search_path = public as $$
  select k::int from public.pren_impostazioni i, jsonb_array_elements(i.fasce) with ordinality f(v, k)
   where i.id = 1 and t >= f.v->>'dalle' and t <= f.v->>'alle'
   order by k limit 1
$$;

-- coperti già presi in un turno (tutte le ore di arrivo di quel turno, anche quelle messe a mano)
create or replace function public.pren_occupati_fascia(s date, k int) returns int
language sql stable set search_path = public as $$
  select coalesce(sum(p.persone), 0)::int
    from public.pren_prenotazioni p, public.pren_impostazioni i
   where i.id = 1 and p.sera = s and p.stato in ('confermata', 'arrivati')
     and p.turno >= i.fasce->(k - 1)->>'dalle' and p.turno <= i.fasce->(k - 1)->>'alle'
$$;

revoke execute on function public.pren_orari()                      from public, anon, authenticated;
revoke execute on function public.pren_fascia(text)                 from public, anon, authenticated;
revoke execute on function public.pren_occupati_fascia(date, int)   from public, anon, authenticated;


-- ================= CLIENTE (sito) =================

-- per ogni sera gli orari di arrivo, con i posti liberi del loro turno (al massimo quanti se ne
-- possono prenotare insieme). La chiave resta "turni" per il sito: ogni voce è un orario.
create or replace function public.pren_disponibilita() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  imp    public.pren_impostazioni;
  oggi   date := public.pren_oggi();
  orari  text[] := public.pren_orari();
  s      date;
  t      text;
  k      int;
  liberi int;
  liste  jsonb;
  giorni jsonb := '[]'::jsonb;
begin
  select * into imp from public.pren_impostazioni where id = 1;
  for i in 0 .. imp.giorni_avanti loop
    s := oggi + i;
    liste := '[]'::jsonb;
    foreach t in array orari loop
      k := public.pren_fascia(t);
      if not imp.attive or public.pren_chiuso(s)
         or public.pren_inizio(s, t) - make_interval(mins => imp.anticipo_min) < now() then
        liberi := 0;
      else
        liberi := least(imp.max_persone, greatest(0, imp.coperti - public.pren_occupati_fascia(s, k)));
      end if;
      liste := liste || jsonb_build_object('ora', t, 'liberi', liberi, 'fascia', k);
    end loop;
    giorni := giorni || jsonb_build_object('sera', s, 'chiuso', public.pren_chiuso(s), 'turni', liste);
  end loop;
  return jsonb_build_object('attive', imp.attive, 'maxPersone', imp.max_persone, 'giorni', giorni);
end $$;

-- prenota: come prima, ma l'ora è quella di arrivo e i coperti si contano sul suo turno
create or replace function public.pren_prenota(p_sera text, p_turno text, p_persone int, p_nota text, p_chiave text,
                                               p_nome text, p_email text, p_telefono text, p_nascita text,
                                               p_promo boolean, p_lingua text, p_dispositivo text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  imp   public.pren_impostazioni;
  oggi  date := public.pren_oggi();
  s     date;
  t     text := trim(coalesce(p_turno, ''));
  k     int;
  n     int  := coalesce(p_persone, 0);
  disp  text := left(coalesce(p_dispositivo, ''), 64);
  e     text := lower(trim(coalesce(p_email, '')));
  tel   text := public.club_telefono(p_telefono);
  ling  text := left(coalesce(nullif(trim(p_lingua), ''), 'it'), 5);
  i     public.club_iscritti;
  nuovo jsonb;
  p     public.pren_prenotazioni;
begin
  select * into imp from public.pren_impostazioni where id = 1;
  if not imp.attive then raise exception 'Le prenotazioni online sono chiuse: chiamaci' using hint = 'chiuse'; end if;
  begin
    s := p_sera::date;
  exception when others then
    s := null;
  end;
  if s is null or not (t = any(public.pren_orari())) then raise exception 'Sera o orario non validi' using hint = 'turno'; end if;
  k := public.pren_fascia(t);
  if s < oggi or s > oggi + imp.giorni_avanti or public.pren_chiuso(s) then
    raise exception 'Quella sera non si può prenotare' using hint = 'sera';
  end if;
  if public.pren_inizio(s, t) - make_interval(mins => imp.anticipo_min) < now() then
    raise exception 'È tardi per prenotare online questo orario: chiamaci' using hint = 'tardi';
  end if;
  if n < 1 then raise exception 'Quante persone siete?' using hint = 'persone'; end if;
  if n > imp.max_persone then raise exception 'Per gruppi più grandi chiamaci' using hint = 'gruppo'; end if;
  if (disp <> '' and (select count(*) from public.pren_prenotazioni
                       where dispositivo = disp and creato > now() - interval '1 day') >= 5)
     or (select count(*) from public.pren_prenotazioni
          where fonte = 'sito' and creato > now() - interval '1 day') >= 300 then
    raise exception 'Troppe prenotazioni: chiamaci' using hint = 'troppe';
  end if;
  -- c'è ancora posto nel turno? (si ricontrolla sotto, col lucchetto, prima di scrivere)
  if n > imp.coperti - public.pren_occupati_fascia(s, k) then
    raise exception 'Alle % è tutto pieno', t using hint = 'pieno';
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
  perform pg_advisory_xact_lock(hashtext('pren:' || s || ':' || k));
  if n > imp.coperti - public.pren_occupati_fascia(s, k) then
    raise exception 'Alle % è tutto pieno', t using hint = 'pieno';
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


-- ================= TITOLARE (dashboard, col PIN) =================

-- una sera divisa per turni (con le ore di arrivo dentro), più le ore fuori dai turni
-- (messe a mano) e il riepilogo dei prossimi 14 giorni
create or replace function public.pren_giorno(p_pin text, p_sera text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  imp   public.pren_impostazioni;
  oggi  date := public.pren_oggi();
  s     date;
  f     jsonb;
  k     int := 0;
  turni jsonb := '[]'::jsonb;
  fuori jsonb;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into imp from public.pren_impostazioni where id = 1;
  begin
    s := coalesce(nullif(p_sera, '')::date, oggi);
  exception when others then
    s := oggi;
  end;
  for f in select * from jsonb_array_elements(imp.fasce) loop
    k := k + 1;
    turni := turni || jsonb_build_object(
      'ora', (f->>'dalle') || ' – ' || (f->>'alle'), 'dalle', f->>'dalle', 'alle', f->>'alle', 'numero', k,
      'prenotati', public.pren_occupati_fascia(s, k), 'previsto', true,
      'lista', coalesce((select jsonb_agg(public.pren_vista_titolare(p)
                                          order by (p.stato = 'annullata'), p.turno, p.creato)
                           from public.pren_prenotazioni p
                          where p.sera = s and p.turno >= f->>'dalle' and p.turno <= f->>'alle'), '[]'::jsonb));
  end loop;
  select jsonb_agg(public.pren_vista_titolare(p) order by (p.stato = 'annullata'), p.turno, p.creato) into fuori
    from public.pren_prenotazioni p where p.sera = s and public.pren_fascia(p.turno) is null;
  if fuori is not null then
    turni := turni || jsonb_build_object('ora', 'Altri orari', 'previsto', false,
      'prenotati', (select coalesce(sum(x.persone), 0) from public.pren_prenotazioni x
                     where x.sera = s and x.stato in ('confermata', 'arrivati') and public.pren_fascia(x.turno) is null),
      'lista', fuori);
  end if;
  return jsonb_build_object(
    'sera', s, 'oggi', oggi, 'coperti', imp.coperti, 'chiuso', public.pren_chiuso(s), 'turni', turni,
    'prossimi', (select coalesce(jsonb_agg(jsonb_build_object(
                    'sera', d, 'chiuso', public.pren_chiuso(d),
                    'prenotazioni', (select count(*) from public.pren_prenotazioni
                                      where sera = d and stato in ('confermata', 'arrivati')),
                    'persone', (select coalesce(sum(persone), 0) from public.pren_prenotazioni
                                 where sera = d and stato in ('confermata', 'arrivati'))) order by d), '[]'::jsonb)
                   from (select oggi + j as d from generate_series(0, 13) j) g),
    'nuove', (select count(*) from public.pren_prenotazioni
               where fonte = 'sito' and creato > now() - interval '1 day' and stato = 'confermata'));
end $$;

create or replace function public.pren_impostazioni(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare imp public.pren_impostazioni;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into imp from public.pren_impostazioni where id = 1;
  return jsonb_build_object(
    'attive', imp.attive, 'fasce', imp.fasce, 'passo', imp.passo_min, 'orari', to_jsonb(public.pren_orari()),
    'coperti', imp.coperti, 'maxPersone', imp.max_persone,
    'giorniAvanti', imp.giorni_avanti, 'anticipoMin', imp.anticipo_min,
    'dateChiuse', (select coalesce(jsonb_agg(d order by d), '[]'::jsonb)
                     from unnest(imp.date_chiuse) d where d >= public.pren_oggi()),
    'giorniChiusura', (select to_jsonb(giorni_chiusura) from public.club_impostazioni where id = 1),
    'telefoni', (select count(*) from public.pren_push));
end $$;

-- i turni sono fasce di orari di arrivo ("dalle"–"alle"), da 1 a 4, in ordine e senza sovrapporsi
create or replace function public.pren_salva_impostazioni(p_pin text, p_dati jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_fasce jsonb;
  v_date  date[];
  ora     text := '^([01][0-9]|2[0-3]):[0-5][0-9]$';
begin
  perform public.pr_controlla_pin(p_pin);
  if p_dati ? 'fasce' then
    select jsonb_agg(jsonb_build_object('dalle', x.v->>'dalle', 'alle', x.v->>'alle') order by x.v->>'dalle') into v_fasce
      from jsonb_array_elements(p_dati->'fasce') x(v);
    if v_fasce is null or jsonb_array_length(v_fasce) > 4
       or exists (select 1 from jsonb_array_elements(v_fasce) x(v)
                   where coalesce(x.v->>'dalle', '') !~ ora or coalesce(x.v->>'alle', '') !~ ora or x.v->>'dalle' > x.v->>'alle')
       or exists (select 1 from jsonb_array_elements(v_fasce) with ordinality a(x, n)
                    join jsonb_array_elements(v_fasce) with ordinality b(y, m) on m = n + 1
                   where a.x->>'alle' >= b.y->>'dalle') then
      raise exception 'Turni non validi: da 1 a 4, con l''ora di inizio prima della fine e senza sovrapporsi'
        using hint = 'turni';
    end if;
  end if;
  if p_dati ? 'dateChiuse' then
    select coalesce(array_agg(distinct x::date order by x::date), '{}') into v_date
      from jsonb_array_elements_text(p_dati->'dateChiuse') x where x::date >= public.pren_oggi();
    if array_length(v_date, 1) > 60 then raise exception 'Troppe date chiuse' using hint = 'date'; end if;
  end if;
  update public.pren_impostazioni set
    attive        = coalesce((p_dati->>'attive')::boolean, attive),
    fasce         = coalesce(v_fasce, fasce),
    passo_min     = coalesce((p_dati->>'passo')::int, passo_min),
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
