-- =============================================================================
-- VICO AGENTI — modifica del 29/10/2026: da quale canale arrivano i PR.
-- Estratta da 01-agenti.sql (che resta il file completo e aggiornato). Si esegue DOPO
-- 20-dashboard-fondamenta.sql (usa dash_canale_pulito) e PRIMA di pubblicare il codice nuovo.
-- · Le pagine "Lavora come PR" e "Guide" si linkano con ?ref=<canale> (es. ?ref=esn-florentia):
--   la richiesta si porta dietro il canale ("diretto" se il link non ce l'ha).
-- · pr_canali_richieste: quante richieste al giorno per canale (solo conteggi, restano anche
--   quando la richiesta viene approvata o scartata).
-- · pr_agenti.canale: approvando la richiesta, il canale passa all'agente.
-- · pr_canali(pin): per ogni canale richieste, agenti, agenti col primo tavolo, persone portate.
-- =============================================================================

alter table public.pr_candidature add column if not exists canale text;
alter table public.pr_agenti      add column if not exists canale text;

create table if not exists public.pr_canali_richieste (
  giorno    date not null,
  canale    text not null,
  richieste int  not null default 0,
  primary key (giorno, canale)
);
alter table public.pr_canali_richieste enable row level security;

-- la versione a 4 parametri va tolta, se no le chiamate senza canale non saprebbero quale usare
drop function if exists public.pr_candidatura(text, text, text, text);

create or replace function public.pr_candidatura(p_nome text, p_telefono text, p_ruolo text, p_note text,
                                                 p_canale text default null) returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare
  n text := left(trim(coalesce(p_nome, '')), 80);
  t text := regexp_replace(coalesce(p_telefono, ''), '[^0-9+]', '', 'g');
  k text := coalesce(public.dash_canale_pulito(p_canale), 'diretto');
begin
  if length(n) < 2 then raise exception 'Scrivi il tuo nome' using hint = 'nome'; end if;
  if length(regexp_replace(t, '\D', '', 'g')) < 8 or length(t) > 16 then
    raise exception 'Numero di telefono non valido' using hint = 'telefono';
  end if;
  if (select count(*) from public.pr_candidature where telefono = t and creato > now() - interval '1 day') >= 3
     or (select count(*) from public.pr_candidature where creato > now() - interval '1 day') >= 100 then
    raise exception 'Troppe richieste: riprova domani' using hint = 'troppe';
  end if;
  insert into public.pr_candidature (nome, telefono, ruolo, note, canale)
  values (n, t, left(trim(coalesce(p_ruolo, '')), 40), left(trim(coalesce(p_note, '')), 500), k);
  insert into public.pr_canali_richieste (giorno, canale, richieste)
  values ((now() at time zone 'Europe/Rome')::date, k, 1)
  on conflict (giorno, canale) do update set richieste = public.pr_canali_richieste.richieste + 1;
  return true;
end $$;

-- approvata: diventa un agente (i suoi dati restano solo nella scheda agente, col canale da cui è arrivato)
create or replace function public.pr_approva_candidatura(p_pin text, p_id uuid, p_bonus boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare c public.pr_candidature; a jsonb;
begin
  perform public.pr_controlla_pin(p_pin);
  select * into c from public.pr_candidature where id = p_id for update;
  if not found then raise exception 'Richiesta non trovata' using hint = 'candidatura'; end if;
  a := public.pr_salva_agente(p_pin, jsonb_build_object('nome', c.nome, 'telefono', c.telefono, 'bonus', coalesce(p_bonus, true)));
  update public.pr_agenti set canale = c.canale where id = (a->>'id')::uuid;
  delete from public.pr_candidature where id = c.id;
  return a || jsonb_build_object('canale', c.canale);
end $$;

-- per ogni canale: richieste arrivate, agenti approvati, quanti hanno già fatto sedere un tavolo, persone portate
create or replace function public.pr_canali(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return coalesce((
    with r as (select canale, sum(richieste) as n, min(giorno) as dal from public.pr_canali_richieste group by canale),
         g as (select a.canale, count(*) as agenti,
                      count(*) filter (where t.persone > 0) as con_tavolo,
                      coalesce(sum(t.persone), 0) as persone
                 from public.pr_agenti a
                 left join lateral (select coalesce(sum(b.persone), 0) as persone from public.pr_buoni b
                                     where b.agente = a.id and b.stato = 'riscattato') t on true
                where a.canale is not null
                group by a.canale),
         k as (select canale from r union select canale from g)
    select jsonb_agg(jsonb_build_object('canale', k.canale, 'richieste', coalesce(r.n, 0), 'dal', r.dal,
                                        'agenti', coalesce(g.agenti, 0), 'conTavolo', coalesce(g.con_tavolo, 0),
                                        'persone', coalesce(g.persone, 0))
                     order by coalesce(g.con_tavolo, 0) desc, coalesce(g.agenti, 0) desc, coalesce(r.n, 0) desc, k.canale)
      from k left join r using (canale) left join g using (canale)), '[]'::jsonb);
end $$;

grant execute on function
  public.pr_candidatura(text, text, text, text, text), public.pr_canali(text)
to anon, authenticated;

-- controllo
select (select count(*) from public.pr_candidature) as richieste,
       (select count(*) from public.pr_agenti where canale is not null) as agenti_con_canale,
       (select string_agg(p.oid::regprocedure::text, ', ' order by p.proname)
          from pg_proc p where p.proname in ('pr_candidatura', 'pr_canali')) as funzioni;
