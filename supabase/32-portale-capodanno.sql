-- =============================================================================
-- PRENOTAZIONI DA CAPODANNOFIRENZE.IT → CRUSCOTTO (si esegue DOPO 31-caparre-stripe.sql)
-- Il portale capodannofirenze.it vende il cenone del Vico e le prenotazioni stanno nel loro
-- gestionale (prenotazioni.capodannofirenze.it, solo lettura). Ogni mattina un'attività sul Mac
-- apre il gestionale nel browser dell'app, legge l'elenco e lo manda qui con pren_da_portale:
-- così nel cruscotto ci sono insieme le prenotazioni del portale e quelle prese al telefono.
-- · portale_config: l'impronta (sha256) della chiave dell'attività, ultimo invio ed esito
-- · portale_eventi: quale locale/biglietto del portale va in quale sera e a che ora
-- · portale_pren: una prenotazione del portale = una prenotazione del cruscotto
-- · pren_da_portale(chiave, righe, prova): nuove → aggiunte (provenienza "altro", canale
--   "capodannofirenze", nella nota numero, pagamento, acconto/saldo e note) con la solita
--   notifica; cambiate → aggiornate; "Cancellata" → annullate. "In attesa di pagamento" non conta
--   ancora. Con prova = true fa tutto e poi annulla (serve per provare senza lasciare dati).
-- Si può rieseguire.
-- =============================================================================

create table if not exists public.portale_config (
  id           int primary key default 1 check (id = 1),
  chiave_hash  text,
  ultimo_invio timestamptz,
  ultimo_esito text
);
insert into public.portale_config (id) values (1) on conflict (id) do nothing;
alter table public.portale_config enable row level security;

create table if not exists public.portale_eventi (
  locale    text not null,
  biglietto text not null,
  sera      date not null,
  turno     text not null check (turno ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  primary key (locale, biglietto)
);
alter table public.portale_eventi enable row level security;
insert into public.portale_eventi (locale, biglietto, sera, turno)
values ('Vico del Carmine', 'Cenone', '2026-12-31', '20:00')
on conflict (locale, biglietto) do nothing;

create table if not exists public.portale_pren (
  id_portale   text primary key,
  prenotazione uuid references public.pren_prenotazioni(id) on delete set null,
  stato        text,
  impronta     text,                    -- per capire se qualcosa è cambiato
  creato       timestamptz not null default now(),
  aggiornato   timestamptz not null default now()
);
alter table public.portale_pren enable row level security;

-- p_righe: [{ id, nome, cognome, locale, biglietto, persone, pagamento, stato, totale, acconto, saldo, telefono, note, note_pag }]
create or replace function public.pren_da_portale(p_chiave text, p_righe jsonb, p_prova boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  h      text;
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
  select chiave_hash into h from public.portale_config where id = 1;
  if h is null or coalesce(p_chiave, '') = '' or encode(sha256(convert_to(p_chiave, 'UTF8')), 'hex') <> h then
    raise exception 'Chiave non valida' using hint = 'chiave';
  end if;
  if jsonb_typeof(p_righe) <> 'array' or jsonb_array_length(p_righe) > 1000 then
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
revoke execute on function public.pren_da_portale(text, jsonb, boolean) from public;
grant  execute on function public.pren_da_portale(text, jsonb, boolean) to anon, authenticated, service_role;
