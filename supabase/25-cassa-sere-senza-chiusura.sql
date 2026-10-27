-- =============================================================================
-- DASHBOARD — LE SERE SENZA CHIUSURA DI CASSA (si esegue DOPO 24-cassa-categorie.sql)
-- Se una sera la cassa non viene chiusa, la chiusura della sera dopo conta anche lei.
-- Il titolare stampa dalla cassa la "Stampa Reparti Periodo" della sera mancante e i
-- suoi numeri vanno in cassa_rettifiche: la sera mancante diventa una sera "a mano" e gli
-- stessi numeri si tolgono dalla sera che li conteneva, anche quando la sua chiusura
-- arriva di nuovo da Google Drive (erp_incasso li toglie ogni volta).
-- · cassa_rettifiche: sera mancante → sera che la conteneva (dentro), incasso, coperti,
--   sconti, coperto, abbuono e i reparti stampati.
-- · cassa_rettifica_di(sera): le sere mancanti contate dentro quella sera (sommate).
-- · cassa_togli_rettifica(incasso, coperti, dettaglio, r): i numeri giusti di quella sera.
-- · erp_incasso: come prima, ma toglie le sere mancanti contate dentro.
-- Gli articoli della sera che le conteneva restano quelli della chiusura (di due sere):
-- la cassa non dice quali erano della sera prima.
-- Si può rieseguire: le sere già sistemate non si toccano due volte.
-- =============================================================================

create table if not exists public.cassa_rettifiche (
  sera     date primary key,                      -- la sera senza chiusura
  dentro   date not null,                         -- la sera la cui chiusura l'ha contata
  incasso  numeric(10,2) not null check (incasso >= 0),
  coperti  int check (coperti is null or coperti >= 0),
  sconti   numeric(10,2) not null default 0,
  coperto  numeric(10,2) not null default 0,
  abbuono  numeric(10,2) not null default 0,
  reparti  jsonb,                                 -- dalla "Stampa Reparti Periodo" della cassa
  nota     text,
  creato   timestamptz not null default now(),
  check (dentro > sera)
);
alter table public.cassa_rettifiche enable row level security;

-- le sere mancanti contate dentro p_sera, sommate (null se nessuna)
create or replace function public.cassa_rettifica_di(p_sera date) returns jsonb
language sql stable set search_path = public as $$
  select case when count(*) = 0 then null else jsonb_build_object(
           'sere', jsonb_agg(sera order by sera), 'incasso', sum(incasso), 'coperti', sum(coalesce(coperti, 0)),
           'sconti', sum(sconti), 'coperto', sum(coperto), 'abbuono', sum(abbuono)) end
    from public.cassa_rettifiche where dentro = p_sera
$$;

-- i numeri di una chiusura meno le sere mancanti che conteneva: {incasso, coperti, dettaglio}
create or replace function public.cassa_togli_rettifica(p_incasso numeric, p_coperti int, p_dettaglio jsonb, r jsonb) returns jsonb
language plpgsql immutable as $$
declare d jsonb := coalesce(p_dettaglio, '{}'::jsonb);
begin
  if r is null then
    return jsonb_build_object('incasso', p_incasso, 'coperti', p_coperti, 'dettaglio', p_dettaglio);
  end if;
  if d ? 'sconti'  then d := d || jsonb_build_object('sconti',  round((d->>'sconti')::numeric  - (r->>'sconti')::numeric, 2)); end if;
  if d ? 'coperto' then d := d || jsonb_build_object('coperto', round((d->>'coperto')::numeric - (r->>'coperto')::numeric, 2)); end if;
  if d ? 'abbuono' then d := d || jsonb_build_object('abbuono', round((d->>'abbuono')::numeric - (r->>'abbuono')::numeric, 2)); end if;
  return jsonb_build_object(
    'incasso', round(p_incasso - (r->>'incasso')::numeric, 2),
    'coperti', case when p_coperti is null then null else greatest(p_coperti - (r->>'coperti')::int, 0) end,
    'dettaglio', d || jsonb_build_object('rettifica', r));
end $$;
revoke execute on function public.cassa_rettifica_di(date) from public, anon, authenticated;
revoke execute on function public.cassa_togli_rettifica(numeric, int, jsonb, jsonb) from public, anon, authenticated;

-- erp_incasso: uguale a prima, ma la sera che conteneva una sera mancante ne perde i numeri
create or replace function public.erp_incasso(p_chiave text, p_sera date, p_incasso numeric,
                                              p_coperti int, p_scontrini int, p_dettaglio jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare h text; v jsonb;
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
  v := public.cassa_togli_rettifica(p_incasso, p_coperti, p_dettaglio, public.cassa_rettifica_di(p_sera));
  insert into public.cassa_sere (sera, incasso, coperti, scontrini, dettaglio, fonte, aggiornato)
  values (p_sera, round((v->>'incasso')::numeric, 2), (v->>'coperti')::int, p_scontrini, v->'dettaglio', 'erp', now())
  on conflict (sera) do update set incasso = excluded.incasso, coperti = excluded.coperti,
    scontrini = excluded.scontrini, dettaglio = excluded.dettaglio, fonte = 'erp', aggiornato = now();
  update public.erp_config set ultimo_invio = now(), ultimo_esito = 'ok ' || p_sera where id = 1;
  return jsonb_build_object('ok', true, 'sera', p_sera);
exception when check_violation or numeric_value_out_of_range or invalid_text_representation then
  raise exception 'Numeri non validi' using hint = 'numeri';
end $$;
grant execute on function public.erp_incasso(text, date, numeric, int, int, jsonb) to anon, authenticated;

-- ---------- le due sere senza chiusura (foto della "Stampa Reparti Periodo", 27/10/2026) ----------
insert into public.cassa_rettifiche (sera, dentro, incasso, coperti, sconti, coperto, abbuono, reparti, nota) values
  ('2026-05-18', '2026-05-19', 645.90, 33, 133.10, 82.50, -5.00, '[
     {"reparto": "ANTIPASTI", "qta": 5, "euro": 38.50, "sconti": 19.50}, {"reparto": "ABBUONO", "qta": -1, "euro": -5.00, "sconti": 0},
     {"reparto": "BEVANDE", "qta": 27, "euro": 109.00, "sconti": 0}, {"reparto": "BIRRE", "qta": 5, "euro": 25.50, "sconti": 0},
     {"reparto": "CAFFETTERIA", "qta": 2, "euro": 4.00, "sconti": 0}, {"reparto": "COCKTAIL", "qta": 2, "euro": 16.00, "sconti": 0},
     {"reparto": "CONTORNI INSALATONE", "qta": 6, "euro": 41.00, "sconti": 3.00}, {"reparto": "COPERTO", "qta": 33, "euro": 82.50, "sconti": 0},
     {"reparto": "DOLCI", "qta": 5, "euro": 17.00, "sconti": 14.50}, {"reparto": "PIZZA", "qta": 17, "euro": 132.70, "sconti": 54.80},
     {"reparto": "PRIMI", "qta": 10, "euro": 105.20, "sconti": 33.80}, {"reparto": "SECONDI", "qta": 5, "euro": 79.50, "sconti": 7.50}]',
   'Cassa non chiusa: contata nella chiusura del 19/05'),
  ('2026-10-08', '2026-10-09', 76.00, 4, 22.00, 10.00, 0, '[
     {"reparto": "BEVANDE", "qta": 3, "euro": 11.00, "sconti": 0}, {"reparto": "BIRRE", "qta": 1, "euro": 5.50, "sconti": 0},
     {"reparto": "CAFFETTERIA", "qta": 1, "euro": 2.00, "sconti": 0}, {"reparto": "CONTORNI INSALATONE", "qta": 2, "euro": 6.00, "sconti": 6.00},
     {"reparto": "COPERTO", "qta": 4, "euro": 10.00, "sconti": 0}, {"reparto": "PIZZA", "qta": 2, "euro": 25.50, "sconti": 0},
     {"reparto": "PRIMI", "qta": 1, "euro": 7.00, "sconti": 7.00}, {"reparto": "SECONDI", "qta": 1, "euro": 9.00, "sconti": 9.00}]',
   'Cassa non chiusa: contata nella chiusura del 09/10')
on conflict (sera) do nothing;

-- la sera mancante diventa una sera "a mano" (senza articoli: la cassa dà solo i reparti)
insert into public.cassa_sere (sera, incasso, coperti, dettaglio, fonte, aggiornato)
select r.sera, r.incasso, r.coperti,
       jsonb_build_object('fonte', 'cassa-reparti', 'sconti', r.sconti, 'coperto', r.coperto, 'abbuono', r.abbuono,
                          'reparti', r.reparti, 'nota', r.nota),
       'manuale', now()
  from public.cassa_rettifiche r
on conflict (sera) do nothing;

-- la sera che la conteneva (già arrivata da Drive) perde quei numeri, una volta sola
update public.cassa_sere c
   set incasso = (v->>'incasso')::numeric, coperti = (v->>'coperti')::int, dettaglio = v->'dettaglio', aggiornato = now()
  from (select x.sera, public.cassa_togli_rettifica(x.incasso, x.coperti, x.dettaglio, public.cassa_rettifica_di(x.sera)) as v
          from public.cassa_sere x
         where x.sera in (select dentro from public.cassa_rettifiche)
           and x.fonte = 'erp' and not (coalesce(x.dettaglio, '{}'::jsonb) ? 'rettifica')) t
 where c.sera = t.sera;
