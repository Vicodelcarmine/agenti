-- =============================================================================
-- ASPORTO: WHATSAPP AL CLIENTE (conferma dell'ordine e "è pronto" a chi lo chiede)
-- Si esegue DOPO 12-asporto.sql, 27-novita-prenotazioni.sql, 32-regalo-scadenza.sql e 36/37/38.
-- Idea del titolare 12/11/2026:
--  1. appena il cliente ordina dal sito gli arriva un WhatsApp dal numero del Vico, col
--     modello approvato "asporto_ricevuto" (categoria Utilità) e il tasto rapido OK:
--       "Ciao {{1}}, grazie per il tuo ordine d'asporto al Vico del Carmine! 🛍️
--        Codice {{2}}, ritiro alle {{3}} in Via Pisana 40/r. Paghi al ritiro.
--        Rispondi OK se vuoi un messaggio appena è pronto."
--     {{1}} = nome (la prima parola), {{2}} = codice, {{3}} = ora di ritiro.
--  2. se risponde (OK o qualsiasi cosa, tranne STOP) si apre la finestra di 24 ore di
--     WhatsApp: gli rispondiamo subito "Perfetto! 👍 …" (messaggio libero, gratis);
--  3. quando l'ordine viene segnato PRONTO (dal Sunmi o dal Banco), SOLO a chi ha risposto
--     arriva "🛍️ … il tuo ordine … è pronto!" (messaggio libero, gratis).
--  Se l'ordine è già ritirato o annullato, quello che è ancora in coda non parte.
--  Tutto passa dalla coda wa_uscita (tipo 'asporto', colonna ordine): chi ha scritto STOP
--  non riceve niente; ogni messaggio al massimo una volta per ordine.
-- INTERRUTTORE: asp_impostazioni.wa_ordini, SPENTO finché Meta non approva il modello
-- (si accende dall'app del Sunmi). Si può rieseguire: non cancella niente.
-- =============================================================================

alter table public.asp_impostazioni add column if not exists wa_ordini  boolean not null default false;
alter table public.asp_impostazioni add column if not exists wa_modello text    not null default 'asporto_ricevuto';

alter table public.wa_uscita add column if not exists ordine uuid references public.asp_ordini(id) on delete set null;
create index if not exists wa_uscita_ordine on public.wa_uscita (ordine) where ordine is not null;

alter table public.wa_uscita drop constraint if exists wa_uscita_tipo_check;
alter table public.wa_uscita add constraint wa_uscita_tipo_check
  check (tipo in ('prosecco', 'club', 'voto', 'grazie', 'basso', 'stop', 'start', 'risposta', 'campagna', 'scadenza', 'asporto'));


-- ---------- pezzi di servizio (non chiamabili da fuori) ----------

create or replace function public.asp_wa_nome(o public.asp_ordini) returns text
language sql immutable set search_path = public as $$
  select coalesce(nullif(initcap(split_part(trim(coalesce(o.nome, '')), ' ', 1)), ''), 'ciao')
$$;

-- i messaggi liberi (partono solo dentro le 24 ore dall'ultimo messaggio del cliente)
create or replace function public.asp_wa_testo(p_scopo text, o public.asp_ordini) returns text
language sql immutable set search_path = public as $$
  select case p_scopo
    when 'ok'     then 'Perfetto! 👍 Ti scriviamo qui appena il tuo ordine ' || o.codice || ' è pronto.'
    when 'pronto' then '🛍️ ' || public.asp_wa_nome(o) || ', il tuo ordine ' || o.codice || ' è pronto! '
                       || 'Ti aspettiamo al Vico del Carmine, Via Pisana 40/r. Paghi al ritiro.'
  end
$$;

-- mette in coda un messaggio libero per l'ordine (una volta sola per scopo)
create or replace function public.asp_wa_libero(o public.asp_ordini, p_scopo text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  if exists (select 1 from public.wa_uscita where ordine = o.id and tipo = 'asporto' and parametri->>'scopo' = p_scopo) then
    return false;
  end if;
  insert into public.wa_uscita (telefono, tipo, testo, parametri, lingua, ordine)
  values (o.telefono, 'asporto', public.asp_wa_testo(p_scopo, o), jsonb_build_object('scopo', p_scopo), 'it', o.id);
  return true;
end $$;

-- il cliente ha risposto al messaggio di questo ordine? (STOP non conta)
create or replace function public.asp_wa_ha_risposto(o public.asp_ordini) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from public.wa_uscita u
                  where u.ordine = o.id and u.tipo = 'asporto' and u.modello is not null
                    and u.stato in ('invio', 'inviato', 'consegnato', 'letto'))
     and exists (select 1 from public.wa_entrata e
                  where e.telefono = o.telefono and e.quando >= o.creato
                    and lower(regexp_replace(e.testo, '[^[:alnum:]]', '', 'g')) not in ('stop', 'basta', 'stopp'))
     and not exists (select 1 from public.wa_contatti c where c.telefono = o.telefono and c.stop)
$$;

-- chiama subito la funzione whatsapp-invia, con la stessa chiamata dell'orologio 'whatsapp-invia'
-- (parte dopo il salvataggio; se non riesce, ci pensa l'orologio entro 2 minuti)
create or replace function public.asp_sveglia_whatsapp() returns void
language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url     := 'https://agbvmhpktilpaoabjkre.supabase.co/functions/v1/whatsapp-invia',
    body    := '{"azione":"invia"}'::jsonb,
    headers := '{"Content-Type":"application/json","apikey":"sb_publishable_2O5l8ZbQqGnwDXwxZnsZ2Q_0Mt1V8T7"}'::jsonb);
exception when others then
  null;
end $$;


-- ---------- trigger sugli ordini: nuovo → conferma; PRONTO → "è pronto"; ritirato/annullato → stop ----------

create or replace function public.asp_wa_da_ordine() returns trigger
language plpgsql security definer set search_path = public as $$
declare imp public.asp_impostazioni;
begin
  begin
    if tg_op = 'INSERT' then
      select * into imp from public.asp_impostazioni where id = 1;
      if coalesce(imp.wa_ordini, false) and coalesce(new.telefono, '') <> '' and new.stato <> 'annullato' then
        insert into public.wa_uscita (telefono, tipo, modello, parametri, lingua, ordine)
        values (new.telefono, 'asporto', imp.wa_modello,
                jsonb_build_array(public.asp_wa_nome(new), new.codice, new.ritiro), 'it', new.id);
        perform public.asp_sveglia_whatsapp();
      end if;
    elsif new.stato = 'pronto' and old.stato is distinct from 'pronto' then
      if public.asp_wa_ha_risposto(new) and public.asp_wa_libero(new, 'pronto') then
        perform public.asp_sveglia_whatsapp();
      end if;
    elsif new.stato in ('ritirato', 'annullato') and old.stato is distinct from new.stato then
      update public.wa_uscita set stato = 'saltato', errore = 'ordine già ' || new.stato
       where ordine = new.id and tipo = 'asporto' and stato = 'in_coda';
    end if;
  exception when others then
    raise warning 'whatsapp asporto: % (ordine %)', sqlerrm, new.codice;
  end;
  return new;
end $$;

drop trigger if exists asp_wa_ordine on public.asp_ordini;
create trigger asp_wa_ordine after insert or update of stato on public.asp_ordini
  for each row execute function public.asp_wa_da_ordine();


-- ---------- trigger sui messaggi in arrivo: la prima risposta dopo la conferma ----------
-- (scatta dentro wa_ricevi; il webhook poi vede la coda e manda subito)

create or replace function public.asp_wa_da_risposta() returns trigger
language plpgsql security definer set search_path = public as $$
declare o public.asp_ordini;
begin
  begin
    if lower(regexp_replace(new.testo, '[^[:alnum:]]', '', 'g')) in ('stop', 'basta', 'stopp') then return new; end if;
    select a.* into o from public.asp_ordini a
     where a.telefono = new.telefono and a.sera = public.pren_oggi()
       and a.stato in ('ricevuto', 'preparazione', 'pronto') and a.creato <= new.quando
       and exists (select 1 from public.wa_uscita u where u.ordine = a.id and u.tipo = 'asporto' and u.modello is not null
                      and u.stato in ('invio', 'inviato', 'consegnato', 'letto'))
     order by a.creato desc limit 1;
    if o.id is null then return new; end if;
    if exists (select 1 from public.wa_uscita where ordine = o.id and tipo = 'asporto' and parametri->>'scopo' in ('ok', 'pronto')) then
      return new;                                            -- ha già avuto la risposta
    end if;
    perform public.asp_wa_libero(o, case when o.stato = 'pronto' then 'pronto' else 'ok' end);
  exception when others then
    raise warning 'whatsapp asporto (risposta): %', sqlerrm;
  end;
  return new;
end $$;

drop trigger if exists asp_wa_risposta on public.wa_entrata;
create trigger asp_wa_risposta after insert on public.wa_entrata
  for each row execute function public.asp_wa_da_risposta();

revoke execute on function public.asp_wa_nome(public.asp_ordini)               from public, anon, authenticated;
revoke execute on function public.asp_wa_testo(text, public.asp_ordini)        from public, anon, authenticated;
revoke execute on function public.asp_wa_libero(public.asp_ordini, text)       from public, anon, authenticated;
revoke execute on function public.asp_wa_ha_risposto(public.asp_ordini)        from public, anon, authenticated;
revoke execute on function public.asp_sveglia_whatsapp()                       from public, anon, authenticated;
revoke execute on function public.asp_wa_da_ordine()                           from public, anon, authenticated;
revoke execute on function public.asp_wa_da_risposta()                         from public, anon, authenticated;


-- ---------- l'interruttore, dall'app del Sunmi (password del menu) ----------

create or replace function public.asp_wa_ordini(pwd text, p_attivo boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare imp public.asp_impostazioni;
begin
  if public.verify_pw(pwd) is null then raise exception 'password non valida' using hint = 'password'; end if;
  if p_attivo is not null then
    update public.asp_impostazioni set wa_ordini = p_attivo where id = 1;
  end if;
  select * into imp from public.asp_impostazioni where id = 1;
  return jsonb_build_object('attivo', imp.wa_ordini, 'modello', imp.wa_modello,
    'stasera', (select jsonb_build_object(
                  'conferme', count(*) filter (where u.modello is not null and u.stato in ('inviato', 'consegnato', 'letto')),
                  'risposte', count(*) filter (where u.parametri->>'scopo' in ('ok', 'pronto')),
                  'errori',   count(*) filter (where u.stato = 'errore'))
                  from public.wa_uscita u join public.asp_ordini o on o.id = u.ordine
                 where u.tipo = 'asporto' and o.sera = public.pren_oggi()));
end $$;

grant execute on function public.asp_wa_ordini(text, boolean) to anon, authenticated;


-- ---------- controllo (non scrive niente) ----------
select (select wa_ordini from public.asp_impostazioni where id = 1)                              as interruttore_whatsapp,
       (select count(*) from pg_trigger where tgname in ('asp_wa_ordine', 'asp_wa_risposta') and not tgisinternal) as trigger_installati,
       public.asp_wa_testo('pronto', jsonb_populate_record(null::public.asp_ordini,
                           '{"nome":"mario rossi","codice":"K7QX"}'))                          as esempio_pronto;
