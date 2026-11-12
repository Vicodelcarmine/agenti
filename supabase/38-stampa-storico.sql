-- =============================================================================
-- STAMPANTE DEL BANCO: STORICO ORDINI NELL'APP DEL SUNMI (si esegue DOPO 36 e 37)
-- Richiesta del titolare 12/11/2026: nell'app Vico Stampa un tasto "Storico ordini"
-- con tutti gli ordini d'asporto raggruppati per data, dal più recente, solo le
-- sere in cui ci sono ordini; scorrendo si caricano i giorni più vecchi.
-- Si apre con la password del menu (quella del Banco, che conosce anche il personale):
-- per questo qui NON ci sono i numeri di telefono. Tutti i dati restano nella
-- dashboard del titolare (col PIN).
-- Solo lettura: non cambia tabelle né ordini. Si può rieseguire.
-- =============================================================================

-- 7 sere con ordini alla volta, quelle prima di p_prima (null = da stasera)
create or replace function public.stampa_storico_dentro(p_prima date) returns jsonb
language plpgsql stable set search_path = public as $$
declare
  sere jsonb;
  piu_vecchia date;
begin
  with s as (
    select distinct o.sera from public.asp_ordini o
     where p_prima is null or o.sera < p_prima
     order by o.sera desc limit 7)
  select coalesce(jsonb_agg(jsonb_build_object(
           'sera',    s.sera,
           'ordini',  (select count(*) from public.asp_ordini o where o.sera = s.sera and o.stato <> 'annullato'),
           'totale',  (select coalesce(sum(o.totale), 0) from public.asp_ordini o where o.sera = s.sera and o.stato <> 'annullato'),
           'elenco',  (select jsonb_agg(jsonb_build_object(
                                 'codice', o.codice, 'ritiro', o.ritiro, 'nome', o.nome, 'totale', o.totale,
                                 'stato', o.stato, 'righe', o.righe, 'nota', o.nota, 'socio', o.iscritto is not null,
                                 'creato', o.creato)
                                 order by o.ritiro, o.creato)
                         from public.asp_ordini o where o.sera = s.sera))
           order by s.sera desc), '[]'::jsonb),
         min(s.sera)
    into sere, piu_vecchia
    from s;
  return jsonb_build_object(
    'sere',  sere,
    'altre', piu_vecchia is not null and exists (select 1 from public.asp_ordini where sera < piu_vecchia));
end $$;

revoke execute on function public.stampa_storico_dentro(date) from public, anon, authenticated;

create or replace function public.stampa_storico(pwd text, p_prima date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if public.verify_pw(pwd) is null then raise exception 'password non valida' using hint = 'password'; end if;
  return public.stampa_storico_dentro(p_prima);
end $$;

grant execute on function public.stampa_storico(text, date) to anon, authenticated;

-- controllo (solo numeri, nessun nome): quante sere arrivano, la più recente, se ce ne sono altre
select jsonb_array_length(x->'sere')        as sere_nella_prima_pagina,
       x->'sere'->0->>'sera'                as sera_piu_recente,
       x->'sere'->0->>'ordini'              as ordini_quella_sera,
       x->>'altre'                          as ce_ne_sono_altre,
       (select count(distinct sera) from public.asp_ordini) as sere_con_ordini_in_tutto
  from (select public.stampa_storico_dentro(null) as x) t;
