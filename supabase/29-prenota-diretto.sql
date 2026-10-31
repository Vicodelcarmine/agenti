-- =============================================================================
-- PRENOTA DIRETTO — DALLE EMAIL DI THEFORK AL WHATSAPP (si esegue DOPO 28-frecce-prenotazioni.sql)
-- Uno script di Google nell'account vicodelcarmine1@gmail.com (MENU/collegamento-thefork) legge
-- le email "Nuova prenotazione" di TheFork e le manda qui (tf_ricevi, con una chiave sua):
-- nome, telefono, email, persone, promozione, sera. La lista si riempie sempre.
-- Il WhatsApp parte SOLO con l'interruttore acceso (camp_campagne.wa_attivo, di base spento) e il
-- modello approvato da Meta, una volta sola per numero, dalle 10 alle 20, mai di sabato, a chi:
--   · non ha mai usato il 50%                 · ha un cellulare italiano
--   · ha prenotato per un'altra sera (non per stasera, e mai per un sabato)
--   · non ha scritto STOP                     · non ha già ricevuto una campagna
--   · non ha già prenotato dal sito           · quella sera sul sito trova posto
-- Dal bottone arriva alla sua pagina (vicodelcarmine.it/regalo/?c=CODICE): entra nel Club, ha
-- l'offerta (camp_contatti.premio_fisso, senza sorteggio) e prenota con sera e persone già pronte.
-- Dopo la prenotazione per la stessa sera la pagina gli chiede di annullare l'altra.
-- Il ristorante NON annulla mai su TheFork (contratto, Offerte Speciali 2.1).
-- Si può rieseguire: non cancella niente e non riaccende l'interruttore.
-- =============================================================================

-- ---------- tabelle ----------
create table if not exists public.tf_config (
  id           int primary key default 1 check (id = 1),
  chiave_hash  text,                               -- impronta della chiave dello script (mai la chiave)
  chiave_quando timestamptz,
  ultimo_giro  timestamptz                         -- l'ultima volta che lo script ha chiamato
);
insert into public.tf_config (id) values (1) on conflict (id) do nothing;

create table if not exists public.tf_email (
  id        text primary key,                      -- reservationId del link dell'email
  email_id  text,
  ricevuta  timestamptz not null default now(),
  nome      text not null default '',
  telefono  text,                                  -- col prefisso, come club_telefono()
  email     text,
  persone   int  not null default 2,
  promo     text not null default '',
  sconto    int  not null default 0,               -- 30 = 30%, 0 = senza sconto
  sera      date,
  stato     text not null default 'pronta' check (stato in ('pronta', 'esclusa', 'inviata', 'saltata', 'passata')),
  motivo    text,                                  -- perché esclusa o saltata
  contatto  uuid references public.camp_contatti(id) on delete set null,
  creato    timestamptz not null default now()
);
create index if not exists tf_email_stato on public.tf_email (stato, ricevuta);
create index if not exists tf_email_telefono on public.tf_email (telefono, sera);

-- chi ha usato il 50% anche una volta: solo l'impronta del numero, mai il numero
create table if not exists public.tf_esclusi (
  impronta text primary key,
  creato   timestamptz not null default now()
);

alter table public.tf_config  enable row level security;
alter table public.tf_email   enable row level security;
alter table public.tf_esclusi enable row level security;

-- l'offerta decisa da noi (niente sorteggio) e la sera già pronta nel modulo
alter table public.camp_contatti
  add column if not exists premio_fisso text,
  add column if not exists sera         date,
  add column if not exists persone      int;


-- ---------- la campagna: spenta finché non la accende il titolare ----------
insert into public.camp_campagne (id, nome, sere, scopri_entro, sostituisce_benvenuto, wa_attivo, wa_modello, wa_giorni, wa_max_giorno)
values ('diretto-thefork', 'Prenota diretto · clienti TheFork', 15, null, true, false, 'prenota_diretto', 3, 20)
on conflict (id) do nothing;

insert into public.camp_premi (campagna, id, emoji, nome, descr, persone, peso, limite, ordine) values
  ('diretto-thefork', 'TRENTA_PROSECCO', '🥂',
   '{"it":"30% sul menù alla carta + prosecco di benvenuto","en":"30% off the à la carte menu + welcome prosecco"}',
   '{"it":"30% di sconto sul menù alla carta per tutto il tavolo (bevande e menù fissi esclusi) e un calice di prosecco di benvenuto a testa, fino a 4 persone.","en":"30% off the à la carte menu for your whole table (drinks and set menus excluded) and a welcome glass of prosecco each, up to 4 people."}',
   4, 1, null, 1),
  ('diretto-thefork', 'PROSECCO', '🥂',
   '{"it":"Prosecco di benvenuto per il tavolo","en":"Welcome prosecco for your table"}',
   '{"it":"Un calice di prosecco di benvenuto a testa, fino a 4 persone.","en":"A welcome glass of prosecco each, up to 4 people."}',
   4, 1, null, 2)
on conflict (campagna, id) do nothing;


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- l'impronta di un numero: le stesse cifre danno sempre la stessa impronta (come prepara.py, accorciata)
create or replace function public.tf_impronta(tel text) returns text
language sql immutable set search_path = public as $$
  select case when regexp_replace(coalesce(tel, ''), '\D', '', 'g') <> ''
    then left(encode(sha256(convert_to(regexp_replace(tel, '\D', '', 'g'), 'UTF8')), 'hex'), 20) end
$$;

-- a questo numero è già arrivata una campagna, o ha già scoperto un regalo, o si è tolto?
create or replace function public.tf_gia_contattato(tel text) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from public.wa_uscita u
                  where u.telefono = tel and u.tipo = 'campagna' and u.stato not in ('saltato', 'errore'))
      or exists (select 1 from public.camp_contatti c
                  where c.telefono = tel and (c.premio is not null or c.disiscritto is not null or c.wa_quando is not null))
$$;

-- quella sera sul sito c'è posto per n persone, almeno a un orario?
create or replace function public.tf_posto(s date, n int) returns boolean
language sql stable security definer set search_path = public as $$
  select n <= (select max_persone from public.pren_impostazioni where id = 1)
     and exists (select 1
                   from jsonb_array_elements(public.pren_disponibilita()->'giorni') g,
                        jsonb_array_elements(g->'turni') t
                  where g->>'sera' = s::text and not coalesce((g->>'chiuso')::boolean, false)
                    and (t->>'liberi')::int >= n)
$$;

revoke execute on function public.tf_impronta(text)         from public, anon, authenticated;
revoke execute on function public.tf_gia_contattato(text)   from public, anon, authenticated;
revoke execute on function public.tf_posto(date, int)       from public, anon, authenticated;


-- ================= LO SCRIPT DI GOOGLE (con la sua chiave) =================

-- p_righe: [{ id, emailId, quando, nome, telefono, email, persone, promo, sera }].
-- Una prenotazione già arrivata non cambia: mandarla di nuovo non fa danni.
create or replace function public.tf_ricevi(p_chiave text, p_righe jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  h     text;
  r     jsonb;
  rid   text;
  tel   text;
  sc    int;
  s     date;
  q     timestamptz;
  n     int;
  mot   text;
  nuove int := 0;
begin
  select chiave_hash into h from public.tf_config where id = 1;
  if h is null or coalesce(p_chiave, '') = ''
     or encode(sha256(convert_to(p_chiave, 'UTF8')), 'hex') <> h then
    raise exception 'Chiave della posta non valida' using hint = 'chiave';
  end if;
  update public.tf_config set ultimo_giro = now() where id = 1;

  for r in select value from jsonb_array_elements(coalesce(p_righe, '[]'::jsonb)) loop
    rid := left(nullif(trim(coalesce(r->>'id', '')), ''), 80);
    continue when rid is null or exists (select 1 from public.tf_email where id = rid);
    tel := public.club_telefono(r->>'telefono');
    sc  := coalesce(substring(coalesce(r->>'promo', '') from '(\d{1,3})\s*%')::int, 0);
    n   := greatest(1, least(coalesce(nullif(regexp_replace(coalesce(r->>'persone', ''), '\D', '', 'g'), '')::int, 2), 200));
    begin s := nullif(r->>'sera', '')::date; exception when others then s := null; end;
    begin q := nullif(r->>'quando', '')::timestamptz; exception when others then q := null; end;
    -- il 50% esclude per sempre quel numero, anche dalle prenotazioni future
    if sc >= 50 and tel is not null then
      insert into public.tf_esclusi (impronta) values (public.tf_impronta(tel)) on conflict (impronta) do nothing;
    end if;
    mot := case
      when sc >= 50 then 'ha prenotato col 50%'
      when exists (select 1 from public.tf_esclusi x where x.impronta = public.tf_impronta(tel)) then 'ha già usato il 50%'
      when tel is null or tel !~ '^\+393\d{8,10}$' then 'non è un cellulare italiano'
      when s is null then 'email senza data'
      when extract(dow from s)::int = any(public.camp_giorni_no()) then 'prenotazione di sabato'
    end;
    insert into public.tf_email (id, email_id, ricevuta, nome, telefono, email, persone, promo, sconto, sera, stato, motivo)
    values (rid, left(r->>'emailId', 80), coalesce(q, now()), left(trim(coalesce(r->>'nome', '')), 120), tel,
            nullif(lower(left(trim(coalesce(r->>'email', '')), 200)), ''), n, left(trim(coalesce(r->>'promo', '')), 200), sc, s,
            case when mot is null then 'pronta' else 'esclusa' end, mot)
    on conflict (id) do nothing;
    nuove := nuove + 1;
  end loop;
  return jsonb_build_object('nuove', nuove);
end $$;

grant execute on function public.tf_ricevi(text, jsonb) to anon, authenticated;


-- ================= PER L'OROLOGIO (solo service_role) =================

-- ogni giro: chi è pronto riceve il WhatsApp, chi non può più riceverlo resta nella lista col motivo.
-- Con l'interruttore spento non parte niente: quando si accende, valgono solo le sere ancora da venire.
create or replace function public.tf_pianifica() returns int
language plpgsql volatile security definer set search_path = public as $$
declare
  k     public.camp_campagne;
  x     public.tf_email;
  oggi  date := public.pren_oggi();
  resta int;
  n     int := 0;
  mot   text;
  cod   text;
  cid   uuid;
  pr    text;
begin
  update public.tf_email set stato = 'passata', motivo = 'la sera è passata prima dell''invio'
   where stato = 'pronta' and sera < oggi;
  -- come le prenotazioni: 24 mesi
  delete from public.tf_email where creato < now() - interval '24 months';

  select * into k from public.camp_campagne where id = 'diretto-thefork';
  if k.id is null or not k.attiva or not k.wa_attivo or not public.camp_wa_ora_buona(now())
     or coalesce((select numero_id from public.wa_config where id = 1), '') = '' then
    return 0;
  end if;
  resta := k.wa_max_giorno - (select count(*) from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                               where c.campagna = k.id and u.tipo = 'campagna'
                                 and u.creato >= (oggi + time '00:00') at time zone 'Europe/Rome');

  for x in select * from public.tf_email where stato = 'pronta' order by ricevuta for update skip locked loop
    exit when resta <= 0;
    mot := case
      when x.sera <= oggi then 'prenotazione per la sera stessa'
      when exists (select 1 from public.tf_esclusi e where e.impronta = public.tf_impronta(x.telefono)) then 'ha già usato il 50%'
      when exists (select 1 from public.wa_contatti w where w.telefono = x.telefono and w.stop) then 'ha scritto STOP'
      when public.tf_gia_contattato(x.telefono) then 'già contattato da una campagna'
      when exists (select 1 from public.pren_prenotazioni p
                    where p.telefono = x.telefono and p.sera = x.sera and p.stato <> 'annullata') then 'ha già prenotato dal sito'
      when not public.tf_posto(x.sera, x.persone) then 'quella sera sul sito non c''è posto'
    end;
    if mot is not null then
      update public.tf_email set stato = 'saltata', motivo = mot where id = x.id;
      continue;
    end if;

    pr := case when x.sconto > 0 then 'TRENTA_PROSECCO' else 'PROSECCO' end;
    loop
      cod := public.pr_casuale(10);
      exit when not exists (select 1 from public.camp_contatti where codice = cod);
    end loop;
    insert into public.camp_contatti (campagna, codice, nome, telefono, email, premio_fisso, sera, persone, wa_quando)
    values (k.id, cod, x.nome, x.telefono, x.email, pr, x.sera, x.persone, now())
    returning id into cid;
    insert into public.wa_uscita (telefono, tipo, modello, parametri, link, lingua, contatto)
    values (x.telefono, 'campagna', k.wa_modello,
            jsonb_build_array(public.camp_nome_breve(x.nome), public.club_data(x.sera, 'it'),
                              case when pr = 'TRENTA_PROSECCO' then 'il 30% di sconto sul menù alla carta e il prosecco di benvenuto'
                                   else 'il prosecco di benvenuto offerto dalla casa' end),
            cod, 'it', cid);
    update public.tf_email set stato = 'inviata', contatto = cid where id = x.id;
    n := n + 1;
    resta := resta - 1;
  end loop;
  return n;
end $$;

revoke execute on function public.tf_pianifica() from public, anon, authenticated;
grant execute on function public.tf_pianifica() to service_role;


-- ---------- la campagna regalo non riscrive a chi ha già ricevuto questa ----------
-- (19-campagna-whatsapp.sql, con in più il controllo tf_gia_contattato)
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


-- ================= CLIENTE (pagina vicodelcarmine.it/regalo) =================

-- apre il link: in più l'offerta già decisa, la sera e le persone della sua prenotazione
create or replace function public.camp_vista(p_codice text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare c public.camp_contatti; k public.camp_campagne;
begin
  update public.camp_contatti set aperto = coalesce(aperto, now()), aperture = aperture + 1
   where codice = upper(trim(coalesce(p_codice, ''))) returning * into c;
  if c.id is null then raise exception 'Questo link non è valido' using hint = 'codice'; end if;
  select * into k from public.camp_campagne where id = c.campagna;
  return jsonb_build_object(
    'nome', c.nome, 'telefono', c.telefono, 'email', c.email,
    'socio', exists (select 1 from public.club_iscritti i
                      where i.telefono = c.telefono or (c.email is not null and lower(i.email) = lower(c.email))),
    'aperta', k.attiva and (k.scopri_entro is null or public.pr_sera(now()) <= k.scopri_entro),
    'sere', k.sere, 'scopriEntro', k.scopri_entro,
    'giorniNo', (select to_jsonb(giorni_no || giorni_chiusura) from public.club_impostazioni where id = 1),
    'premi', (select jsonb_agg(jsonb_build_object('emoji', p.emoji, 'nome', p.nome) order by p.ordine)
                from public.camp_premi p where p.campagna = c.campagna and p.attivo and p.peso > 0),
    'offerta', case when c.premio_fisso is not null then jsonb_build_object(
      'sera', c.sera, 'persone', c.persone,
      'premio', (select jsonb_build_object('emoji', p.emoji, 'nome', p.nome, 'descr', p.descr)
                   from public.camp_premi p where p.campagna = c.campagna and p.id = c.premio_fisso)) end,
    'premio', public.camp_vista_premio(c));
end $$;

-- scopre il premio: se è già deciso (premio_fisso) è quello, altrimenti si sorteggia
create or replace function public.camp_scopri(p_codice text, p_chiave text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  c   public.camp_contatti;
  k   public.camp_campagne;
  i   public.club_iscritti;
  imp public.club_impostazioni;
  pr  public.camp_premi;
  g   int[];
  d1  date;
  d2  date;
  cod text;
begin
  select * into c from public.camp_contatti where codice = upper(trim(coalesce(p_codice, ''))) for update;
  if c.id is null then raise exception 'Questo link non è valido' using hint = 'codice'; end if;
  -- l'ha già scoperto: ritrova lo stesso
  if c.club_codice is not null and exists (select 1 from public.club_premi where codice = c.club_codice) then
    return jsonb_build_object('nome', c.nome, 'premio', public.camp_vista_premio(c), 'nuovo', false);
  end if;
  select * into k from public.camp_campagne where id = c.campagna;
  if not k.attiva or (k.scopri_entro is not null and public.pr_sera(now()) > k.scopri_entro) then
    raise exception 'La campagna è finita' using hint = 'finita';
  end if;
  if coalesce(p_chiave, '') <> '' then
    select * into i from public.club_iscritti where chiave = p_chiave;
  end if;
  if i.id is null then
    select * into i from public.club_iscritti
     where telefono = c.telefono or (c.email is not null and lower(email) = lower(c.email))
     order by creato limit 1;
  end if;
  if i.id is null then raise exception 'Prima entra nel Club' using hint = 'club'; end if;
  if exists (select 1 from public.camp_contatti x
              where x.campagna = c.campagna and x.iscritto = i.id and x.id <> c.id and x.club_codice is not null) then
    raise exception 'Hai già scoperto il tuo regalo' using hint = 'gia';
  end if;

  -- un'estrazione alla volta per campagna: i premi a numero chiuso non sforano
  perform pg_advisory_xact_lock(hashtext('camp:' || c.campagna));
  select * into pr from public.camp_premi p
   where p.campagna = c.campagna and p.attivo and p.peso > 0
     and (c.premio_fisso is null or p.id = c.premio_fisso)
     and (p.limite is null
          or (select count(*) from public.camp_contatti x where x.campagna = p.campagna and x.premio = p.id) < p.limite)
   order by power(random(), 1.0 / p.peso) desc limit 1;
  if pr.id is null then raise exception 'I regali sono finiti' using hint = 'finiti'; end if;

  -- vale da stasera (o dalla prima sera buona) per k.sere sere: sabato e chiusura non contano
  select * into imp from public.club_impostazioni where id = 1;
  g  := imp.giorni_no || imp.giorni_chiusura;
  d1 := public.club_piu_sere(public.pr_sera(now()), 1, g);
  d2 := public.club_piu_sere(d1, k.sere, g);
  loop
    cod := public.pr_casuale(7);
    exit when not exists (select 1 from public.club_premi where codice = cod);
  end loop;
  insert into public.club_premi (codice, iscritto, tipo, emoji, nome, persone, dal, al, giorni_no, solo_prenotati)
  values (cod, i.id, 'regalo', pr.emoji, pr.nome, pr.persone, d1, d2, g, true);
  -- entrato nel Club dalla campagna (nell'ultima ora): un regalo solo, questo al posto del benvenuto
  if k.sostituisce_benvenuto and i.creato > now() - interval '1 hour' then
    delete from public.club_premi where iscritto = i.id and tipo = 'benvenuto' and usato is null;
  end if;
  update public.camp_contatti set premio = pr.id, premio_quando = now(), iscritto = i.id, club_codice = cod
   where id = c.id returning * into c;
  return jsonb_build_object('nome', c.nome, 'premio', public.camp_vista_premio(c), 'nuovo', true);
end $$;


-- ================= TITOLARE (dashboard, col PIN) =================

-- la prenotazione: in più se lo stesso numero ha anche TheFork per quella sera (27-novita-prenotazioni.sql)
create or replace function public.pren_vista_titolare(p public.pren_prenotazioni) returns jsonb
language sql stable set search_path = public as $$
  select public.pren_vista(p) || jsonb_build_object('id', p.id, 'telefono', p.telefono, 'fonte', p.fonte,
         'socio', p.iscritto is not null, 'iscritto', p.iscritto, 'creato', p.creato,
         'annullata', p.annullata, 'annullataDa', p.annullata_da, 'waErrore', p.wa_errore, 'waQuando', p.wa_quando,
         'waAttivato', p.wa_attivato, 'voto', p.voto,
         'regalo', (select jsonb_build_object('codice', r.codice, 'emoji', r.emoji, 'nome', r.nome,
                                              'persone', r.persone, 'usato', r.usato)
                      from public.club_premi r
                     where p.iscritto is not null and p.fonte = 'sito' and r.iscritto = p.iscritto and r.tipo = 'regalo'
                       and p.sera between r.dal and r.al and (r.usato is null or r.sera_uso = p.sera)
                     order by r.creato limit 1),
         'suThefork', p.fonte = 'sito' and p.stato <> 'annullata'
                      and exists (select 1 from public.tf_email t where t.telefono = p.telefono and t.sera = p.sera),
         'conversazione', public.pren_conversazione(p.id),
         'finestra', exists (select 1 from public.wa_contatti c
                              where c.telefono = p.telefono and c.ultimo_in > now() - interval '23 hours 50 minutes' and not c.stop),
         'novita', jsonb_build_object(
           'nuova',     exists (select 1 from public.pren_avvisi a where a.prenotazione = p.id and a.tipo = 'nuova' and a.visto is null),
           'annullata', exists (select 1 from public.pren_avvisi a where a.prenotazione = p.id and a.tipo = 'annullata' and a.visto is null),
           'messaggi',  (select count(*) from public.pren_avvisi a where a.prenotazione = p.id and a.tipo = 'whatsapp' and a.visto is null)))
$$;
revoke execute on function public.pren_vista_titolare(public.pren_prenotazioni) from public, anon, authenticated;

-- come sta andando: posta collegata, clienti letti, messaggi partiti, chi si è spostato sul sito
create or replace function public.tf_panoramica(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare cfg public.tf_config; oggi date := public.pren_oggi();
begin
  perform public.pr_controlla_pin(p_pin);
  select * into cfg from public.tf_config where id = 1;
  return jsonb_build_object(
    'collegata', cfg.chiave_hash is not null, 'chiaveQuando', cfg.chiave_quando, 'ultimoGiro', cfg.ultimo_giro,
    'ultimaEmail', (select max(ricevuta) from public.tf_email),
    'lette',     (select count(*) from public.tf_email),
    'trenta',    (select count(*) from public.tf_email where sconto between 1 and 49),
    'senza',     (select count(*) from public.tf_email where sconto = 0),
    'cinquanta', (select count(*) from public.tf_email where sconto >= 50),
    'esclusi',   (select count(*) from public.tf_email where stato = 'esclusa'),
    'pronte',    (select count(*) from public.tf_email where stato = 'pronta'),
    'inviate',   (select count(*) from public.tf_email where stato = 'inviata'),
    'saltate',   (select count(*) from public.tf_email where stato in ('saltata', 'passata')),
    'impronte',  (select count(*) from public.tf_esclusi),
    'motivi',    coalesce((select jsonb_agg(jsonb_build_object('motivo', m.motivo, 'n', m.n) order by m.n desc)
                             from (select motivo, count(*) n from public.tf_email where motivo is not null group by motivo) m), '[]'::jsonb),
    'spostati',  (select count(*) from public.tf_email t
                   where t.stato = 'inviata'
                     and exists (select 1 from public.pren_prenotazioni p
                                  where p.telefono = t.telefono and p.fonte = 'sito' and p.stato <> 'annullata' and p.creato >= t.creato)),
    'doppioni',  (select count(*) from public.tf_email t
                   where t.sera >= oggi
                     and exists (select 1 from public.pren_prenotazioni p
                                  where p.telefono = t.telefono and p.sera = t.sera and p.fonte = 'sito' and p.stato <> 'annullata')));
end $$;

-- l'elenco dei clienti letti dalle email, dagli ultimi
create or replace function public.tf_elenco(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'ricevuta', t.ricevuta, 'nome', t.nome, 'telefono', t.telefono, 'email', t.email, 'persone', t.persone,
      'promo', t.promo, 'sconto', t.sconto, 'sera', t.sera, 'stato', t.stato, 'motivo', t.motivo,
      'attivata', c.premio is not null,
      'prenotato', exists (select 1 from public.pren_prenotazioni p
                            where p.telefono = t.telefono and p.fonte = 'sito' and p.stato <> 'annullata' and p.creato >= t.creato))
      order by t.ricevuta desc)
      from (select * from public.tf_email order by ricevuta desc limit 200) t
      left join public.camp_contatti c on c.id = t.contatto), '[]'::jsonb);
end $$;

-- una chiave nuova per lo script di Google: si vede UNA volta sola (qui si tiene solo l'impronta)
create or replace function public.tf_nuova_chiave(p_pin text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare k text := public.pr_casuale(40);
begin
  perform public.pr_controlla_pin(p_pin);
  update public.tf_config set chiave_hash = encode(sha256(convert_to(k, 'UTF8')), 'hex'), chiave_quando = now() where id = 1;
  return jsonb_build_object('chiave', k);
end $$;

-- una prova vera al numero del titolare, anche con l'interruttore spento: stesso modello e link vero.
-- Passa dalla coda come risposta (così non aspetta le ore buone); non tocca la lista dei clienti.
create or replace function public.tf_prova(p_pin text, p_telefono text, p_sconto boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  k   public.camp_campagne;
  tel text := public.club_telefono(p_telefono);
  pr  text := case when coalesce(p_sconto, true) then 'TRENTA_PROSECCO' else 'PROSECCO' end;
  s   date;
  cod text;
begin
  perform public.pr_controlla_pin(p_pin);
  if tel is null then raise exception 'Numero non valido' using hint = 'telefono'; end if;
  select * into k from public.camp_campagne where id = 'diretto-thefork';
  s := public.club_piu_sere(public.pren_oggi(), 2, public.camp_giorni_no());
  loop
    cod := public.pr_casuale(10);
    exit when not exists (select 1 from public.camp_contatti where codice = cod);
  end loop;
  insert into public.camp_contatti (campagna, codice, nome, telefono, premio_fisso, sera, persone)
  values (k.id, cod, 'Prova', tel, pr, s, 2);
  insert into public.wa_uscita (telefono, tipo, modello, parametri, link, lingua)
  values (tel, 'risposta', k.wa_modello,
          jsonb_build_array('Prova', public.club_data(s, 'it'),
                            case when pr = 'TRENTA_PROSECCO' then 'il 30% di sconto sul menù alla carta e il prosecco di benvenuto'
                                 else 'il prosecco di benvenuto offerto dalla casa' end),
          cod, 'it');
  return jsonb_build_object('codice', cod);
end $$;

grant execute on function public.tf_panoramica(text), public.tf_elenco(text), public.tf_nuova_chiave(text),
  public.tf_prova(text, text, boolean) to anon, authenticated;


-- ================= OROLOGIO =================
-- ogni 5 minuti: la coda la manda poi il lavoro "whatsapp-invia" (ogni 2 minuti)
select cron.schedule('tf-pianifica', '*/5 * * * *', $tf$ select public.tf_pianifica(); $tf$);
