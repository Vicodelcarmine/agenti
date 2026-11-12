-- =============================================================================
-- ASPORTO: WHATSAPP AL CLIENTE QUANDO L'ORDINE È PRONTO
-- Si esegue DOPO 12-asporto.sql, 32-regalo-scadenza.sql e 36/37/38 (stampante).
-- Richiesta del titolare 12/11/2026: chi ordina dal sito lascia il telefono; quando
-- l'ordine viene segnato PRONTO (dal Sunmi o dal Banco) gli arriva un WhatsApp dal
-- numero del Vico con il modello approvato "asporto_pronto" (categoria Utilità):
--   "Ciao {{1}}, il tuo ordine d'asporto {{2}} è pronto! 🛍️
--    Ti aspettiamo al Vico del Carmine, Via Pisana 40/r, Firenze. Paghi al ritiro."
--   {{1}} = il nome (la prima parola), {{2}} = il codice dell'ordine.
-- Passa dalla coda wa_uscita (tipo 'asporto') come gli altri messaggi: chi ha
-- scritto STOP non lo riceve; ogni ordine al massimo un messaggio; se l'ordine è già
-- ritirato o annullato prima che parta, non parte.
-- INTERRUTTORE: asp_impostazioni.wa_pronto, SPENTO finché Meta non approva il modello
-- (si accende dall'app del Sunmi). Si può rieseguire: non cancella niente.
-- =============================================================================

alter table public.asp_impostazioni add column if not exists wa_pronto  boolean not null default false;
alter table public.asp_impostazioni add column if not exists wa_modello text    not null default 'asporto_pronto';

alter table public.wa_uscita add column if not exists ordine uuid references public.asp_ordini(id) on delete set null;
create index if not exists wa_uscita_ordine on public.wa_uscita (ordine) where ordine is not null;

alter table public.wa_uscita drop constraint if exists wa_uscita_tipo_check;
alter table public.wa_uscita add constraint wa_uscita_tipo_check
  check (tipo in ('prosecco', 'club', 'voto', 'grazie', 'basso', 'stop', 'start', 'risposta', 'campagna', 'scadenza', 'asporto'));


-- ---------- il trigger: PRONTO → messaggio in coda; RITIRATO/ANNULLATO prima dell'invio → non parte ----------

create or replace function public.asp_avvisa_pronto() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  imp  public.asp_impostazioni;
  nome text;
begin
  begin
    if new.stato = 'pronto' and old.stato is distinct from 'pronto' then
      select * into imp from public.asp_impostazioni where id = 1;
      if coalesce(imp.wa_pronto, false)
         and coalesce(new.telefono, '') <> ''
         and not exists (select 1 from public.wa_uscita where ordine = new.id and tipo = 'asporto') then
        nome := initcap(split_part(trim(coalesce(new.nome, '')), ' ', 1));
        insert into public.wa_uscita (telefono, tipo, modello, parametri, lingua, ordine)
        values (new.telefono, 'asporto', imp.wa_modello,
                jsonb_build_array(coalesce(nullif(nome, ''), 'ciao'), new.codice), 'it', new.id);
        -- parte subito (senza aspettare l'orologio dei 2 minuti)
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

-- chiama subito la funzione whatsapp-invia, con la stessa chiamata dell'orologio 'whatsapp-invia'
-- (parte dopo il salvataggio dell'ordine; se non riesce, ci pensa l'orologio entro 2 minuti)
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

revoke execute on function public.asp_avvisa_pronto()    from public, anon, authenticated;
revoke execute on function public.asp_sveglia_whatsapp() from public, anon, authenticated;

drop trigger if exists asp_avvisa_pronto on public.asp_ordini;
create trigger asp_avvisa_pronto after update of stato on public.asp_ordini
  for each row execute function public.asp_avvisa_pronto();


-- ---------- l'interruttore, dall'app del Sunmi (password del menu) ----------

create or replace function public.asp_wa_pronto(pwd text, p_attivo boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare imp public.asp_impostazioni;
begin
  if public.verify_pw(pwd) is null then raise exception 'password non valida' using hint = 'password'; end if;
  if p_attivo is not null then
    update public.asp_impostazioni set wa_pronto = p_attivo where id = 1;
  end if;
  select * into imp from public.asp_impostazioni where id = 1;
  return jsonb_build_object('attivo', imp.wa_pronto, 'modello', imp.wa_modello,
    'inviati_oggi', (select count(*) from public.wa_uscita u join public.asp_ordini o on o.id = u.ordine
                      where u.tipo = 'asporto' and o.sera = public.pren_oggi() and u.stato in ('inviato', 'consegnato', 'letto')));
end $$;

grant execute on function public.asp_wa_pronto(text, boolean) to anon, authenticated;


-- ---------- controllo (non scrive niente) ----------
select (select wa_pronto from public.asp_impostazioni where id = 1)                         as interruttore_whatsapp,
       (select count(*) from cron.job where jobname = 'whatsapp-invia')                     as orologio_whatsapp,
       (select count(*) from pg_trigger where tgname = 'asp_avvisa_pronto' and not tgisinternal) as trigger_pronto;
