-- =============================================================================
-- VICO AGENTI — modifica del 06/10/2026: settimana di benvenuto e giorni di pausa.
-- Estratta da 01-agenti.sql (che resta il file completo e aggiornato).
-- =============================================================================

-- settimana di benvenuto: i primi giorni dell'agente le tariffe sono moltiplicate (0 giorni = niente bonus)
alter table public.pr_impostazioni add column if not exists bonus_giorni int not null default 7;
alter table public.pr_impostazioni add column if not exists bonus_per numeric(4,2) not null default 2;
-- giorni di pausa del servizio (0 = domenica … 6 = sabato): quella sera il gioco non dà buoni
alter table public.pr_impostazioni add column if not exists giorni_pausa int[] not null default '{6}';

create or replace function public.pr_bonus_ultima(a public.pr_agenti) returns date
language sql stable set search_path = public as $$
  select case when i.bonus_giorni > 0 and i.bonus_per > 1 then public.pr_sera(a.creato) + i.bonus_giorni - 1 end
    from public.pr_impostazioni i where i.id = 1
$$;

create or replace function public.pr_fasce_sera(a public.pr_agenti, s date) returns jsonb
language sql stable set search_path = public as $$
  select case when s <= public.pr_bonus_ultima(a) then (
           select jsonb_agg(jsonb_build_object('fino', x.f->'fino',
                                               'euro', round((x.f->>'euro')::numeric * i.bonus_per, 2)) order by x.n)
             from jsonb_array_elements(a.fasce) with ordinality as x(f, n), public.pr_impostazioni i
            where i.id = 1)
         else a.fasce end
$$;

create or replace function public.pr_in_pausa(s date) returns boolean
language sql stable set search_path = public as $$
  select extract(dow from s)::int = any(giorni_pausa) from public.pr_impostazioni where id = 1
$$;

revoke execute on function public.pr_bonus_ultima(public.pr_agenti)       from public, anon, authenticated;
revoke execute on function public.pr_fasce_sera(public.pr_agenti, date)   from public, anon, authenticated;

create or replace function public.pr_agente_pubblico(p_codice text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.pr_agenti;
begin
  select * into a from public.pr_agenti where codice = upper(p_codice);
  if not found then raise exception 'QR non valido' using hint = 'agente'; end if;
  return jsonb_build_object('attivo', a.attivo, 'pausa', public.pr_in_pausa(public.pr_sera(now())));
end $$;

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
  sc := public.pr_scadenza(s, imp.chiusura);
  if now() >= sc then raise exception 'Per stasera abbiamo chiuso' using hint = 'chiuso'; end if;

  -- già giocato stasera da questo telefono: gli ridò il suo buono
  select * into b from public.pr_buoni where dispositivo = p_dispositivo and sera = s order by creato limit 1;
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

create or replace function public.pr_agente(p_chiave text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.pr_agenti;
begin
  select * into a from public.pr_agenti where chiave = p_chiave;
  if not found then raise exception 'Link non valido' using hint = 'chiave'; end if;
  return jsonb_build_object(
      'nome', a.nome, 'codice', a.codice, 'attivo', a.attivo,
      'fasce', public.pr_fasce_sera(a, public.pr_sera(now())), 'fasceBase', a.fasce,
      'bonusFino', case when public.pr_bonus_ultima(a) >= public.pr_sera(now()) then public.pr_bonus_ultima(a) end,
      'bonusPer', (select bonus_per from public.pr_impostazioni where id = 1),
      'pausa', public.pr_in_pausa(public.pr_sera(now())),
      'ultimi', coalesce((
        select jsonb_agg(to_jsonb(x) order by x.quando desc) from (
          select riscattato as quando, sera, persone, euro from public.pr_buoni
           where agente = a.id and stato = 'riscattato' order by riscattato desc limit 12) x), '[]'::jsonb))
    || public.pr_riepilogo(a.id);
end $$;

create or replace function public.pr_leggi_buono(p_pin text, p_codice text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b public.pr_buoni; a public.pr_agenti; gia int;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into b from public.pr_buoni where codice = upper(p_codice);
  if not found then raise exception 'Nessun buono con questo codice' using hint = 'buono'; end if;
  select * into a from public.pr_agenti where id = b.agente;
  select coalesce(sum(persone), 0) into gia from public.pr_buoni
   where agente = a.id and sera = b.sera and stato = 'riscattato' and codice <> b.codice;
  return public.pr_vista(b) || jsonb_build_object(
    'agente', jsonb_build_object('id', a.id, 'nome', a.nome, 'attivo', a.attivo),
    'fasce', public.pr_fasce_sera(a, b.sera), 'giaStasera', gia,
    'bonus', coalesce(b.sera <= public.pr_bonus_ultima(a), false),
    'annullabile', b.stato = 'riscattato' and public.pr_ultimo_della_sera(b));
end $$;

create or replace function public.pr_riscatta(p_pin text, p_codice text, p_persone int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare b public.pr_buoni; a public.pr_agenti; gia int; e numeric;
begin
  perform public.pr_controlla_pin(p_pin);
  if p_persone is null or p_persone < 1 or p_persone > 60 then
    raise exception 'Numero di persone non valido' using hint = 'persone';
  end if;
  select * into b from public.pr_buoni where codice = upper(p_codice) for update;
  if not found then raise exception 'Nessun buono con questo codice' using hint = 'buono'; end if;
  if b.stato = 'riscattato' then raise exception 'Buono già usato' using hint = 'usato'; end if;
  if now() >= b.scade then raise exception 'Buono scaduto' using hint = 'scaduto'; end if;
  -- blocco l'agente: due riscatti insieme non sbagliano lo scaglione
  select * into a from public.pr_agenti where id = b.agente for update;
  select coalesce(sum(persone), 0) into gia from public.pr_buoni
   where agente = a.id and sera = b.sera and stato = 'riscattato';
  e := public.pr_provvigione(public.pr_fasce_sera(a, b.sera), gia, p_persone);
  update public.pr_buoni set stato = 'riscattato', riscattato = clock_timestamp(), persone = p_persone, euro = e
   where codice = b.codice;
  return jsonb_build_object('euro', e, 'gia', gia, 'fasce', public.pr_fasce_sera(a, b.sera), 'agente', a.nome, 'premio', b.premio);
end $$;

create or replace function public.pr_panoramica(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s date := public.pr_sera(now());
begin
  perform public.pr_controlla_pin(p_pin);
  return jsonb_build_object(
    'agenti', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'nome', a.nome, 'telefono', a.telefono,
                                          'attivo', a.attivo, 'codice', a.codice,
                                          'bonusFino', case when public.pr_bonus_ultima(a) >= s then public.pr_bonus_ultima(a) end)
                       || public.pr_riepilogo(a.id) order by a.creato)
        from public.pr_agenti a), '[]'::jsonb),
    'tavoli', coalesce((
      select jsonb_agg(jsonb_build_object('codice', b.codice, 'agente', a.nome, 'quando', b.riscattato,
                                          'persone', b.persone, 'euro', b.euro, 'premio', b.premio,
                                          'annullabile', public.pr_ultimo_della_sera(b))
                       order by b.riscattato desc)
        from public.pr_buoni b join public.pr_agenti a on a.id = b.agente
       where b.sera = s and b.stato = 'riscattato'), '[]'::jsonb),
    'inAttesa', (select count(*) from public.pr_buoni where sera = s and stato = 'attivo' and now() < scade),
    'giocate',  (select count(*) from public.pr_buoni where sera = s),
    'chiusura', (select chiusura from public.pr_impostazioni where id = 1));
end $$;

create or replace function public.pr_dettaglio_agente(p_pin text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.pr_agenti;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into a from public.pr_agenti where id = p_id;
  if not found then raise exception 'Agente non trovato' using hint = 'agente'; end if;
  return to_jsonb(a) || public.pr_riepilogo(a.id) || jsonb_build_object(
    'bonusFino', case when public.pr_bonus_ultima(a) >= public.pr_sera(now()) then public.pr_bonus_ultima(a) end,
    'bonusPer', (select bonus_per from public.pr_impostazioni where id = 1),
    'serate', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.sera desc) from (
        select sera,
               count(*) as giocate,
               count(*) filter (where stato = 'riscattato') as tavoli,
               coalesce(sum(persone) filter (where stato = 'riscattato'), 0) as persone,
               coalesce(sum(euro) filter (where stato = 'riscattato'), 0) as euro
          from public.pr_buoni where agente = a.id group by sera) x), '[]'::jsonb),
    'pagamenti', coalesce((
      select jsonb_agg(jsonb_build_object('id', p.id, 'importo', p.importo, 'data', p.data, 'nota', p.nota)
                       order by p.data desc)
        from public.pr_pagamenti p where p.agente = a.id), '[]'::jsonb));
end $$;

create or replace function public.pr_impostazioni(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return (select jsonb_build_object('chiusura', chiusura, 'fasce', fasce, 'bonusGiorni', bonus_giorni,
                                     'bonusPer', bonus_per, 'giorniPausa', to_jsonb(giorni_pausa))
            from public.pr_impostazioni where id = 1);
end $$;

create or replace function public.pr_salva_impostazioni(p_pin text, p_dati jsonb) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare s date := public.pr_sera(now()); ch text := p_dati->>'chiusura'; v text;
begin
  perform public.pr_controlla_pin(p_pin);
  if ch is not null then
    if ch !~ '^([01]\d|2[0-3]):[0-5]\d$' then raise exception 'Orario non valido' using hint = 'ora'; end if;
    update public.pr_impostazioni set chiusura = ch where id = 1;
    -- i buoni di stasera ancora da usare seguono il nuovo orario
    update public.pr_buoni set scade = public.pr_scadenza(s, ch) where sera = s and stato = 'attivo';
  end if;
  if p_dati ? 'fasce' then
    update public.pr_impostazioni set fasce = public.pr_valida_fasce(p_dati->'fasce') where id = 1;
  end if;
  if p_dati ? 'bonusGiorni' then
    v := trim(p_dati->>'bonusGiorni');
    if coalesce(v, '') !~ '^\d{1,2}$' or v::int > 60 then
      raise exception 'Giorni di benvenuto non validi (da 0 a 60)' using hint = 'bonus';
    end if;
    update public.pr_impostazioni set bonus_giorni = v::int where id = 1;
  end if;
  if p_dati ? 'bonusPer' then
    v := replace(trim(p_dati->>'bonusPer'), ',', '.');
    if coalesce(v, '') !~ '^\d(\.\d{1,2})?$' or v::numeric < 1 or v::numeric > 5 then
      raise exception 'Moltiplicatore non valido (da 1 a 5)' using hint = 'bonus';
    end if;
    update public.pr_impostazioni set bonus_per = v::numeric where id = 1;
  end if;
  if p_dati ? 'giorniPausa' then
    if jsonb_typeof(p_dati->'giorniPausa') <> 'array' then raise exception 'Giorni di pausa non validi' using hint = 'pausa'; end if;
    update public.pr_impostazioni
       set giorni_pausa = coalesce((select array_agg(distinct g::int order by g::int)
                                      from jsonb_array_elements_text(p_dati->'giorniPausa') g
                                     where g ~ '^[0-6]$'), '{}')
     where id = 1;
  end if;
  return true;
end $$;


-- controllo
select bonus_giorni, bonus_per, giorni_pausa from public.pr_impostazioni;
