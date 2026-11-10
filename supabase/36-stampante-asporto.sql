-- =============================================================================
-- STAMPANTE DEL BANCO (Sunmi V3H): GLI ORDINI D'ASPORTO SI STAMPANO DA SOLI
-- Si esegue DOPO 12-asporto.sql.
-- Ogni ordine d'asporto nuovo entra da solo in una coda di stampa, già impaginato
-- per la carta da 58 mm. L'app "Vico Stampa" sul Sunmi guarda la coda ogni pochi
-- secondi con la password del menu (la stessa del Banco), stampa il foglietto,
-- suona e dice "fatto". Come il tablet di Glovo: non serve toccare niente.
-- Se il cliente annulla un ordine già stampato, esce un foglietto ANNULLATO.
-- Se manca la carta o il Sunmi è spento, i foglietti aspettano ed escono dopo
-- (quelli più vecchi di 8 ore no: sono di un'altra sera).
-- È il foglio per la cucina e il banco, NON uno scontrino: lo scontrino si fa
-- sempre alla cassa di prima, quando il cliente paga al ritiro.
-- Tutto ha il prefisso stampa_ : non cambia niente di quello che c'è già, aggiunge
-- solo un "trigger" sulla tabella asp_ordini che, se qualcosa va storto, si fa da
-- parte e lascia passare l'ordine come prima.
-- Tabelle non leggibili da fuori (RLS senza regole). Si può rieseguire.
-- =============================================================================

-- ---------- tabelle ----------

create table if not exists public.stampa_impostazioni (
  id      int primary key default 1 check (id = 1),
  attiva  boolean not null default true,                    -- stampa automatica accesa
  copie   int     not null default 1 check (copie between 1 and 3),
  visto   timestamptz,                                      -- ultima volta che l'app si è fatta sentire
  stato   text    not null default '',                      -- cosa dice la stampante: pronta, carta, …
  app     text    not null default ''                       -- versione dell'app e modello
);
insert into public.stampa_impostazioni (id) values (1) on conflict (id) do nothing;

create table if not exists public.stampa_coda (
  id        bigint generated always as identity primary key,
  tipo      text not null check (tipo in ('asporto', 'annullato', 'prova')),
  ordine    uuid references public.asp_ordini(id) on delete cascade,
  righe     jsonb not null,               -- il foglietto riga per riga (vedi sotto)
  copie     int  not null default 1,
  creato    timestamptz not null default now(),
  preso     timestamptz,                  -- l'app l'ha preso e lo sta stampando
  stampato  timestamptz,
  saltato   timestamptz,                  -- non va più stampato
  tentativi int  not null default 0
);
create index if not exists stampa_coda_attesa on public.stampa_coda (id) where stampato is null and saltato is null;
create index if not exists stampa_coda_ordine on public.stampa_coda (ordine);

alter table public.stampa_impostazioni enable row level security;
alter table public.stampa_coda         enable row level security;


-- ---------- il foglietto ----------
-- Ogni riga è un oggetto che l'app sa stampare:
--   {"t": testo}                 testo a sinistra (va a capo da solo)
--   "a": "c" | "r"               centrato / a destra
--   "z": 2                       doppio (16 caratteri per riga invece di 32)
--   "b": true                    grassetto
--   "d": "16,00"                 testo in fondo a destra sulla stessa riga (il prezzo)
--   {"sep": "-"}                 una riga intera di trattini (o "=")
--   {"sp": 3}                    righe vuote

create or replace function public.stampa_euro(n numeric) returns text
language sql immutable set search_path = public as $$
  select case when n is null then '' else replace(to_char(round(n, 2), 'FM999990.00'), '.', ',') end
$$;

create or replace function public.stampa_numero(v jsonb) returns numeric
language sql immutable set search_path = public as $$
  select case
    when jsonb_typeof(v) = 'number' then (v #>> '{}')::numeric
    when jsonb_typeof(v) = 'string' and trim(v #>> '{}') ~ '^[0-9]+([.,][0-9]+)?$'
      then replace(trim(v #>> '{}'), ',', '.')::numeric
  end
$$;

create or replace function public.stampa_foglio_asporto(o public.asp_ordini, p_prova boolean) returns jsonb
language plpgsql stable set search_path = public as $$
declare
  f     jsonb := '[]'::jsonb;
  cat   text;
  prima text := null;
  x     record;
  prezzo numeric;
  quando timestamptz := coalesce(o.creato, now());
begin
  f := f || jsonb_build_array(
    jsonb_build_object('t', 'VICO DEL CARMINE', 'a', 'c', 'b', true),
    jsonb_build_object('t', case when p_prova then 'PROVA DI STAMPA' else 'ASPORTO' end, 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'RITIRO ' || o.ritiro, 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'Codice ' || o.codice, 'a', 'c', 'z', 2),
    jsonb_build_object('sep', '-'),
    jsonb_build_object('t', o.nome, 'b', true),
    jsonb_build_object('t', 'Tel ' || o.telefono),
    jsonb_build_object('t', 'Ordinato alle ' || to_char(quando at time zone 'Europe/Rome', 'HH24:MI')
                            || ' del ' || to_char(quando at time zone 'Europe/Rome', 'DD/MM')));
  if o.iscritto is not null then
    f := f || jsonb_build_array(jsonb_build_object('t', 'Socio del Club'));
  end if;
  f := f || jsonb_build_array(jsonb_build_object('sep', '='));

  -- i piatti, raggruppati per portata nell'ordine in cui il cliente li ha scelti
  for x in
    with r as (select v, n from jsonb_array_elements(coalesce(o.righe, '[]'::jsonb)) with ordinality t(v, n)),
         c as (select coalesce(nullif(trim(v->>'categoria'), ''), 'Altro') as cat, min(n) as primo from r group by 1)
    select r.v, coalesce(nullif(trim(r.v->>'categoria'), ''), 'Altro') as cat
      from r join c on c.cat = coalesce(nullif(trim(r.v->>'categoria'), ''), 'Altro')
     order by c.primo, r.n
  loop
    if prima is distinct from x.cat then
      if prima is not null then f := f || jsonb_build_array(jsonb_build_object('sp', 1)); end if;
      f := f || jsonb_build_array(jsonb_build_object('t', '- ' || upper(x.cat) || ' -'));
      prima := x.cat;
    end if;
    prezzo := public.stampa_numero(x.v->'prezzo');
    f := f || jsonb_build_array(jsonb_build_object(
      't', greatest(1, coalesce((x.v->>'qta')::int, 1)) || ' x ' || coalesce(x.v->>'nome', '?'),
      'd', case when prezzo is null then '' else public.stampa_euro(prezzo * greatest(1, coalesce((x.v->>'qta')::int, 1))) end,
      'b', true));
    if coalesce(trim(x.v->>'nota'), '') <> '' then
      f := f || jsonb_build_array(jsonb_build_object('t', '   > ' || trim(x.v->>'nota')));
    end if;
  end loop;

  f := f || jsonb_build_array(
    jsonb_build_object('sep', '='),
    jsonb_build_object('t', 'TOTALE', 'd', public.stampa_euro(o.totale), 'z', 2, 'b', true),
    jsonb_build_object('t', 'Da pagare al ritiro', 'a', 'c'));
  if coalesce(trim(o.nota), '') <> '' then
    f := f || jsonb_build_array(
      jsonb_build_object('sep', '-'),
      jsonb_build_object('t', 'NOTA DEL CLIENTE', 'b', true),
      jsonb_build_object('t', trim(o.nota)));
  end if;
  if p_prova then
    f := f || jsonb_build_array(jsonb_build_object('sep', '-'),
      jsonb_build_object('t', 'È solo una prova: non preparare niente', 'a', 'c', 'b', true));
  end if;
  return f || jsonb_build_array(jsonb_build_object('sp', 4));
end $$;

create or replace function public.stampa_foglio_annullato(o public.asp_ordini) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_array(
    jsonb_build_object('t', '** ANNULLATO **', 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'ASPORTO - RITIRO ' || o.ritiro, 'a', 'c', 'b', true),
    jsonb_build_object('t', 'Codice ' || o.codice, 'a', 'c', 'z', 2),
    jsonb_build_object('t', o.nome, 'a', 'c'),
    jsonb_build_object('sep', '-'),
    jsonb_build_object('t', 'NON PREPARARE', 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'Annullato alle ' || to_char(now() at time zone 'Europe/Rome', 'HH24:MI'), 'a', 'c'),
    jsonb_build_object('sp', 4))
$$;

-- se il foglietto completo non si riesce a fare, ne esce uno minimo: l'ordine non si perde
create or replace function public.stampa_foglio_minimo(o public.asp_ordini) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_array(
    jsonb_build_object('t', 'NUOVO ORDINE ASPORTO', 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'RITIRO ' || coalesce(o.ritiro, '?'), 'a', 'c', 'z', 2, 'b', true),
    jsonb_build_object('t', 'Codice ' || coalesce(o.codice, '?'), 'a', 'c', 'z', 2),
    jsonb_build_object('t', 'Guarda i piatti sul Banco', 'a', 'c'),
    jsonb_build_object('sp', 4))
$$;


-- ---------- il trigger: ogni ordine nuovo va in coda da solo ----------

create or replace function public.stampa_da_asporto() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  imp public.stampa_impostazioni;
  fg  jsonb;
begin
  begin
    select * into imp from public.stampa_impostazioni where id = 1;
    if tg_op = 'INSERT' then
      if coalesce(imp.attiva, false) and new.stato <> 'annullato' then
        begin
          fg := public.stampa_foglio_asporto(new, false);
        exception when others then
          fg := public.stampa_foglio_minimo(new);
        end;
        insert into public.stampa_coda (tipo, ordine, righe, copie)
        values ('asporto', new.id, fg, coalesce(imp.copie, 1));
      end if;
    elsif new.stato = 'annullato' and old.stato is distinct from 'annullato' then
      -- non ancora preso dalla stampante: non serve più
      update public.stampa_coda set saltato = now()
       where ordine = new.id and tipo = 'asporto' and stampato is null and saltato is null and preso is null;
      -- già stampato (o in stampa): esce il foglietto ANNULLATO
      if exists (select 1 from public.stampa_coda where ordine = new.id and tipo = 'asporto' and saltato is null) then
        insert into public.stampa_coda (tipo, ordine, righe, copie)
        values ('annullato', new.id, public.stampa_foglio_annullato(new), 1);
      end if;
    end if;
  exception when others then
    raise warning 'stampa: % (ordine % non messo in coda)', sqlerrm, new.codice;
  end;
  return new;
end $$;

drop trigger if exists stampa_asporto on public.asp_ordini;
create trigger stampa_asporto after insert or update of stato on public.asp_ordini
  for each row execute function public.stampa_da_asporto();


-- ---------- il lavoro vero (non chiamabile da fuori) ----------

create or replace function public.stampa_prendi_dentro(p_stato text, p_app text, p_pronta boolean) returns jsonb
language plpgsql volatile set search_path = public as $$
declare
  imp    public.stampa_impostazioni;
  asp    public.asp_impostazioni;
  lavori jsonb;
  attesa int;
begin
  update public.stampa_impostazioni
     set visto = now(), stato = left(coalesce(p_stato, ''), 40), app = left(coalesce(p_app, ''), 80)
   where id = 1 returning * into imp;
  select * into asp from public.asp_impostazioni where id = 1;

  -- i foglietti di un'altra sera non escono più
  update public.stampa_coda set saltato = now()
   where stampato is null and saltato is null and creato < now() - interval '8 hours';
  select count(*) into attesa from public.stampa_coda where stampato is null and saltato is null;

  lavori := '[]'::jsonb;
  if coalesce(p_pronta, false) then
    with presi as (
      update public.stampa_coda c set preso = now(), tentativi = c.tentativi + 1
       where c.id in (select q.id from public.stampa_coda q
                       where q.stampato is null and q.saltato is null
                         and (q.preso is null or q.preso < now() - interval '90 seconds')
                       order by q.id limit 3
                       for update skip locked)
      returning c.id, c.tipo, c.righe, c.copie)
    select coalesce(jsonb_agg(jsonb_build_object('id', id, 'tipo', tipo, 'righe', righe, 'copie', copie) order by id),
                    '[]'::jsonb)
      into lavori from presi;
  end if;

  return jsonb_build_object('attiva', imp.attiva, 'copie', imp.copie, 'attesa', attesa, 'lavori', lavori,
                            'asporto', jsonb_build_object('aperto', public.asp_aperto(public.pren_oggi()),
                                                          'dalle', asp.dalle, 'alle', asp.alle));
end $$;

create or replace function public.stampa_fatto_dentro(p_id bigint, p_ok boolean) returns jsonb
language plpgsql volatile set search_path = public as $$
begin
  if coalesce(p_ok, false) then
    update public.stampa_coda set stampato = coalesce(stampato, now()) where id = p_id;
  else
    update public.stampa_coda set preso = null where id = p_id and stampato is null;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.stampa_prova_dentro() returns jsonb
language plpgsql volatile set search_path = public as $$
declare o public.asp_ordini;
begin
  if (select count(*) from public.stampa_coda where tipo = 'prova' and creato > now() - interval '10 minutes') >= 5 then
    raise exception 'Troppe prove: aspetta qualche minuto' using hint = 'troppe';
  end if;
  o.codice   := 'PROVA';
  o.ritiro   := to_char((now() + interval '30 minutes') at time zone 'Europe/Rome', 'HH24:MI');
  o.nome     := 'Mario Rossi (prova)';
  o.telefono := '333 1234567';
  o.creato   := now();
  o.righe    := '[{"nome":"Pizza Margherita","prezzo":8,"qta":2,"categoria":"Pizze","nota":"una senza basilico"},
                  {"nome":"Chitarrina allo scoglio","prezzo":16,"qta":1,"categoria":"Primi"},
                  {"nome":"Tiramisù","prezzo":6,"qta":1,"categoria":"Dolci"},
                  {"nome":"Acqua naturale","prezzo":2.5,"qta":1,"categoria":"Bevande"}]';
  o.totale   := 40.5;
  o.nota     := 'Citofono Rossi, secondo piano';
  insert into public.stampa_coda (tipo, righe, copie)
  values ('prova', public.stampa_foglio_asporto(o, true), 1);
  return jsonb_build_object('ok', true);
end $$;

revoke execute on function public.stampa_euro(numeric)                          from public, anon, authenticated;
revoke execute on function public.stampa_numero(jsonb)                          from public, anon, authenticated;
revoke execute on function public.stampa_foglio_asporto(public.asp_ordini, boolean) from public, anon, authenticated;
revoke execute on function public.stampa_foglio_annullato(public.asp_ordini)    from public, anon, authenticated;
revoke execute on function public.stampa_foglio_minimo(public.asp_ordini)       from public, anon, authenticated;
revoke execute on function public.stampa_da_asporto()                           from public, anon, authenticated;
revoke execute on function public.stampa_prendi_dentro(text, text, boolean)     from public, anon, authenticated;
revoke execute on function public.stampa_fatto_dentro(bigint, boolean)          from public, anon, authenticated;
revoke execute on function public.stampa_prova_dentro()                         from public, anon, authenticated;


-- ================= L'APP SUL SUNMI (password del menu, come il Banco) =================

-- ogni pochi secondi: "ci sono foglietti?" (e intanto dice come sta la stampante)
create or replace function public.stampa_prendi(pwd text, p_stato text, p_app text, p_pronta boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if public.verify_pw(pwd) is null then raise exception 'password non valida' using hint = 'password'; end if;
  return public.stampa_prendi_dentro(p_stato, p_app, p_pronta);
end $$;

-- "stampato" (oppure "non ci sono riuscito": torna in coda)
create or replace function public.stampa_fatto(pwd text, p_id bigint, p_ok boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if public.verify_pw(pwd) is null then raise exception 'password non valida' using hint = 'password'; end if;
  return public.stampa_fatto_dentro(p_id, p_ok);
end $$;

-- il tasto "Prova di stampa": un ordine finto fa tutto il giro, dal database alla carta
create or replace function public.stampa_prova(pwd text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if public.verify_pw(pwd) is null then raise exception 'password non valida' using hint = 'password'; end if;
  return public.stampa_prova_dentro();
end $$;

-- dall'app: stampa automatica accesa/spenta e quante copie
create or replace function public.stampa_imposta(pwd text, p_attiva boolean, p_copie int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare imp public.stampa_impostazioni;
begin
  if public.verify_pw(pwd) is null then raise exception 'password non valida' using hint = 'password'; end if;
  update public.stampa_impostazioni
     set attiva = coalesce(p_attiva, attiva),
         copie  = case when p_copie is null then copie else greatest(1, least(3, p_copie)) end
   where id = 1 returning * into imp;
  return jsonb_build_object('attiva', imp.attiva, 'copie', imp.copie);
end $$;

grant execute on function public.stampa_prendi(text, text, text, boolean) to anon, authenticated;
grant execute on function public.stampa_fatto(text, bigint, boolean)      to anon, authenticated;
grant execute on function public.stampa_prova(text)                       to anon, authenticated;
grant execute on function public.stampa_imposta(text, boolean, int)       to anon, authenticated;
