-- =============================================================================
-- ASPORTO — STORICO per il titolare (dashboard, col PIN)
-- Si esegue DOPO 12-asporto.sql. Solo lettura: non cambia tabelle né ordini.
-- Gli ordini di una sera qualsiasi (anche quelle passate), le ultime sere con i
-- totali e il totale del mese. Il Banco continua a vedere solo stasera.
-- Si può rieseguire.
-- =============================================================================

create or replace function public.asp_storico(p_pin text, p_sera date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  oggi date := public.pren_oggi();
  s    date := least(coalesce(p_sera, public.pren_oggi()), public.pren_oggi());
begin
  perform public.pr_controlla_pin(p_pin);
  return jsonb_build_object(
    'oggi', oggi,
    'sera', s,
    'ordini', coalesce((select jsonb_agg(public.asp_vista(o) || jsonb_build_object(
                          'id', o.id, 'telefono', o.telefono, 'pezzi', o.pezzi, 'socio', o.iscritto is not null,
                          'visto', o.visto, 'chiuso', o.chiuso)
                          order by o.ritiro, o.creato)
                          from public.asp_ordini o where o.sera = s), '[]'::jsonb),
    -- le ultime 30 sere con almeno un ordine (gli annullati non contano nei totali)
    'sere', coalesce((select jsonb_agg(x order by x.sera desc) from (
               select sera,
                      count(*) filter (where stato <> 'annullato')                    as ordini,
                      count(*) filter (where stato = 'annullato')                     as annullati,
                      coalesce(sum(pezzi) filter (where stato <> 'annullato'), 0)     as piatti,
                      coalesce(sum(totale) filter (where stato <> 'annullato'), 0)    as incasso
                 from public.asp_ordini
                group by sera order by sera desc limit 30) x), '[]'::jsonb),
    'mese', (select jsonb_build_object(
               'ordini', count(*) filter (where stato <> 'annullato'),
               'incasso', coalesce(sum(totale) filter (where stato <> 'annullato'), 0))
               from public.asp_ordini
              where sera >= date_trunc('month', oggi)::date and sera <= oggi));
end $$;

grant execute on function public.asp_storico(text, date) to anon, authenticated;
