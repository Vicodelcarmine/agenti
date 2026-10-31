-- =============================================================================
-- CAMPAGNA REGALO: MAI A CHI HA USATO IL 50% (si esegue DOPO 29-prenota-diretto.sql)
-- Scelta del titolare, 31/10/2026: chi ha prenotato col 50% anche una volta è fuori per sempre.
-- Il WhatsApp di richiamo salta chi è in tf_esclusi, anche se ci entra dopo: l'elenco cresce da
-- solo con le email di TheFork. Chi ha già ricevuto il messaggio o scoperto il regalo resta com'è.
-- Le email della campagna partono da Brevo: lì questi contatti hanno GRUPPO = 0, fuori dai segmenti.
-- Si può rieseguire: non cancella niente.
-- =============================================================================

create or replace function public.camp_pianifica_wa() returns int
language plpgsql volatile security definer set search_path = public as $$
declare k public.camp_campagne; n int := 0; m int; resta int;
begin
  if coalesce((select numero_id from public.wa_config where id = 1), '') = '' or not public.camp_wa_ora_buona(now()) then
    return 0;
  end if;
  for k in select * from public.camp_campagne where attiva and wa_attivo loop
    resta := k.wa_max_giorno - (select count(*) from public.wa_uscita u join public.camp_contatti x on x.id = u.contatto
                                 where x.campagna = k.id and u.tipo = 'campagna'
                                   and u.creato >= (public.pren_oggi() + time '00:00') at time zone 'Europe/Rome');
    continue when resta <= 0;
    with scelti as (
      select distinct on (c.telefono) c.*
        from public.camp_contatti c
        join public.camp_gruppi gr on gr.campagna = c.campagna and gr.gruppo = c.gruppo
       where c.campagna = k.id and c.telefono is not null
         and c.premio is null and c.disiscritto is null and c.wa_quando is null
         and public.camp_quando_wa(gr.email_quando, k.wa_giorni) <= now()
         and not exists (select 1 from public.wa_contatti w where w.telefono = c.telefono and w.stop)
         -- lo stesso telefono su due contatti: basta un messaggio, e niente se l'altro ha già fatto qualcosa
         and not exists (select 1 from public.camp_contatti y
                          where y.campagna = c.campagna and y.telefono = c.telefono and y.id <> c.id
                            and (y.premio is not null or y.disiscritto is not null or y.wa_quando is not null))
         and not public.tf_gia_contattato(c.telefono)
         and not exists (select 1 from public.tf_esclusi e where e.impronta = public.tf_impronta(c.telefono))
       order by c.telefono, c.gruppo, c.codice),
    nuovi as (
      insert into public.wa_uscita (telefono, tipo, modello, parametri, link, lingua, contatto)
      select s.telefono, 'campagna', k.wa_modello, jsonb_build_array(public.camp_nome_breve(s.nome)), s.codice, 'it', s.id
        from (select * from scelti order by gruppo, codice limit resta) s
      returning contatto)
    update public.camp_contatti set wa_quando = now() where id in (select contatto from nuovi);
    get diagnostics m = row_count;
    n := n + m;
  end loop;
  return n;
end $$;
