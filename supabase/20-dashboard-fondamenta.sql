-- =============================================================================
-- DASHBOARD DA COMPUTER — LE FONDAMENTA DEI DATI (si esegue DOPO 19-campagna-whatsapp.sql)
-- Prima dei grafici, i dati che mancavano per avere statistiche vere:
-- · cassa_sere: l'incasso di ogni sera (con coperti e scontrini). Lo manda il gestionale
--   (ERP) ogni sera con erp_incasso e una chiave sua; se manca, il titolare lo scrive a mano.
-- · canale: da dove è arrivato chi prenota o entra nel Club dal sito (Instagram, Google,
--   campagna…). Il sito lo legge dal link o dalla pagina di provenienza, solo per quella
--   visita (niente cookie, niente identificativi) e lo aggiunge subito dopo.
-- · sito_visite: quante visite al giorno per pagina e canale (solo conteggi, anonimi).
-- · dash_periodi: i periodi da confrontare (una campagna, una chiusura, un evento).
-- Si può rieseguire: non cancella niente.
-- =============================================================================

-- ---------- incassi ----------
create table if not exists public.cassa_sere (
  sera       date primary key,                     -- la sera di servizio (fino alle 6 = sera prima)
  incasso    numeric(10,2) not null check (incasso >= 0),
  coperti    int check (coperti is null or coperti >= 0),
  scontrini  int check (scontrini is null or scontrini >= 0),
  dettaglio  jsonb,                                -- facoltativo: reparti, pagamenti, piatti venduti…
  fonte      text not null default 'manuale' check (fonte in ('erp', 'manuale')),
  aggiornato timestamptz not null default now()
);
alter table public.cassa_sere enable row level security;

create table if not exists public.erp_config (
  id           int primary key default 1 check (id = 1),
  chiave_hash  text,                               -- impronta della chiave del gestionale (mai la chiave)
  creata       timestamptz,
  ultimo_invio timestamptz,
  ultimo_esito text
);
insert into public.erp_config (id) values (1) on conflict (id) do nothing;
alter table public.erp_config enable row level security;

-- ---------- canali ----------
alter table public.pren_prenotazioni add column if not exists canale text;
alter table public.club_iscritti     add column if not exists canale text;

create table if not exists public.sito_visite (
  giorno date not null,
  pagina text not null,
  canale text not null,
  visite int  not null default 0,
  primary key (giorno, pagina, canale)
);
alter table public.sito_visite enable row level security;

-- ---------- periodi da confrontare ----------
create table if not exists public.dash_periodi (
  id     bigserial primary key,
  nome   text not null,
  tipo   text not null default 'campagna' check (tipo in ('campagna', 'evento', 'chiusura', 'altro')),
  dal    date not null,
  al     date,                                      -- null = ancora in corso
  note   text not null default '',
  creato timestamptz not null default now(),
  check (al is null or al >= dal)
);
alter table public.dash_periodi enable row level security;
insert into public.dash_periodi (nome, tipo, dal, note)
select 'Regalo a sorpresa · clienti TheFork', 'campagna', date '2026-10-26', 'Email a gruppi da 50 + WhatsApp di richiamo'
 where not exists (select 1 from public.dash_periodi where nome = 'Regalo a sorpresa · clienti TheFork');


-- ---------- funzioni di servizio ----------

-- un canale pulito: "Instagram" → "instagram", "campagna:regalo-thefork" resta, il resto si scarta
create or replace function public.dash_canale_pulito(c text) returns text
language sql immutable set search_path = public as $$
  select case when lower(trim(coalesce(c, ''))) ~ '^[a-z0-9][a-z0-9:._-]{0,39}$' then lower(trim(c)) end
$$;
revoke execute on function public.dash_canale_pulito(text) from public, anon, authenticated;


-- ================= SITO (anon) =================

-- subito dopo la prenotazione: da dove era arrivato (solo prenotazioni fatte da pochi minuti, una volta sola)
create or replace function public.pren_canale(p_segreto text, p_canale text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare c text := public.dash_canale_pulito(p_canale);
begin
  if c is null then return false; end if;
  update public.pren_prenotazioni set canale = c
   where segreto = p_segreto and canale is null and fonte = 'sito' and creato > now() - interval '15 minutes';
  return found;
end $$;

-- subito dopo l'iscrizione al Club, lo stesso
create or replace function public.club_canale(p_chiave text, p_canale text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare c text := public.dash_canale_pulito(p_canale);
begin
  if c is null or coalesce(p_chiave, '') = '' then return false; end if;
  update public.club_iscritti set canale = c
   where chiave = p_chiave and canale is null and creato > now() - interval '15 minutes';
  return found;
end $$;

-- una visita (una per pagina per visita): solo il conteggio del giorno
create or replace function public.sito_visita(p_pagina text, p_canale text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare
  pg text := coalesce(public.dash_canale_pulito(p_pagina), 'altro');
  c  text := coalesce(public.dash_canale_pulito(p_canale), 'diretto');
begin
  insert into public.sito_visite (giorno, pagina, canale, visite)
  values (public.pren_oggi(), pg, c, 1)
  on conflict (giorno, pagina, canale) do update set visite = public.sito_visite.visite + 1
  where public.sito_visite.visite < 100000;
end $$;

grant execute on function public.pren_canale(text, text), public.club_canale(text, text),
  public.sito_visita(text, text) to anon, authenticated;


-- ================= GESTIONALE (ERP) =================
-- Il gestionale chiama POST /rest/v1/rpc/erp_incasso con la sua chiave. Una sera si può
-- rimandare quante volte si vuole: vale l'ultimo invio. Sopra 100.000 € o con una data
-- fuori dagli ultimi 400 giorni si rifiuta (errori di battitura).
create or replace function public.erp_incasso(p_chiave text, p_sera date, p_incasso numeric,
                                              p_coperti int, p_scontrini int, p_dettaglio jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare h text;
begin
  select chiave_hash into h from public.erp_config where id = 1;
  if h is null or coalesce(p_chiave, '') = ''
     or encode(sha256(convert_to(p_chiave, 'UTF8')), 'hex') <> h then
    raise exception 'Chiave del gestionale non valida' using hint = 'chiave';
  end if;
  if p_sera is null or p_sera > public.pren_oggi() or p_sera < public.pren_oggi() - 400 then
    raise exception 'Data non valida' using hint = 'sera';
  end if;
  if p_incasso is null or p_incasso < 0 or p_incasso > 100000 then
    raise exception 'Incasso non valido' using hint = 'incasso';
  end if;
  insert into public.cassa_sere (sera, incasso, coperti, scontrini, dettaglio, fonte, aggiornato)
  values (p_sera, round(p_incasso, 2), p_coperti, p_scontrini, p_dettaglio, 'erp', now())
  on conflict (sera) do update set incasso = excluded.incasso, coperti = excluded.coperti,
    scontrini = excluded.scontrini, dettaglio = excluded.dettaglio, fonte = 'erp', aggiornato = now();
  update public.erp_config set ultimo_invio = now(), ultimo_esito = 'ok ' || p_sera where id = 1;
  return jsonb_build_object('ok', true, 'sera', p_sera);
exception when check_violation or numeric_value_out_of_range or invalid_text_representation then
  raise exception 'Numeri non validi' using hint = 'numeri';
end $$;

grant execute on function public.erp_incasso(text, date, numeric, int, int, jsonb) to anon, authenticated;


-- ================= TITOLARE (dashboard, col PIN) =================

-- una chiave nuova per il gestionale: si vede UNA volta sola (qui si tiene solo l'impronta)
create or replace function public.dash_erp_nuova_chiave(p_pin text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare k text := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
begin
  perform public.pr_controlla_pin(p_pin);
  update public.erp_config set chiave_hash = encode(sha256(convert_to(k, 'UTF8')), 'hex'),
         creata = now(), ultimo_esito = null where id = 1;
  return jsonb_build_object('chiave', k);
end $$;

-- l'incasso scritto a mano (se il gestionale non l'ha mandato, o per correggerlo)
create or replace function public.dash_cassa_salva(p_pin text, p_sera date, p_incasso numeric,
                                                   p_coperti int, p_scontrini int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  if p_sera is null or p_sera > public.pren_oggi() then raise exception 'Data non valida' using hint = 'sera'; end if;
  if p_incasso is null then
    delete from public.cassa_sere where sera = p_sera;                    -- vuoto = togli la sera
  else
    insert into public.cassa_sere (sera, incasso, coperti, scontrini, fonte, aggiornato)
    values (p_sera, round(p_incasso, 2), p_coperti, p_scontrini, 'manuale', now())
    on conflict (sera) do update set incasso = excluded.incasso, coperti = excluded.coperti,
      scontrini = excluded.scontrini, fonte = 'manuale', aggiornato = now();
  end if;
  return jsonb_build_object('ok', true);
exception when check_violation or numeric_value_out_of_range then
  raise exception 'Numeri non validi' using hint = 'numeri';
end $$;

-- i periodi: salva (nuovo o modifica) ed elimina
create or replace function public.dash_periodo_salva(p_pin text, p_id bigint, p_nome text, p_tipo text,
                                                     p_dal date, p_al date, p_note text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n text := left(trim(coalesce(p_nome, '')), 80);
begin
  perform public.pr_controlla_pin(p_pin);
  if length(n) < 2 then raise exception 'Scrivi un nome' using hint = 'nome'; end if;
  if p_dal is null or (p_al is not null and p_al < p_dal) then raise exception 'Date non valide' using hint = 'date'; end if;
  if p_id is null then
    insert into public.dash_periodi (nome, tipo, dal, al, note) values (n, coalesce(p_tipo, 'campagna'), p_dal, p_al, left(coalesce(p_note, ''), 300));
  else
    update public.dash_periodi set nome = n, tipo = coalesce(p_tipo, tipo), dal = p_dal, al = p_al,
           note = left(coalesce(p_note, ''), 300) where id = p_id;
  end if;
  return coalesce((select jsonb_agg(to_jsonb(d) order by d.dal desc) from public.dash_periodi d), '[]'::jsonb);
exception when check_violation then
  raise exception 'Tipo non valido' using hint = 'tipo';
end $$;

create or replace function public.dash_periodo_elimina(p_pin text, p_id bigint) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  delete from public.dash_periodi where id = p_id;
  return coalesce((select jsonb_agg(to_jsonb(d) order by d.dal desc) from public.dash_periodi d), '[]'::jsonb);
end $$;

grant execute on function public.dash_erp_nuova_chiave(text), public.dash_cassa_salva(text, date, numeric, int, int),
  public.dash_periodo_salva(text, bigint, text, text, date, date, text), public.dash_periodo_elimina(text, bigint)
  to anon, authenticated;
