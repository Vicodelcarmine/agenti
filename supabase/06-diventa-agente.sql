-- =============================================================================
-- VICO AGENTI — modifica del 12/10/2026: pagina "Diventa agente" (richieste da approvare in dashboard).
-- Estratta da 01-agenti.sql (che resta il file completo e aggiornato).
-- =============================================================================

-- richieste dalla pagina "Diventa agente": restano qui solo finché il titolare non le approva o scarta
create table if not exists public.pr_candidature (
  id       uuid primary key default gen_random_uuid(),
  creato   timestamptz not null default now(),
  nome     text not null,
  telefono text not null,
  ruolo    text not null default '',
  note     text not null default ''
);
alter table public.pr_candidature enable row level security;

create or replace function public.pr_panoramica(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s date := public.pr_sera(now());
begin
  perform public.pr_controlla_pin(p_pin);
  return jsonb_build_object(
    'agenti', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'nome', a.nome, 'telefono', a.telefono,
                                          'attivo', a.attivo, 'codice', a.codice, 'validita', a.validita,
                                          'bonusFino', case when public.pr_bonus_ultima(a) >= s then public.pr_bonus_ultima(a) end)
                       || public.pr_riepilogo(a.id) order by a.creato)
        from public.pr_agenti a), '[]'::jsonb),
    'tavoli', coalesce((
      select jsonb_agg(jsonb_build_object('codice', b.codice, 'agente', a.nome, 'quando', b.riscattato,
                                          'persone', b.persone, 'euro', b.euro, 'premio', b.premio,
                                          'annullabile', public.pr_ultimo_della_sera(b))
                       order by b.riscattato desc)
        from public.pr_buoni b join public.pr_agenti a on a.id = b.agente
       where b.sera_riscatto = s and b.stato = 'riscattato'), '[]'::jsonb),
    'inAttesa', (select count(*) from public.pr_buoni where stato = 'attivo' and now() < scade),
    'giocate',  (select count(*) from public.pr_buoni where sera = s),
    'chiusura', (select chiusura from public.pr_impostazioni where id = 1),
    'richieste', (select count(*) from public.pr_candidature));
end $$;

create or replace function public.pr_candidatura(p_nome text, p_telefono text, p_ruolo text, p_note text) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare
  n text := left(trim(coalesce(p_nome, '')), 80);
  t text := regexp_replace(coalesce(p_telefono, ''), '[^0-9+]', '', 'g');
begin
  if length(n) < 2 then raise exception 'Scrivi il tuo nome' using hint = 'nome'; end if;
  if length(regexp_replace(t, '\D', '', 'g')) < 8 or length(t) > 16 then
    raise exception 'Numero di telefono non valido' using hint = 'telefono';
  end if;
  if (select count(*) from public.pr_candidature where telefono = t and creato > now() - interval '1 day') >= 3
     or (select count(*) from public.pr_candidature where creato > now() - interval '1 day') >= 100 then
    raise exception 'Troppe richieste: riprova domani' using hint = 'troppe';
  end if;
  insert into public.pr_candidature (nome, telefono, ruolo, note)
  values (n, t, left(trim(coalesce(p_ruolo, '')), 40), left(trim(coalesce(p_note, '')), 500));
  return true;
end $$;

create or replace function public.pr_candidature(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return coalesce((select jsonb_agg(to_jsonb(c) order by c.creato desc) from public.pr_candidature c), '[]'::jsonb);
end $$;

create or replace function public.pr_approva_candidatura(p_pin text, p_id uuid, p_bonus boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare c public.pr_candidature; a jsonb;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into c from public.pr_candidature where id = p_id for update;
  if not found then raise exception 'Richiesta non trovata' using hint = 'candidatura'; end if;
  a := public.pr_salva_agente(p_pin, jsonb_build_object('nome', c.nome, 'telefono', c.telefono, 'bonus', coalesce(p_bonus, true)));
  delete from public.pr_candidature where id = c.id;
  return a;
end $$;

create or replace function public.pr_scarta_candidatura(p_pin text, p_id uuid) returns boolean
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  delete from public.pr_candidature where id = p_id;
  if not found then raise exception 'Richiesta non trovata' using hint = 'candidatura'; end if;
  return true;
end $$;

grant execute on function
  public.pr_candidatura(text, text, text, text), public.pr_candidature(text),
  public.pr_approva_candidatura(text, uuid, boolean), public.pr_scarta_candidatura(text, uuid)
to anon, authenticated;

-- controllo
select (select count(*) from public.pr_candidature) as richieste,
       (select string_agg(proname, ', ' order by proname) from pg_proc where proname like 'pr\_%candidatur%') as funzioni;