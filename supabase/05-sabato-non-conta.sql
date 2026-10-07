-- =============================================================================
-- VICO AGENTI — modifica del 07/10/2026 (2): il sabato (giorni di pausa) non si conta mai,
-- né nella validità dei buoni né nella settimana di benvenuto.
-- Estratta da 01-agenti.sql (che resta il file completo e aggiornato).
-- =============================================================================

create or replace function public.pr_piu_sere(s date, n int) returns date
language plpgsql stable set search_path = public as $$
declare d date := s; contate int := 0;
begin
  if n < 1 then return s; end if;
  for i in 1 .. n + 60 loop
    if not public.pr_in_pausa(d) then
      contate := contate + 1;
      if contate = n then return d; end if;
    end if;
    d := d + 1;
  end loop;
  return s + n - 1;   -- tutti i giorni in pausa: conto normale
end $$;

create or replace function public.pr_bonus_periodo(a public.pr_agenti) returns date
language sql stable set search_path = public as $$
  select case when i.bonus_giorni > 0 and i.bonus_per > 1 then public.pr_piu_sere(public.pr_sera(a.creato), i.bonus_giorni) end
    from public.pr_impostazioni i where i.id = 1
$$;

create or replace function public.pr_gioca(p_codice text, p_dispositivo text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  a public.pr_agenti;
  imp public.pr_impostazioni;
  s date := public.pr_sera(now());
  sc timestamptz;
  b public.pr_buoni;
  p public.pr_premi;
  scelto public.pr_premi;
  tot int;
  r numeric;
  c text;
begin
  if coalesce(length(p_dispositivo), 0) < 8 or length(p_dispositivo) > 64 then
    raise exception 'Dispositivo non valido' using hint = 'dispositivo';
  end if;
  select * into a from public.pr_agenti where codice = upper(p_codice);
  if not found or not a.attivo then raise exception 'QR non attivo' using hint = 'agente'; end if;
  if public.pr_in_pausa(s) then raise exception 'Stasera siamo al completo' using hint = 'pausa'; end if;
  select * into imp from public.pr_impostazioni where id = 1;
  -- il buono vale fino alla chiusura dell'ultima sera di validità di quell'agente (il sabato non si conta)
  sc := public.pr_scadenza(public.pr_piu_sere(s, a.validita), imp.chiusura);
  if now() >= sc then raise exception 'Per stasera abbiamo chiuso' using hint = 'chiuso'; end if;

  -- questo telefono ha già un buono di stasera o ancora valido: gli ridò quello
  select * into b from public.pr_buoni
   where dispositivo = p_dispositivo and (sera = s or (stato = 'attivo' and scade > now()))
   order by creato desc limit 1;
  if found then return public.pr_vista(b) || jsonb_build_object('gia', true); end if;

  if (select count(*) from public.pr_buoni where agente = a.id and sera = s) >= 500 then
    raise exception 'Troppe giocate stasera' using hint = 'troppe';
  end if;

  select sum(peso) into tot from public.pr_premi where attivo and peso > 0;
  if coalesce(tot, 0) = 0 then raise exception 'Nessun premio disponibile' using hint = 'premi'; end if;
  r := random() * tot;
  for p in select * from public.pr_premi where attivo and peso > 0 order by ordine, id loop
    scelto := p;
    r := r - p.peso;
    exit when r <= 0;
  end loop;

  loop
    c := public.pr_casuale(6);
    exit when not exists (select 1 from public.pr_buoni where codice = c);
  end loop;
  insert into public.pr_buoni (codice, agente, premio, sera, scade, dispositivo)
  values (c, a.id,
          jsonb_build_object('id', scelto.id, 'emoji', scelto.emoji, 'nome', scelto.nome, 'desc', scelto.descr),
          s, sc, p_dispositivo)
  returning * into b;
  return public.pr_vista(b);
end $$;

-- i buoni su più giorni ancora da usare si allungano, se nel mezzo c'era un sabato
update public.pr_buoni b set scade = public.pr_scadenza(public.pr_piu_sere(b.sera, a.validita), i.chiusura)
  from public.pr_agenti a, public.pr_impostazioni i
 where a.id = b.agente and i.id = 1 and a.validita > 1 and b.stato = 'attivo' and b.scade > now();

-- controllo: giovedì 8 ott + 3 sere = domenica 11; venerdì 9 + 3 = lunedì 12; da sabato 10, 1 sera = domenica 11
select public.pr_piu_sere('2026-10-08', 3) as gio_3, public.pr_piu_sere('2026-10-09', 3) as ven_3,
       public.pr_piu_sere('2026-10-10', 1) as sab_1, public.pr_piu_sere('2026-10-09', 7) as ven_7,
       (select string_agg(nome || ' bonus fino a ' || coalesce(public.pr_bonus_ultima(a)::text, '-'), ', ') from public.pr_agenti a) as agenti;