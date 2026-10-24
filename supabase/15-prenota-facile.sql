-- =============================================================================
-- PRENOTARE IN 20 SECONDI — si esegue DOPO 11-prenotazioni-orari.sql e 12-asporto.sql
-- · Per prenotare dal sito bastano nome e telefono: la prenotazione non iscrive più al Club.
--   Chi ha la tessera su quel telefono, o un numero già nel Club, resta riconosciuto.
-- · Cliente nuovo (numero mai visto: né prenotazioni né Club) = prosecco di benvenuto,
--   per le persone della prenotazione fino a benvenuto_max (4).
-- · WhatsApp di conferma: quando pren_impostazioni.whatsapp è acceso, ogni prenotazione dal
--   sito nasce con wa_stato = 'in_coda'; la funzione "whatsapp-invia" la manda e WhatsApp ci
--   dice se è stata consegnata e letta (= il numero è giusto). Vedi 16-whatsapp.sql.
-- · Nel Club (e nell'asporto) l'email diventa facoltativa: bastano nome, telefono e nascita.
-- Si può rieseguire: non cancella niente.
-- =============================================================================

-- ---------- tabelle ----------
alter table public.club_iscritti alter column email drop not null;

alter table public.pren_impostazioni
  add column if not exists benvenuto_max int not null default 4 check (benvenuto_max between 0 and 20),
  add column if not exists whatsapp boolean not null default false;    -- conferme WhatsApp accese

alter table public.pren_prenotazioni
  add column if not exists benvenuto int not null default 0,           -- prosecco di benvenuto: per quante persone
  add column if not exists wa_stato  text,                              -- in_coda, inviato, consegnato, letto, errore
  add column if not exists wa_id     text,                              -- il messaggio su WhatsApp
  add column if not exists wa_errore text,
  add column if not exists wa_quando timestamptz;
create index if not exists pren_prenotazioni_tel on public.pren_prenotazioni (telefono);
create index if not exists pren_prenotazioni_wa  on public.pren_prenotazioni (wa_id);
create index if not exists pren_prenotazioni_coda on public.pren_prenotazioni (wa_stato) where wa_stato = 'in_coda';


-- ---------- viste ----------
create or replace function public.pren_vista(p public.pren_prenotazioni) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('codice', p.codice, 'sera', p.sera, 'turno', p.turno, 'persone', p.persone,
                            'nome', p.nome, 'nota', p.nota, 'stato', p.stato, 'benvenuto', p.benvenuto,
                            'whatsapp', p.wa_stato)
$$;

create or replace function public.pren_vista_titolare(p public.pren_prenotazioni) returns jsonb
language sql stable set search_path = public as $$
  select public.pren_vista(p) || jsonb_build_object('id', p.id, 'telefono', p.telefono, 'fonte', p.fonte,
         'socio', p.iscritto is not null, 'iscritto', p.iscritto, 'creato', p.creato,
         'annullata', p.annullata, 'annullataDa', p.annullata_da, 'waErrore', p.wa_errore, 'waQuando', p.wa_quando)
$$;

revoke execute on function public.pren_vista(public.pren_prenotazioni)          from public, anon, authenticated;
revoke execute on function public.pren_vista_titolare(public.pren_prenotazioni) from public, anon, authenticated;

-- l'avviso al titolare dice anche se è un cliente nuovo (prosecco)
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
               case when p.benvenuto > 0 and a.tipo = 'nuova' then ' · 🥂 cliente nuovo: prosecco per ' || p.benvenuto else '' end ||
               case when p.nota <> '' and a.tipo = 'nuova' then ' · «' || left(p.nota, 60) || '»' else '' end)
      order by a.id) filter (where a.id is not null), '[]'::jsonb),
    'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', x.endpoint, 'sub', x.sub)) from public.pren_push x), '[]'::jsonb))
    from presi a join public.pren_prenotazioni p on p.id = a.prenotazione
$$;
revoke execute on function public.pren_prendi_avvisi(int) from public, anon, authenticated;
grant execute on function public.pren_prendi_avvisi(int) to service_role;


-- ================= CLUB: email facoltativa =================
create or replace function public.club_iscriviti(p_nome text, p_email text, p_telefono text, p_nascita text,
                                                 p_promo boolean, p_lingua text, p_dispositivo text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  n    text := left(trim(coalesce(p_nome, '')), 60);
  e    text := nullif(lower(trim(coalesce(p_email, ''))), '');
  t    text := public.club_telefono(p_telefono);
  disp text := left(coalesce(p_dispositivo, ''), 64);
  d    date;
  i    public.club_iscritti;
  pb   text;
begin
  if length(n) < 2 then raise exception 'Scrivi il tuo nome' using hint = 'nome'; end if;
  if e is not null and (length(e) > 120 or e !~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$') then
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
  if exists (select 1 from public.club_iscritti where telefono = t or (e is not null and lower(email) = e)) then
    raise exception 'Questa email o questo numero sono già nel Club' using hint = 'gia';
  end if;
  insert into public.club_iscritti (chiave, nome, email, telefono, nascita, promo, promo_quando, lingua, dispositivo)
  values (public.pr_casuale(24), n, e, t, d, coalesce(p_promo, false), case when p_promo then now() end,
          left(coalesce(nullif(trim(p_lingua), ''), 'it'), 5), disp)
  returning * into i;
  pb := (public.club_dai_benvenuto(i.id)).codice;
  perform public.club_dai_compleanno(i, public.pr_sera(now()));
  if e is not null and (select email_attive from public.club_impostazioni where id = 1) then
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


-- ================= PRENOTAZIONI DAL SITO =================

-- i posti liberi, come prima, e se la conferma arriva su WhatsApp
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
  return jsonb_build_object('attive', imp.attive, 'maxPersone', imp.max_persone, 'giorni', giorni,
                            'whatsapp', imp.whatsapp, 'benvenutoMax', imp.benvenuto_max);
end $$;

-- prenota: nome e telefono (email, nascita e promo non servono più: restano solo per i siti vecchi)
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
  v_nome text := left(trim(coalesce(p_nome, '')), 60);
  tel   text := public.club_telefono(p_telefono);
  ling  text := left(coalesce(nullif(trim(p_lingua), ''), 'it'), 5);
  benv  int  := 0;
  i     public.club_iscritti;
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
  if n > imp.coperti - public.pren_occupati_fascia(s, k) then
    raise exception 'Alle % è tutto pieno', t using hint = 'pieno';
  end if;

  -- chi prenota: la tessera del Club su questo telefono, oppure nome e telefono
  if coalesce(p_chiave, '') <> '' then
    select * into i from public.club_iscritti where chiave = p_chiave;
  end if;
  if i.id is not null then
    v_nome := i.nome;
    tel := i.telefono;
  else
    if length(v_nome) < 2 then raise exception 'Scrivi il tuo nome' using hint = 'nome'; end if;
    if tel is null then raise exception 'Numero di telefono non valido' using hint = 'telefono'; end if;
    select * into i from public.club_iscritti where telefono = tel;     -- già socio: va con la sua tessera
  end if;
  if exists (select 1 from public.pren_prenotazioni where telefono = tel and sera = s and stato = 'confermata') then
    raise exception 'Hai già una prenotazione per questa sera' using hint = 'doppia';
  end if;
  if (select count(*) from public.pren_prenotazioni
       where telefono = tel and stato = 'confermata' and sera >= oggi) >= 3 then
    raise exception 'Hai già 3 prenotazioni in arrivo: chiamaci' using hint = 'tante';
  end if;
  -- cliente nuovo (mai prenotato con questo numero e non è nel Club): prosecco di benvenuto
  if i.id is null and not exists (select 1 from public.pren_prenotazioni where telefono = tel and stato <> 'annullata') then
    benv := least(n, imp.benvenuto_max);
  end if;

  -- un turno alla volta: due prenotazioni nello stesso istante non possono superare i coperti
  perform pg_advisory_xact_lock(hashtext('pren:' || s || ':' || k));
  if n > imp.coperti - public.pren_occupati_fascia(s, k) then
    raise exception 'Alle % è tutto pieno', t using hint = 'pieno';
  end if;

  insert into public.pren_prenotazioni (codice, segreto, sera, turno, persone, nome, telefono, nota, fonte,
                                        iscritto, dispositivo, lingua, benvenuto, wa_stato)
  values (public.pren_nuovo_codice(), public.pr_casuale(24), s, t, n, v_nome, tel,
          left(trim(coalesce(p_nota, '')), 300), 'sito', i.id, disp, ling, benv,
          case when imp.whatsapp then 'in_coda' end)
  returning * into p;
  insert into public.pren_avvisi (prenotazione, tipo) values (p.id, 'nuova');
  return public.pren_vista(p) || jsonb_build_object('segreto', p.segreto, 'socio', i.id is not null,
                                                    'nuovo', false, 'chiave', null);
end $$;

-- dopo la prenotazione il cliente entra nel Club dal riquadro della conferma: la prenotazione va con la tessera
create or replace function public.pren_collega_club(p_segreto text, p_chiave text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare i public.club_iscritti;
begin
  select * into i from public.club_iscritti where chiave = p_chiave and coalesce(p_chiave, '') <> '';
  if i.id is null then return false; end if;
  update public.pren_prenotazioni set iscritto = i.id
   where segreto = p_segreto and coalesce(p_segreto, '') <> '' and iscritto is null and telefono = i.telefono;
  return found;
end $$;

grant execute on function public.pren_collega_club(text, text) to anon, authenticated;


-- ================= ASPORTO: email facoltativa, socio riconosciuto dal telefono =================
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

  -- chi ordina: la tessera su questo telefono, oppure un numero già nel Club, oppure entra nel Club
  if coalesce(p_chiave, '') <> '' then
    select * into i from public.club_iscritti where chiave = p_chiave;
  end if;
  if i.id is null then
    if tel is null then raise exception 'Numero di telefono non valido' using hint = 'telefono'; end if;
    if e <> '' and (length(e) > 120 or e !~ '^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$') then
      raise exception 'Email non valida' using hint = 'email';
    end if;
    select * into i from public.club_iscritti where telefono = tel;
    if i.id is null then
      nuovo := public.club_iscriviti(p_nome, p_email, p_telefono, p_nascita, p_promo, ling, disp);
      select * into i from public.club_iscritti where chiave = nuovo->>'chiave';
    end if;
  end if;
  if (select count(*) from public.asp_ordini
       where iscritto = i.id and sera = oggi and stato in ('ricevuto', 'preparazione', 'pronto')) >= 2 then
    raise exception 'Hai già 2 ordini in corso stasera: chiamaci' using hint = 'tanti';
  end if;

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
