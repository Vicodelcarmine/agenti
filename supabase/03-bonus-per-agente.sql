-- =============================================================================
-- VICO AGENTI — modifica del 06/10/2026 (2): settimana di benvenuto accendibile agente per agente.
-- Estratta da 01-agenti.sql (che resta il file completo e aggiornato).
-- =============================================================================

-- false = per questo agente la settimana di benvenuto non vale (es. lavorava già prima)
alter table public.pr_agenti add column if not exists bonus boolean not null default true;

create or replace function public.pr_bonus_periodo(a public.pr_agenti) returns date
language sql stable set search_path = public as $$
  select case when i.bonus_giorni > 0 and i.bonus_per > 1 then public.pr_sera(a.creato) + i.bonus_giorni - 1 end
    from public.pr_impostazioni i where i.id = 1
$$;

create or replace function public.pr_bonus_ultima(a public.pr_agenti) returns date
language sql stable set search_path = public as $$
  select case when a.bonus then public.pr_bonus_periodo(a) end
$$;

revoke execute on function public.pr_bonus_periodo(public.pr_agenti)      from public, anon, authenticated;

create or replace function public.pr_dettaglio_agente(p_pin text, p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a public.pr_agenti;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into a from public.pr_agenti where id = p_id;
  if not found then raise exception 'Agente non trovato' using hint = 'agente'; end if;
  return to_jsonb(a) || public.pr_riepilogo(a.id) || jsonb_build_object(
    'bonusFino', case when public.pr_bonus_ultima(a) >= public.pr_sera(now()) then public.pr_bonus_ultima(a) end,
    'bonusPeriodo', case when public.pr_bonus_periodo(a) >= public.pr_sera(now()) then public.pr_bonus_periodo(a) end,
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

create or replace function public.pr_salva_agente(p_pin text, p_dati jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a public.pr_agenti; c text;
begin
  perform public.pr_controlla_pin(p_pin);
  if nullif(p_dati->>'id', '') is not null then
    select * into a from public.pr_agenti where id = (p_dati->>'id')::uuid for update;
    if not found then raise exception 'Agente non trovato' using hint = 'agente'; end if;
  else
    loop
      c := public.pr_casuale(5);
      exit when not exists (select 1 from public.pr_agenti where codice = c);
    end loop;
    insert into public.pr_agenti (codice, chiave, nome, fasce)
    values (c, public.pr_casuale(20), 'Agente', (select fasce from public.pr_impostazioni where id = 1))
    returning * into a;
  end if;
  if p_dati ? 'nome' then
    update public.pr_agenti set nome = coalesce(nullif(left(trim(p_dati->>'nome'), 60), ''), 'Agente') where id = a.id;
  end if;
  if p_dati ? 'telefono' then
    update public.pr_agenti set telefono = left(coalesce(trim(p_dati->>'telefono'), ''), 30) where id = a.id;
  end if;
  if p_dati ? 'attivo' then
    update public.pr_agenti set attivo = (p_dati->>'attivo')::boolean where id = a.id;
  end if;
  if p_dati ? 'bonus' then
    update public.pr_agenti set bonus = (p_dati->>'bonus')::boolean where id = a.id;
  end if;
  if p_dati ? 'fasce' then
    update public.pr_agenti set fasce = public.pr_valida_fasce(p_dati->'fasce') where id = a.id;
  end if;
  select * into a from public.pr_agenti where id = a.id;
  return to_jsonb(a);
end $$;

-- Leonardo lavorava già prima: per lui niente settimana di benvenuto (richiesta del titolare, 06/10/2026)
update public.pr_agenti set bonus = false where nome = 'Leonardo';

-- controllo
select nome, bonus, public.pr_bonus_ultima(a) as bonus_fino_a, public.pr_fasce_sera(a, public.pr_sera(now())) as tariffe_stasera
  from public.pr_agenti a;
