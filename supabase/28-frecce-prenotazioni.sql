-- =============================================================================
-- PRENOTAZIONI — le frecce saltano alle sere che hanno prenotazioni.
-- Richiesta del titolare: si può tornare indietro oltre ieri, e avanti e indietro si
-- va solo sulle date con almeno una prenotazione (anche annullata), saltando le vuote.
-- pren_giorno è quella di 11-prenotazioni-orari.sql; in più dice la sera prima e la
-- sera dopo con prenotazioni. Si esegue DOPO 11. Si può rieseguire: non cancella niente.
-- =============================================================================

create or replace function public.pren_giorno(p_pin text, p_sera text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  imp   public.pren_impostazioni;
  oggi  date := public.pren_oggi();
  s     date;
  f     jsonb;
  k     int := 0;
  turni jsonb := '[]'::jsonb;
  fuori jsonb;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into imp from public.pren_impostazioni where id = 1;
  begin
    s := coalesce(nullif(p_sera, '')::date, oggi);
  exception when others then
    s := oggi;
  end;
  for f in select * from jsonb_array_elements(imp.fasce) loop
    k := k + 1;
    turni := turni || jsonb_build_object(
      'ora', (f->>'dalle') || ' – ' || (f->>'alle'), 'dalle', f->>'dalle', 'alle', f->>'alle', 'numero', k,
      'prenotati', public.pren_occupati_fascia(s, k), 'previsto', true,
      'lista', coalesce((select jsonb_agg(public.pren_vista_titolare(p)
                                          order by (p.stato = 'annullata'), p.turno, p.creato)
                           from public.pren_prenotazioni p
                          where p.sera = s and p.turno >= f->>'dalle' and p.turno <= f->>'alle'), '[]'::jsonb));
  end loop;
  select jsonb_agg(public.pren_vista_titolare(p) order by (p.stato = 'annullata'), p.turno, p.creato) into fuori
    from public.pren_prenotazioni p where p.sera = s and public.pren_fascia(p.turno) is null;
  if fuori is not null then
    turni := turni || jsonb_build_object('ora', 'Altri orari', 'previsto', false,
      'prenotati', (select coalesce(sum(x.persone), 0) from public.pren_prenotazioni x
                     where x.sera = s and x.stato in ('confermata', 'arrivati') and public.pren_fascia(x.turno) is null),
      'lista', fuori);
  end if;
  return jsonb_build_object(
    'sera', s, 'oggi', oggi, 'coperti', imp.coperti, 'chiuso', public.pren_chiuso(s), 'turni', turni,
    'prossimi', (select coalesce(jsonb_agg(jsonb_build_object(
                    'sera', d, 'chiuso', public.pren_chiuso(d),
                    'prenotazioni', (select count(*) from public.pren_prenotazioni
                                      where sera = d and stato in ('confermata', 'arrivati')),
                    'persone', (select coalesce(sum(persone), 0) from public.pren_prenotazioni
                                 where sera = d and stato in ('confermata', 'arrivati'))) order by d), '[]'::jsonb)
                   from (select oggi + j as d from generate_series(0, 13) j) g),
    'nuove', (select count(*) from public.pren_prenotazioni
               where fonte = 'sito' and creato > now() - interval '1 day' and stato = 'confermata'),
    'prima', (select max(sera) from public.pren_prenotazioni where sera < s),
    'dopo',  (select min(sera) from public.pren_prenotazioni where sera > s));
end $$;

notify pgrst, 'reload schema';
