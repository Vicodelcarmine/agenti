-- =============================================================================
-- CONSERVAZIONE: LE PRENOTAZIONI PER 24 MESI (si esegue DOPO 21-dashboard-statistiche.sql)
-- Scelta del titolare (26/10/2026), scritta nell'informativa privacy del sito: le
-- prenotazioni si tengono 24 mesi (per riconoscere chi torna e per le statistiche), poi
-- restano solo come numeri, senza nome né telefono.
-- · pren_anonimizza_vecchie(): sulle prenotazioni di più di 24 mesi fa toglie nome,
--   telefono, nota, dispositivo, collegamento al Club e ai messaggi; sera, ora, persone,
--   canale, stato e voto restano per le statistiche. Cancella anche gli avvisi al titolare
--   e i messaggi WhatsApp di più di 24 mesi fa. L'orologio la chiama il 1° di ogni mese.
-- · Le statistiche dei clienti ignorano le prenotazioni senza telefono (prima un telefono
--   vuoto, per esempio in una prenotazione scritta a mano, contava come un cliente solo).
-- Si può rieseguire.
-- =============================================================================

create or replace function public.pren_anonimizza_vecchie() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  limite date := (public.pren_oggi() - interval '24 months')::date;
  n1 int; n2 int; n3 int; n4 int;
begin
  update public.pren_prenotazioni
     set nome = 'Cliente', telefono = '', nota = '', dispositivo = '', segreto = null, iscritto = null,
         wa_id = null, wa_errore = null
   where sera < limite and (telefono <> '' or nome <> 'Cliente' or nota <> '' or segreto is not null or iscritto is not null);
  get diagnostics n1 = row_count;
  delete from public.pren_avvisi where creato < limite;
  get diagnostics n2 = row_count;
  delete from public.wa_entrata where quando < limite;
  get diagnostics n3 = row_count;
  delete from public.wa_uscita where creato < limite and stato <> 'in_coda';
  get diagnostics n4 = row_count;
  return jsonb_build_object('prima_del', limite, 'prenotazioni', n1, 'avvisi', n2, 'waRicevuti', n3, 'waInviati', n4);
end $$;
revoke execute on function public.pren_anonimizza_vecchie() from public, anon, authenticated;

-- le presenze dei clienti: solo con un telefono vero
create or replace function public.dash_presenze() returns table (telefono text, sera date, origine text)
language sql stable set search_path = public as $$
  select p.telefono, p.sera, 'prenotazione'
    from public.pren_prenotazioni p
   where coalesce(p.telefono, '') <> '' and p.stato in ('confermata', 'arrivati') and p.sera < public.pren_oggi()
  union
  select i.telefono, r.sera_uso, 'premio'
    from public.club_premi r join public.club_iscritti i on i.id = r.iscritto
   where r.usato is not null and r.sera_uso is not null and coalesce(i.telefono, '') <> ''
$$;
revoke execute on function public.dash_presenze() from public, anon, authenticated;

-- cerca un cliente: le righe senza telefono non sono un cliente
create or replace function public.dash_cerca(p_pin text, p_cerca text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  q  text := lower(trim(coalesce(p_cerca, '')));
  qd text := regexp_replace(q, '[^0-9]', '', 'g');
begin
  perform public.pr_controlla_pin(p_pin);
  if length(q) < 2 then return '[]'::jsonb; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('telefono', telefono, 'nome', public.dash_nome(telefono)) order by public.dash_nome(telefono))
      from (select distinct telefono from (
              select telefono, nome from public.club_iscritti
              union all select telefono, nome from public.pren_prenotazioni
              union all select telefono, nome from public.asp_ordini
              union all select telefono, nome from public.camp_contatti) t
             where coalesce(telefono, '') <> ''
               and (lower(nome) like '%' || q || '%' or (length(qd) >= 4 and regexp_replace(telefono, '[^0-9]', '', 'g') like '%' || qd || '%'))
             limit 30) x), '[]'::jsonb);
end $$;
grant execute on function public.dash_cerca(text, text) to anon, authenticated;

-- l'orologio: il 1° di ogni mese alle 4:30
select cron.schedule('conservazione-24-mesi', '30 4 1 * *', $c$ select public.pren_anonimizza_vecchie(); $c$);
