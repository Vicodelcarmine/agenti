-- =============================================================================
-- STAMPANTE DEL BANCO: FOGLIETTO PIÙ LEGGIBILE (si esegue DOPO 36-stampante-asporto.sql)
-- Richiesta del titolare 10/11/2026 dopo le prime prove sul Sunmi:
--   caratteri un po' più grandi e righe più distanziate; i piatti grandi, i prezzi
--   dei singoli piatti piccoli come prima; "PAGA AL RITIRO" grande, maiuscolo e in
--   grassetto, oppure "GIÀ PAGATO" se l'ordine è già stato pagato.
-- "Già pagato": oggi non esiste il pagamento online dell'asporto, quindi esce sempre
-- PAGA AL RITIRO. Se un giorno asp_ordini avrà una colonna "pagato" (data o vero/falso),
-- il foglietto la legge da solo senza toccare questo file.
-- Serve l'app Vico Stampa 1.2 o più nuova (sa leggere "stile", "s" e "ds").
-- Cambia solo come sono fatti i foglietti: niente tabelle, niente dati. Si può rieseguire.
-- =============================================================================

create or replace function public.stampa_foglio_asporto(o public.asp_ordini, p_prova boolean) returns jsonb
language plpgsql stable set search_path = public as $$
declare
  f      jsonb;
  prima  text := null;
  x      record;
  prezzo numeric;
  q      int;
  quando timestamptz := coalesce(o.creato, now());
  pagato boolean := coalesce(to_jsonb(o)->>'pagato', '') not in ('', 'false');
begin
  f := jsonb_build_array(
    jsonb_build_object('stile', jsonb_build_object('s', 28, 'spazio', 10)),
    jsonb_build_object('t', 'VICO DEL CARMINE', 'a', 'c', 'b', true),
    jsonb_build_object('t', case when p_prova then 'PROVA DI STAMPA' else 'ASPORTO' end, 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'RITIRO ' || o.ritiro, 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'Codice ' || o.codice, 'a', 'c', 'z', 2),
    jsonb_build_object('sep', '-'),
    jsonb_build_object('t', o.nome, 'b', true),
    jsonb_build_object('t', 'Tel ' || o.telefono),
    jsonb_build_object('t', 'Ordinato alle ' || to_char(quando at time zone 'Europe/Rome', 'HH24:MI')
                            || ' del ' || to_char(quando at time zone 'Europe/Rome', 'DD/MM')));
  if o.iscritto is not null then
    f := f || jsonb_build_array(jsonb_build_object('t', 'Socio del Club'));
  end if;
  f := f || jsonb_build_array(jsonb_build_object('sep', '='));

  -- i piatti, raggruppati per portata nell'ordine in cui il cliente li ha scelti:
  -- il piatto grande (32), il suo prezzo piccolo (24)
  for x in
    with r as (select v, n from jsonb_array_elements(coalesce(o.righe, '[]'::jsonb)) with ordinality t(v, n)),
         c as (select coalesce(nullif(trim(v->>'categoria'), ''), 'Altro') as cat, min(n) as primo from r group by 1)
    select r.v, coalesce(nullif(trim(r.v->>'categoria'), ''), 'Altro') as cat
      from r join c on c.cat = coalesce(nullif(trim(r.v->>'categoria'), ''), 'Altro')
     order by c.primo, r.n
  loop
    if prima is distinct from x.cat then
      if prima is not null then f := f || jsonb_build_array(jsonb_build_object('sp', 1)); end if;
      f := f || jsonb_build_array(jsonb_build_object('t', '- ' || upper(x.cat) || ' -'));
      prima := x.cat;
    end if;
    q := greatest(1, coalesce((x.v->>'qta')::int, 1));
    prezzo := public.stampa_numero(x.v->'prezzo');
    f := f || jsonb_build_array(jsonb_build_object(
      't', q || ' x ' || coalesce(x.v->>'nome', '?'),
      'd', case when prezzo is null then '' else public.stampa_euro(prezzo * q) end,
      's', 32, 'ds', 24, 'b', true));
    if coalesce(trim(x.v->>'nota'), '') <> '' then
      f := f || jsonb_build_array(jsonb_build_object('t', '   > ' || trim(x.v->>'nota')));
    end if;
  end loop;

  f := f || jsonb_build_array(
    jsonb_build_object('sep', '='),
    jsonb_build_object('t', 'TOTALE', 'd', public.stampa_euro(o.totale), 'z', 2, 'b', true),
    jsonb_build_object('sp', 1),
    jsonb_build_object('t', case when pagato then 'GIÀ PAGATO' else 'PAGA AL RITIRO' end, 'a', 'c', 'z', 2, 'b', true));
  if coalesce(trim(o.nota), '') <> '' then
    f := f || jsonb_build_array(
      jsonb_build_object('sep', '-'),
      jsonb_build_object('t', 'NOTA DEL CLIENTE', 'b', true),
      jsonb_build_object('t', trim(o.nota)));
  end if;
  if p_prova then
    f := f || jsonb_build_array(jsonb_build_object('sep', '-'),
      jsonb_build_object('t', 'È solo una prova: non preparare niente', 'a', 'c', 'b', true));
  end if;
  return f || jsonb_build_array(jsonb_build_object('sp', 4));
end $$;

create or replace function public.stampa_foglio_annullato(o public.asp_ordini) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_array(
    jsonb_build_object('stile', jsonb_build_object('s', 28, 'spazio', 10)),
    jsonb_build_object('t', '** ANNULLATO **', 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'ASPORTO - RITIRO ' || o.ritiro, 'a', 'c', 'b', true),
    jsonb_build_object('t', 'Codice ' || o.codice, 'a', 'c', 'z', 2),
    jsonb_build_object('t', o.nome, 'a', 'c'),
    jsonb_build_object('sep', '-'),
    jsonb_build_object('t', 'NON PREPARARE', 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'Annullato alle ' || to_char(now() at time zone 'Europe/Rome', 'HH24:MI'), 'a', 'c'),
    jsonb_build_object('sp', 4))
$$;

create or replace function public.stampa_foglio_minimo(o public.asp_ordini) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_array(
    jsonb_build_object('stile', jsonb_build_object('s', 28, 'spazio', 10)),
    jsonb_build_object('t', 'NUOVO ORDINE ASPORTO', 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'RITIRO ' || coalesce(o.ritiro, '?'), 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'Codice ' || coalesce(o.codice, '?'), 'a', 'c', 'z', 2),
    jsonb_build_object('t', 'Guarda i piatti sul Banco', 'a', 'c'),
    jsonb_build_object('sp', 4))
$$;

-- controllo (non scrive niente): il foglietto di un ordine finto, riga per riga
select string_agg(coalesce(x->>'t', case when x ? 'sep' then repeat(x->>'sep', 8)
                                         when x ? 'stile' then '[stile ' || (x->'stile')::text || ']' else '' end)
                  || coalesce(' | ' || nullif(x->>'d', ''), ''), ' / ') as foglietto
  from jsonb_array_elements(public.stampa_foglio_asporto(
         jsonb_populate_record(null::public.asp_ordini,
           '{"codice":"K7QX","ritiro":"20:30","nome":"Mario Rossi","telefono":"3331234567","totale":25,
             "righe":[{"nome":"Pizza Margherita","prezzo":8,"qta":2,"categoria":"Pizze"},{"nome":"Tiramisù","prezzo":9,"qta":1,"categoria":"Dolci"}]}'),
         false)) x;
