-- =============================================================================
-- PORTALE CAPODANNOFIRENZE.IT: invio in due passaggi (si esegue DOPO 32-portale-capodanno.sql)
-- Così la chiave non sta mai nella pagina del portale:
-- 1. la pagina del gestionale (nel browser dell'app) legge l'elenco e lo lascia qui con
--    portale_deposita(righe): finisce in una "cassetta" che nessuno può leggere dal sito
--    e torna solo un'impronta (sha256 dell'elenco);
-- 2. sul Mac un comando con la chiave (collegamento-portale/importa.sh) chiama
--    pren_portale_importa(chiave, impronta): prende quella cassetta, la passa a
--    pren_da_portale e la svuota. Una cassetta vale 30 minuti; dopo un'ora si cancella da sola.
-- Si può rieseguire.
-- =============================================================================

create table if not exists public.portale_deposito (
  impronta text primary key,
  righe    jsonb not null,
  creato   timestamptz not null default now()
);
alter table public.portale_deposito enable row level security;

create or replace function public.portale_deposita(p_righe jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare imp text;
begin
  if p_righe is null or jsonb_typeof(p_righe) <> 'array' or jsonb_array_length(p_righe) > 1000
     or length(p_righe::text) > 600000 then
    raise exception 'Elenco non valido' using hint = 'righe';
  end if;
  delete from public.portale_deposito where creato < now() - interval '1 hour';
  -- al massimo 20 cassette: le più vecchie lasciano il posto
  delete from public.portale_deposito
   where impronta in (select impronta from public.portale_deposito order by creato desc offset 19);
  imp := encode(sha256(convert_to(p_righe::text, 'UTF8')), 'hex');
  insert into public.portale_deposito (impronta, righe) values (imp, p_righe)
  on conflict (impronta) do update set creato = now();
  return jsonb_build_object('ok', true, 'impronta', imp, 'righe', jsonb_array_length(p_righe));
end $$;
revoke execute on function public.portale_deposita(jsonb) from public;
grant  execute on function public.portale_deposita(jsonb) to anon, authenticated, service_role;

create or replace function public.pren_portale_importa(p_chiave text, p_impronta text, p_prova boolean default false) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v jsonb;
  r jsonb;
begin
  select righe into v from public.portale_deposito
   where impronta = coalesce(p_impronta, '') and creato > now() - interval '30 minutes';
  if v is null then raise exception 'Invio non trovato' using hint = 'impronta'; end if;
  r := public.pren_da_portale(p_chiave, v, p_prova);     -- controlla la chiave; con prova annulla tutto
  delete from public.portale_deposito where impronta = p_impronta;
  return r;
end $$;
revoke execute on function public.pren_portale_importa(text, text, boolean) from public;
grant  execute on function public.pren_portale_importa(text, text, boolean) to anon, authenticated, service_role;
