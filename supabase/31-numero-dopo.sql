-- =============================================================================
-- PRENOTAZIONI: IL NUMERO E IL NOME SI POSSONO SISTEMARE DOPO (si esegue DOPO 30-regalo-senza-50.sql)
-- Richiesta del titolare, 02/11/2026: le prenotazioni dettate a voce si salvano senza numero
-- e il numero si aggiunge più tardi dalla prenotazione (anche il nome, se la voce l'ha capito male).
-- Con il numero la prenotazione si collega anche al Club, come quando si aggiunge a mano.
-- Si può rieseguire: sostituisce solo pren_modifica (stessa firma, stessi permessi).
-- =============================================================================

-- cambia una prenotazione: stato (arrivati, non venuti, annullata, di nuovo confermata), persone, sera, turno, nota,
-- nome e telefono ("" = senza numero)
create or replace function public.pren_modifica(p_pin text, p_id uuid, p_dati jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  p      public.pren_prenotazioni;
  st     text := p_dati->>'stato';
  n      int;
  s      date;
  t      text := p_dati->>'turno';
  v_nome text := left(trim(p_dati->>'nome'), 60);
  tel    text;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into p from public.pren_prenotazioni where id = p_id for update;
  if p.id is null then raise exception 'Prenotazione non trovata' using hint = 'nonc'; end if;
  if st is not null and st not in ('confermata', 'arrivati', 'noshow', 'annullata') then
    raise exception 'Stato non valido' using hint = 'stato';
  end if;
  begin
    n := (p_dati->>'persone')::int;
    s := (p_dati->>'sera')::date;
  exception when others then
    raise exception 'Dati non validi' using hint = 'dati';
  end;
  if n is not null and (n < 1 or n > 200) then raise exception 'Numero di persone non valido' using hint = 'persone'; end if;
  if t is not null and t !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then raise exception 'Orario non valido' using hint = 'turno'; end if;
  if v_nome is not null and length(v_nome) < 2 then raise exception 'Scrivi il nome' using hint = 'nome'; end if;
  if p_dati ? 'telefono' then
    tel := trim(coalesce(p_dati->>'telefono', ''));
    if tel <> '' then
      tel := public.club_telefono(tel);
      if tel is null then raise exception 'Numero di telefono non valido' using hint = 'telefono'; end if;
    end if;
  end if;
  update public.pren_prenotazioni set
    stato        = coalesce(st, stato),
    annullata    = case when st = 'annullata' and stato <> 'annullata' then now()
                        when st is not null and st <> 'annullata' then null else annullata end,
    annullata_da = case when st = 'annullata' and stato <> 'annullata' then 'titolare'
                        when st is not null and st <> 'annullata' then null else annullata_da end,
    persone      = coalesce(n, persone),
    sera         = coalesce(s, sera),
    turno        = coalesce(t, turno),
    nota         = coalesce(left(trim(p_dati->>'nota'), 300), nota),
    nome         = coalesce(v_nome, nome),
    telefono     = case when p_dati ? 'telefono' then tel else telefono end,
    iscritto     = case when p_dati ? 'telefono' and tel <> telefono
                        then (select i.id from public.club_iscritti i where i.telefono = tel and tel <> '' order by i.creato limit 1)
                        else iscritto end
   where id = p.id returning * into p;
  return public.pren_vista_titolare(p);
end $$;
