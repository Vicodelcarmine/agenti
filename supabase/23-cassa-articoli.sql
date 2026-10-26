-- =============================================================================
-- DASHBOARD — GLI ARTICOLI VENDUTI DALLA CASSA (si esegue DOPO 22-conservazione-24-mesi.sql)
-- Le chiusure di cassa arrivano da Google Drive (collegamento-cassa/Codice.gs, nell'account
-- chiusurevico@gmail.com) attraverso erp_incasso: in cassa_sere.dettaglio ci sono sconti,
-- abbuono, coperto e tutti gli articoli venduti [{codice, nome, qta, euro, sconti}].
-- · dash_cassa_articoli(pin, dal, al): sconti e articoli più venduti in sala nel periodo.
-- Sola lettura, col PIN del titolare. Si può rieseguire.
-- =============================================================================

create or replace function public.dash_cassa_articoli(p_pin text, p_dal date, p_al date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  if p_dal is null or p_al is null or p_al < p_dal or p_al - p_dal > 400 then
    raise exception 'Periodo non valido' using hint = 'periodo';
  end if;
  return jsonb_build_object(
    'sere',         (select count(*) from public.cassa_sere where sera between p_dal and p_al),
    'conDettaglio', (select count(*) from public.cassa_sere where sera between p_dal and p_al
                      and jsonb_typeof(dettaglio->'articoli') = 'array'),
    'sconti',  (select round(coalesce(sum((dettaglio->>'sconti')::numeric), 0), 2) from public.cassa_sere
                 where sera between p_dal and p_al and dettaglio ? 'sconti'),
    'coperto', (select round(coalesce(sum((dettaglio->>'coperto')::numeric), 0), 2) from public.cassa_sere
                 where sera between p_dal and p_al and dettaglio ? 'coperto'),
    'abbuono', (select round(coalesce(sum((dettaglio->>'abbuono')::numeric), 0), 2) from public.cassa_sere
                 where sera between p_dal and p_al and dettaglio ? 'abbuono'),
    'giorni',  (select coalesce(jsonb_agg(jsonb_build_object('g', sera, 'sconti', (dettaglio->>'sconti')::numeric,
                   'pezzi', (select coalesce(sum((a->>'qta')::numeric), 0) from jsonb_array_elements(dettaglio->'articoli') a))
                   order by sera), '[]'::jsonb)
                  from public.cassa_sere where sera between p_dal and p_al and jsonb_typeof(dettaglio->'articoli') = 'array'),
    'articoli', (select coalesce(jsonb_agg(jsonb_build_object('nome', nome, 'codice', codice, 'qta', qta, 'euro', euro,
                    'sconti', sconti, 'sere', sere) order by euro desc, nome), '[]'::jsonb)
                   from (select a->>'nome' as nome, min(a->>'codice') as codice, sum((a->>'qta')::numeric) as qta,
                                round(sum((a->>'euro')::numeric), 2) as euro,
                                round(sum(coalesce((a->>'sconti')::numeric, 0)), 2) as sconti, count(distinct c.sera) as sere
                           from public.cassa_sere c, jsonb_array_elements(c.dettaglio->'articoli') a
                          where c.sera between p_dal and p_al and jsonb_typeof(c.dettaglio->'articoli') = 'array'
                            and coalesce(a->>'nome', '') <> ''
                          group by a->>'nome' order by 4 desc limit 80) t));
end $$;

grant execute on function public.dash_cassa_articoli(text, date, date) to anon, authenticated;
