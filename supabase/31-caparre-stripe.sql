-- =============================================================================
-- CAPARRE STRIPE → PRENOTAZIONI (si esegue DOPO 30-regalo-senza-50.sql)
-- Chi paga la caparra con un link di pagamento Stripe (es. il cenone di Capodanno) finisce da
-- solo tra le prenotazioni, come se l'avesse aggiunta il titolare: provenienza "altro", canale
-- "stripe", nella nota la caparra pagata, i secondi di carne e di pesce e le allergie.
-- Il titolare riceve la solita notifica (pren_avvisi). Niente WhatsApp: partono solo per "sito".
-- Se il titolare rimborsa tutta la caparra da Stripe, la prenotazione si annulla da sola.
-- · pren_stripe_link: quali link di pagamento portano a quale sera/ora e quanto vale la caparra
-- · pren_stripe: un pagamento = una prenotazione (lo stesso avviso due volte non la raddoppia)
-- · pren_da_stripe(p, p_prova): la chiama la funzione "stripe-webhook" con la chiave di servizio;
--   con p_prova fa tutto e poi annulla (raise): serve per la prova con i pagamenti di test
-- · pren_rimborso_stripe(p_pagamento, p_prova): rimborso totale → prenotazione annullata
-- Si può rieseguire.
-- =============================================================================

create table if not exists public.pren_stripe_link (
  link         text primary key,                  -- id del link di pagamento Stripe (plink_…)
  nome         text not null,
  sera         date not null,
  turno        text not null check (turno ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  caparra_cent int  not null check (caparra_cent > 0),   -- a persona, in centesimi di euro
  prova        boolean not null default false,    -- link della modalità di test: solo prove, mai dati veri
  attivo       boolean not null default true
);
alter table public.pren_stripe_link enable row level security;

create table if not exists public.pren_stripe (
  sessione     text primary key,                  -- id della sessione di pagamento (cs_…)
  pagamento    text,                              -- payment_intent (pi_…), per i rimborsi
  link         text,
  prenotazione uuid references public.pren_prenotazioni(id) on delete set null,
  persone      int,
  importo_cent int,
  rimborsato   timestamptz,
  creato       timestamptz not null default now()
);
create index if not exists pren_stripe_pagamento on public.pren_stripe (pagamento);
alter table public.pren_stripe enable row level security;

insert into public.pren_stripe_link (link, nome, sera, turno, caparra_cent, prova) values
  ('plink_1UaKfqDlhbQcXLCVTDijybif', 'Cenone di Capodanno 2026', '2026-12-31', '20:00', 2500, false),
  ('plink_1UaKOVDlhbQcXLCVIOoeWxHg', 'Cenone di Capodanno 2026 (prova)', '2026-12-31', '20:00', 2500, true)
on conflict (link) do nothing;

-- p: { sessione, pagamento, link, importo_cent, nome, telefono, carne, pesce, note }
create or replace function public.pren_da_stripe(p jsonb, p_prova boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  l      public.pren_stripe_link;
  imp    int;
  n      int;
  v_nome text := left(trim(coalesce(p->>'nome', '')), 60);
  tel    text := trim(coalesce(p->>'telefono', ''));
  carne  text := left(trim(coalesce(p->>'carne', '')), 4);
  pesce  text := left(trim(coalesce(p->>'pesce', '')), 4);
  note   text := left(trim(coalesce(p->>'note', '')), 150);
  v_nota text;
  b      public.pren_prenotazioni;
begin
  if coalesce(p->>'sessione', '') = '' then raise exception 'Sessione mancante' using hint = 'sessione'; end if;
  if exists (select 1 from public.pren_stripe where sessione = p->>'sessione') then
    return jsonb_build_object('ok', true, 'gia', true);
  end if;
  select * into l from public.pren_stripe_link where link = p->>'link' and attivo;
  if l.link is null then return jsonb_build_object('ok', true, 'ignorato', 'link'); end if;
  if l.prova and not p_prova then return jsonb_build_object('ok', true, 'ignorato', 'prova'); end if;
  imp := (p->>'importo_cent')::int;
  n := round(imp::numeric / l.caparra_cent);
  if n < 1 or n > 200 then raise exception 'Persone non valide (% cent)', imp using hint = 'persone'; end if;
  if length(v_nome) < 2 then v_nome := 'Cliente Stripe'; end if;
  if tel <> '' then tel := coalesce(public.club_telefono(tel), ''); end if;
  v_nota := '💳 Caparra pagata online: ' || to_char(imp / 100.0, 'FM9990D00') || ' € (' || n || ' × ' ||
            to_char(l.caparra_cent / 100.0, 'FM990D00') || ' €)' ||
            case when imp <> n * l.caparra_cent then ' ⚠️ importo diverso dalle persone' else '' end ||
            ' · Secondi: carne ' || coalesce(nullif(carne, ''), '?') || ', pesce ' || coalesce(nullif(pesce, ''), '?') ||
            case when note <> '' then ' · ' || note else '' end;
  insert into public.pren_prenotazioni (codice, sera, turno, persone, nome, telefono, nota, fonte, canale, iscritto)
  values (public.pren_nuovo_codice(), l.sera, l.turno, n, v_nome, tel, left(v_nota, 300), 'altro', 'stripe',
          (select id from public.club_iscritti where telefono = tel and tel <> ''))
  returning * into b;
  insert into public.pren_stripe (sessione, pagamento, link, prenotazione, persone, importo_cent)
  values (p->>'sessione', nullif(p->>'pagamento', ''), l.link, b.id, n, imp);
  insert into public.pren_avvisi (prenotazione, tipo, titolo, testo)
  values (b.id, 'nuova', '💳 Caparra pagata: ' || l.nome,
          b.nome || ' · ' || public.club_persone(n, 'it') || ' · ' || public.club_data(l.sera, 'it') || ' alle ' || l.turno ||
          ' · carne ' || coalesce(nullif(carne, ''), '?') || ', pesce ' || coalesce(nullif(pesce, ''), '?'));
  if p_prova then
    -- prova: tutto fatto, ora si annulla (niente resta nelle tabelle)
    raise exception 'PROVA_OK %', jsonb_build_object('persone', n, 'sera', l.sera, 'turno', l.turno, 'nota', b.nota,
                                                      'telefono', b.telefono <> '', 'codice', b.codice)::text
      using hint = 'prova';
  end if;
  return jsonb_build_object('ok', true, 'codice', b.codice, 'persone', n);
end $$;

create or replace function public.pren_rimborso_stripe(p_pagamento text, p_prova boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare s public.pren_stripe; b public.pren_prenotazioni;
begin
  select * into s from public.pren_stripe where pagamento = p_pagamento and rimborsato is null for update;
  if s.sessione is null then return jsonb_build_object('ok', true, 'ignorato', 'pagamento'); end if;
  update public.pren_stripe set rimborsato = now() where sessione = s.sessione;
  update public.pren_prenotazioni set stato = 'annullata', annullata = now(), annullata_da = 'stripe'
   where id = s.prenotazione and stato <> 'annullata'
  returning * into b;
  if b.id is not null then
    insert into public.pren_avvisi (prenotazione, tipo, titolo)
    values (b.id, 'annullata', '❌ Caparra rimborsata: prenotazione annullata');
  end if;
  if p_prova then raise exception 'PROVA_OK rimborso %', coalesce(b.codice, '-') using hint = 'prova'; end if;
  return jsonb_build_object('ok', true, 'annullata', b.id is not null);
end $$;

revoke execute on function public.pren_da_stripe(jsonb, boolean)       from public, anon, authenticated;
revoke execute on function public.pren_rimborso_stripe(text, boolean)  from public, anon, authenticated;
grant  execute on function public.pren_da_stripe(jsonb, boolean)       to service_role;
grant  execute on function public.pren_rimborso_stripe(text, boolean)  to service_role;
