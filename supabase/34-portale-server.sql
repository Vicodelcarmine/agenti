-- =============================================================================
-- PORTALE CAPODANNOFIRENZE.IT LETTO DAL SERVER (si esegue DOPO 33-portale-deposito.sql)
-- Niente più Mac acceso: ogni ora l'orologio del database (cron "portale-capodanno") chiama
-- la funzione "portale-capodanno", che entra nel gestionale con nome utente e password del
-- titolare (segreti delle funzioni PORTALE_UTENTE e PORTALE_PASSWORD, li inserisce il titolare),
-- legge l'elenco e lo passa a pren_portale_elabora.
-- · pren_portale_elabora(righe, prova): quello che faceva pren_da_portale, senza chiave
--   (solo per le funzioni del server). pren_da_portale resta: controlla la chiave e chiama questa.
-- · portale_turno(segreto): la funzione parte solo se l'intestazione x-vico-portale è uguale a
--   portale_config.cron_segreto (creato qui, non esce dal database) e se non è partita negli
--   ultimi 2 minuti. Torna 'ok', 'segreto' o 'presto'.
-- · portale_segnala(esito, errore): annota l'esito; se qualcosa non va avvisa il titolare
--   (notifica e "Novità" del cruscotto) la prima volta e poi al massimo una volta ogni 20 ore.
-- Si può rieseguire.
-- =============================================================================

alter table public.portale_config
  add column if not exists cron_segreto     text,
  add column if not exists ultimo_tentativo timestamptz,
  add column if not exists errore           text,
  add column if not exists errore_avvisato  timestamptz;
update public.portale_config
   set cron_segreto = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
 where id = 1 and cron_segreto is null;

-- p_righe: [{ id, nome, cognome, locale, biglietto, persone, pagamento, stato, totale, acconto, saldo, telefono, note, note_pag }]
create or replace function public.pren_portale_elabora(p_righe jsonb, p_prova boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r      jsonb;
  ev     public.portale_eventi;
  pp     public.portale_pren;
  b      public.pren_prenotazioni;
  v_id   text;
  v_stato text;
  attiva boolean;
  n      int;
  v_nome text;
  tel    text;
  v_nota text;
  impr   text;
  c      jsonb := jsonb_build_object('nuove', 0, 'aggiornate', 0, 'annullate', 0, 'invariate', 0, 'in_attesa', 0, 'altri', 0, 'scartate', 0);
begin
  if p_righe is null or jsonb_typeof(p_righe) <> 'array' or jsonb_array_length(p_righe) > 1000 then
    raise exception 'Elenco non valido' using hint = 'righe';
  end if;

  for r in select * from jsonb_array_elements(p_righe) loop
    v_id := left(trim(coalesce(r->>'id', '')), 30);
    select * into ev from public.portale_eventi
     where lower(locale) = lower(trim(coalesce(r->>'locale', ''))) and lower(biglietto) = lower(trim(coalesce(r->>'biglietto', '')));
    if v_id = '' then c := jsonb_set(c, '{scartate}', to_jsonb((c->>'scartate')::int + 1)); continue; end if;
    if ev.locale is null then c := jsonb_set(c, '{altri}', to_jsonb((c->>'altri')::int + 1)); continue; end if;

    v_stato := trim(coalesce(r->>'stato', ''));
    attiva := v_stato in ('Confermata', 'In attesa di accredito');
    n := nullif(regexp_replace(coalesce(r->>'persone', ''), '[^0-9]', '', 'g'), '')::int;
    v_nome := left(trim(coalesce(r->>'nome', '') || ' ' || coalesce(r->>'cognome', '')), 60);
    if length(v_nome) < 2 then v_nome := 'Cliente portale'; end if;
    tel := trim(coalesce(r->>'telefono', ''));
    if tel <> '' then tel := coalesce(public.club_telefono(tel), ''); end if;
    v_nota := left('🎟️ capodannofirenze.it n. ' || v_id ||
              coalesce(' · ' || nullif(trim(r->>'pagamento'), ''), '') ||
              coalesce(' · acconto ' || nullif(trim(r->>'acconto'), ''), '') ||
              coalesce(' · saldo ' || nullif(trim(r->>'saldo'), ''), '') ||
              case when v_stato = 'In attesa di accredito' then ' · in attesa di accredito' else '' end ||
              coalesce(' · ' || nullif(trim(r->>'note'), ''), '') ||
              coalesce(' · ' || nullif(trim(r->>'note_pag'), ''), ''), 300);
    impr := md5(concat_ws('|', v_stato, n, v_nome, tel, v_nota, ev.sera, ev.turno));
    select * into pp from public.portale_pren where id_portale = v_id for update;

    if not attiva then
      if v_stato = 'Cancellata' and pp.prenotazione is not null and pp.stato is distinct from 'Cancellata' then
        update public.pren_prenotazioni set stato = 'annullata', annullata = now(), annullata_da = 'capodannofirenze'
         where id = pp.prenotazione and stato <> 'annullata' returning * into b;
        if b.id is not null then
          insert into public.pren_avvisi (prenotazione, tipo, titolo)
          values (b.id, 'annullata', '❌ Cancellata su capodannofirenze.it');
        end if;
        update public.portale_pren set stato = v_stato, impronta = impr, aggiornato = now() where id_portale = v_id;
        c := jsonb_set(c, '{annullate}', to_jsonb((c->>'annullate')::int + 1));
      elsif v_stato = 'Cancellata' then
        c := jsonb_set(c, '{invariate}', to_jsonb((c->>'invariate')::int + 1));
      else
        c := jsonb_set(c, '{in_attesa}', to_jsonb((c->>'in_attesa')::int + 1));   -- non ancora pagata: non conta
      end if;
      continue;
    end if;

    if n is null or n < 1 or n > 200 then c := jsonb_set(c, '{scartate}', to_jsonb((c->>'scartate')::int + 1)); continue; end if;

    if pp.id_portale is null or pp.prenotazione is null then
      insert into public.pren_prenotazioni (codice, sera, turno, persone, nome, telefono, nota, fonte, canale, iscritto)
      values (public.pren_nuovo_codice(), ev.sera, ev.turno, n, v_nome, tel, v_nota, 'altro', 'capodannofirenze',
              (select id from public.club_iscritti where telefono = tel and tel <> ''))
      returning * into b;
      insert into public.portale_pren (id_portale, prenotazione, stato, impronta) values (v_id, b.id, v_stato, impr)
      on conflict (id_portale) do update set prenotazione = excluded.prenotazione, stato = excluded.stato,
                                             impronta = excluded.impronta, aggiornato = now();
      insert into public.pren_avvisi (prenotazione, tipo, titolo, testo)
      values (b.id, 'nuova', '🎟️ Prenotazione da capodannofirenze.it',
              b.nome || ' · ' || public.club_persone(n, 'it') || ' · ' || public.club_data(ev.sera, 'it') || ' alle ' || ev.turno);
      c := jsonb_set(c, '{nuove}', to_jsonb((c->>'nuove')::int + 1));
    elsif pp.impronta is distinct from impr then
      update public.pren_prenotazioni
         set persone = n, nome = v_nome, telefono = tel, nota = v_nota,
             stato = case when stato = 'annullata' then 'confermata' else stato end,
             annullata = case when stato = 'annullata' then null else annullata end
       where id = pp.prenotazione;
      update public.portale_pren set stato = v_stato, impronta = impr, aggiornato = now() where id_portale = v_id;
      c := jsonb_set(c, '{aggiornate}', to_jsonb((c->>'aggiornate')::int + 1));
    else
      c := jsonb_set(c, '{invariate}', to_jsonb((c->>'invariate')::int + 1));
    end if;
  end loop;

  update public.portale_config set ultimo_invio = now(), ultimo_esito = c::text where id = 1;
  if p_prova then raise exception 'PROVA_OK %', c::text using hint = 'prova'; end if;
  return c || jsonb_build_object('ok', true);
end $$;
revoke execute on function public.pren_portale_elabora(jsonb, boolean) from public, anon, authenticated;
grant  execute on function public.pren_portale_elabora(jsonb, boolean) to service_role;

-- la strada con la chiave (attività sul Mac) resta, ma usa la stessa elaborazione
create or replace function public.pren_da_portale(p_chiave text, p_righe jsonb, p_prova boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare h text;
begin
  select chiave_hash into h from public.portale_config where id = 1;
  if h is null or coalesce(p_chiave, '') = '' or encode(sha256(convert_to(p_chiave, 'UTF8')), 'hex') <> h then
    raise exception 'Chiave non valida' using hint = 'chiave';
  end if;
  return public.pren_portale_elabora(p_righe, p_prova);
end $$;

create or replace function public.portale_turno(p_segreto text) returns text
language plpgsql volatile security definer set search_path = public as $$
declare k public.portale_config;
begin
  select * into k from public.portale_config where id = 1 for update;
  if k.cron_segreto is null or coalesce(p_segreto, '') <> k.cron_segreto then return 'segreto'; end if;
  if k.ultimo_tentativo > now() - interval '2 minutes' then return 'presto'; end if;
  update public.portale_config set ultimo_tentativo = now() where id = 1;
  return 'ok';
end $$;
revoke execute on function public.portale_turno(text) from public, anon, authenticated;
grant  execute on function public.portale_turno(text) to service_role;

create or replace function public.portale_segnala(p_esito jsonb, p_errore text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare k public.portale_config;
begin
  select * into k from public.portale_config where id = 1 for update;
  p_errore := nullif(left(trim(coalesce(p_errore, '')), 200), '');
  if p_errore is null then
    update public.portale_config set ultimo_invio = now(), ultimo_esito = coalesce(p_esito::text, ultimo_esito), errore = null where id = 1;
    return;
  end if;
  if k.errore is distinct from p_errore or k.errore_avvisato is null or k.errore_avvisato < now() - interval '20 hours' then
    -- senza prenotazione e di tipo "whatsapp": nelle Novità del cruscotto si vede solo titolo e testo
    insert into public.pren_avvisi (prenotazione, tipo, titolo, testo)
    values (null, 'whatsapp', '⚠️ Portale capodannofirenze.it', p_errore);
    update public.portale_config set errore_avvisato = now() where id = 1;
  end if;
  update public.portale_config set errore = p_errore, ultimo_esito = coalesce(p_esito::text, ultimo_esito) where id = 1;
end $$;
revoke execute on function public.portale_segnala(jsonb, text) from public, anon, authenticated;
grant  execute on function public.portale_segnala(jsonb, text) to service_role;

-- ogni ora (al minuto 17), fino al 1° gennaio 2027
select cron.unschedule(jobid) from cron.job where jobname = 'portale-capodanno';
select cron.schedule('portale-capodanno', '17 * * * *', $portale$
  select net.http_post(
    url     := 'https://agbvmhpktilpaoabjkre.supabase.co/functions/v1/portale-capodanno',
    body    := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'apikey', 'sb_publishable_2O5l8ZbQqGnwDXwxZnsZ2Q_0Mt1V8T7',
                                  'x-vico-portale', (select cron_segreto from public.portale_config where id = 1)),
    timeout_milliseconds := 120000)
   where current_date <= date '2027-01-01';
$portale$);
