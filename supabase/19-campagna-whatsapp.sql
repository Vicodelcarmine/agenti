-- =============================================================================
-- CAMPAGNA REGALO — IL WHATSAPP DI RICHIAMO (si esegue DOPO 18-campagna-regalo.sql)
-- L'email parte a gruppi (Brevo, un gruppo al giorno). N giorni dopo l'email del suo gruppo
-- (camp_campagne.wa_giorni, sabato e chiusura non contano) parte un WhatsApp col modello
-- approvato (camp_campagne.wa_modello: {{1}} nome, bottone col link personale ?c=CODICE)
-- solo a chi:
--   · non ha ancora scoperto il regalo        · non si è tolto dalle email (disiscritto)
--   · non ha scritto STOP su WhatsApp          · non l'ha già ricevuto
-- Si manda solo dalle 10 alle 20 e mai nei giorni esclusi (sabato), al massimo
-- camp_campagne.wa_max_giorno messaggi al giorno. Il titolare lo accende dal cruscotto
-- (Club → Campagne regalo) quando Meta ha approvato il modello.
-- · camp_gruppi: quando è partita l'email di ogni gruppo (si riempie quando si programma su Brevo)
-- · camp_contatti.gruppo: il gruppo di ogni contatto (lo stesso attributo GRUPPO di Brevo)
-- · chi si toglie dalle email lo dice Brevo alla funzione "brevo-webhook" → camp_brevo_evento
-- Tutto passa dalla coda wa_uscita (17-whatsapp-dialogo.sql), tipo 'campagna'.
-- Si può rieseguire: non cancella niente.
-- =============================================================================

-- ---------- tabelle ----------
alter table public.camp_campagne
  add column if not exists wa_attivo     boolean not null default false,
  add column if not exists wa_modello    text    not null default 'regalo_sorpresa_richiamo',
  add column if not exists wa_giorni     int     not null default 3   check (wa_giorni between 1 and 30),
  add column if not exists wa_max_giorno int     not null default 120 check (wa_max_giorno between 1 and 240);

alter table public.camp_contatti add column if not exists gruppo int;

create table if not exists public.camp_gruppi (
  campagna     text not null references public.camp_campagne(id) on delete cascade,
  gruppo       int  not null,
  email_quando timestamptz not null,           -- quando parte (o è partita) l'email di quel gruppo
  primary key (campagna, gruppo)
);
alter table public.camp_gruppi enable row level security;

alter table public.wa_uscita
  add column if not exists contatto  uuid references public.camp_contatti(id) on delete set null,
  add column if not exists link      text,                        -- il pezzo variabile del bottone col link
  add column if not exists tentativi int not null default 0;
create index if not exists wa_uscita_contatto on public.wa_uscita (contatto);

do $$
declare c text;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.wa_uscita'::regclass and contype = 'c' and pg_get_constraintdef(oid) like '%tipo%'
  loop
    execute format('alter table public.wa_uscita drop constraint %I', c);
  end loop;
end $$;
alter table public.wa_uscita add constraint wa_uscita_tipo_check
  check (tipo in ('prosecco', 'club', 'voto', 'grazie', 'basso', 'stop', 'start', 'risposta', 'campagna'));


-- ---------- funzioni di servizio (non chiamabili da fuori) ----------

-- i giorni della settimana esclusi (sabato e chiusura)
create or replace function public.camp_giorni_no() returns int[]
language sql stable set search_path = public as $$
  select coalesce((select giorni_no || giorni_chiusura from public.club_impostazioni where id = 1), '{6}'::int[])
$$;

-- si può mandare adesso un messaggio della campagna? dalle 10 alle 20, mai nei giorni esclusi
create or replace function public.camp_wa_ora_buona(t timestamptz) returns boolean
language sql stable set search_path = public as $$
  select extract(hour from t at time zone 'Europe/Rome') between 10 and 19
     and not (extract(dow from t at time zone 'Europe/Rome')::int = any(public.camp_giorni_no()))
$$;

-- quando parte il WhatsApp di un gruppo: N giorni buoni dopo l'email, alla stessa ora
create or replace function public.camp_quando_wa(email timestamptz, giorni int) returns timestamptz
language sql stable set search_path = public as $$
  select (public.club_piu_sere((email at time zone 'Europe/Rome')::date + 1, giorni, public.camp_giorni_no())
          + (email at time zone 'Europe/Rome')::time) at time zone 'Europe/Rome'
$$;

-- "GIULIA ROSSI" → "Giulia" (vuoto: un saluto, perché il modello non accetta parametri vuoti)
create or replace function public.camp_nome_breve(nome text) returns text
language sql immutable set search_path = public as $$
  select coalesce(nullif(initcap(lower(split_part(trim(coalesce(nome, '')), ' ', 1))), ''), '👋')
$$;

revoke execute on function public.camp_giorni_no()                    from public, anon, authenticated;
revoke execute on function public.camp_wa_ora_buona(timestamptz)      from public, anon, authenticated;
revoke execute on function public.camp_quando_wa(timestamptz, int)    from public, anon, authenticated;
revoke execute on function public.camp_nome_breve(text)               from public, anon, authenticated;


-- ---------- per le funzioni e l'orologio (solo service_role) ----------

-- ogni giro: mette in coda i WhatsApp dei gruppi arrivati al loro giorno
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

-- un invio della campagna non è andato: si riprova fra un'ora (3 tentativi in tutto)
create or replace function public.camp_rimanda(p_id bigint, p_errore text) returns void
language sql volatile security definer set search_path = public as $$
  update public.wa_uscita
     set stato = case when tentativi < 2 then 'in_coda' else 'errore' end,
         quando = now() + interval '1 hour', tentativi = tentativi + 1, errore = left(p_errore, 300)
   where id = p_id and tipo = 'campagna';
$$;

-- Brevo dice che qualcuno si è tolto dalle email (o le ha segnate come spam): niente WhatsApp
create or replace function public.camp_brevo_evento(p_email text, p_evento text) returns int
language plpgsql volatile security definer set search_path = public as $$
declare n int := 0;
begin
  if coalesce(p_email, '') = '' or lower(coalesce(p_evento, '')) !~ '(unsub|spam|complaint)' then return 0; end if;
  with tolti as (
    update public.camp_contatti set disiscritto = coalesce(disiscritto, now())
     where lower(email) = lower(trim(p_email))
    returning id)
  update public.wa_uscita set stato = 'saltato', errore = 'disiscritto dalle email'
   where contatto in (select id from tolti) and stato = 'in_coda';
  select count(*) into n from public.camp_contatti where lower(email) = lower(trim(p_email)) and disiscritto is not null;
  return n;
end $$;

-- la coda (17-whatsapp-dialogo.sql) con i messaggi della campagna: in più il link del bottone,
-- solo nelle ore buone, solo con la campagna accesa, e si salta chi nel frattempo ha scoperto
-- il regalo o si è tolto dalle email
create or replace function public.wa_prendi_uscita(n int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare cfg public.wa_config; r record; lista jsonb := '[]'::jsonb; salta text;
begin
  select * into cfg from public.wa_config where id = 1;
  for r in
    select u.*, c.stop, c.ultimo_in, p.stato as pren_stato, p.voto, p.nome as pren_nome,
           cc.premio as camp_premio, cc.disiscritto as camp_disiscritto
      from public.wa_uscita u
      left join public.wa_contatti c on c.telefono = u.telefono
      left join public.pren_prenotazioni p on p.id = u.prenotazione
      left join public.camp_contatti cc on cc.id = u.contatto
     where u.stato = 'in_coda' and u.quando <= now()
       and (u.tipo <> 'campagna'
            or (public.camp_wa_ora_buona(now())
                and exists (select 1 from public.camp_campagne k where k.id = cc.campagna and k.attiva and k.wa_attivo)))
     order by u.quando limit n for update of u skip locked
  loop
    salta := case
      when coalesce(r.stop, false) and r.tipo not in ('stop', 'start') then 'ha scritto STOP'
      when r.tipo = 'club' and exists (select 1 from public.club_iscritti where telefono = r.telefono) then 'già nel Club'
      when r.tipo = 'voto' and (r.pren_stato in ('annullata', 'noshow') or r.voto is not null) then 'prenotazione annullata o voto già dato'
      when r.tipo = 'campagna' and r.contatto is null then 'contatto cancellato'
      when r.tipo = 'campagna' and r.camp_premio is not null then 'ha già scoperto il regalo'
      when r.tipo = 'campagna' and r.camp_disiscritto is not null then 'disiscritto dalle email'
      when r.modello is null and (r.ultimo_in is null or r.ultimo_in < now() - interval '23 hours 50 minutes')
        then 'fuori dalle 24 ore'
      end;
    if salta is not null then
      update public.wa_uscita set stato = 'saltato', errore = salta where id = r.id;
    else
      update public.wa_uscita set stato = 'invio' where id = r.id;
      lista := lista || jsonb_build_object('id', r.id, 'telefono', r.telefono, 'tipo', r.tipo, 'modello', r.modello,
                                           'parametri', r.parametri, 'link', r.link, 'testo', r.testo, 'lingua', r.lingua);
    end if;
  end loop;
  return jsonb_build_object('numeroId', cfg.numero_id, 'messaggi', lista);
end $$;

revoke execute on function public.camp_pianifica_wa()                 from public, anon, authenticated;
revoke execute on function public.camp_rimanda(bigint, text)          from public, anon, authenticated;
revoke execute on function public.camp_brevo_evento(text, text)       from public, anon, authenticated;
revoke execute on function public.wa_prendi_uscita(int)               from public, anon, authenticated;
grant execute on function public.camp_pianifica_wa(), public.camp_rimanda(bigint, text),
  public.camp_brevo_evento(text, text), public.wa_prendi_uscita(int) to service_role;


-- ================= TITOLARE (dashboard, col PIN) =================

-- come sta andando la campagna: in più i gruppi e il WhatsApp di richiamo
create or replace function public.camp_panoramica(p_pin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', k.id, 'nome', k.nome, 'attiva', k.attiva, 'sere', k.sere, 'scopriEntro', k.scopri_entro,
      'contatti',    (select count(*) from public.camp_contatti c where c.campagna = k.id),
      'aperti',      (select count(*) from public.camp_contatti c where c.campagna = k.id and c.aperto is not null),
      'scoperti',    (select count(*) from public.camp_contatti c where c.campagna = k.id and c.premio is not null),
      'disiscritti', (select count(*) from public.camp_contatti c where c.campagna = k.id and c.disiscritto is not null),
      'prenotati',   (select count(*) from public.camp_contatti c
                       where c.campagna = k.id and c.premio is not null and c.iscritto is not null
                         and exists (select 1 from public.pren_prenotazioni x
                                      where x.iscritto = c.iscritto and x.fonte = 'sito' and x.stato <> 'annullata'
                                        and x.creato >= c.premio_quando)),
      'usati',       (select count(*) from public.camp_contatti c join public.club_premi r on r.codice = c.club_codice
                       where c.campagna = k.id and r.usato is not null),
      'premi', (select jsonb_agg(jsonb_build_object('id', p.id, 'emoji', p.emoji, 'nome', p.nome->>'it',
                                                    'peso', p.peso, 'limite', p.limite,
                                                    'usciti', (select count(*) from public.camp_contatti c
                                                                where c.campagna = k.id and c.premio = p.id)) order by p.ordine)
                  from public.camp_premi p where p.campagna = k.id),
      'wa', jsonb_build_object(
        'attivo', k.wa_attivo, 'modello', k.wa_modello, 'giorni', k.wa_giorni,
        'inviati',   (select count(*) from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                       where c.campagna = k.id and u.tipo = 'campagna' and u.stato in ('inviato', 'consegnato', 'letto')),
        'letti',     (select count(*) from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                       where c.campagna = k.id and u.tipo = 'campagna' and u.stato = 'letto'),
        'errori',    (select count(*) from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                       where c.campagna = k.id and u.tipo = 'campagna' and u.stato = 'errore'),
        'scopertiDopo', (select count(*) from public.camp_contatti c
                          where c.campagna = k.id and c.wa_quando is not null and c.premio_quando > c.wa_quando),
        'ultimoErrore', (select u.errore from public.wa_uscita u join public.camp_contatti c on c.id = u.contatto
                          where c.campagna = k.id and u.tipo = 'campagna' and u.errore is not null
                            and u.stato in ('errore', 'in_coda') order by u.id desc limit 1)),
      'gruppi', (select jsonb_agg(jsonb_build_object(
                   'gruppo', g.gruppo,
                   'email', g.email_quando,
                   'wa', public.camp_quando_wa(g.email_quando, k.wa_giorni),
                   'contatti', (select count(*) from public.camp_contatti c where c.campagna = k.id and c.gruppo = g.gruppo),
                   'scoperti', (select count(*) from public.camp_contatti c
                                 where c.campagna = k.id and c.gruppo = g.gruppo and c.premio is not null),
                   'whatsapp', (select count(*) from public.camp_contatti c
                                 where c.campagna = k.id and c.gruppo = g.gruppo and c.wa_quando is not null)) order by g.gruppo)
                   from public.camp_gruppi g where g.campagna = k.id),
      'senzaGruppo', (select count(*) from public.camp_contatti c
                       where c.campagna = k.id and (c.gruppo is null
                         or not exists (select 1 from public.camp_gruppi g where g.campagna = k.id and g.gruppo = c.gruppo))))
      order by k.creato desc)
      from public.camp_campagne k), '[]'::jsonb);
end $$;

-- accende / spegne il WhatsApp di richiamo
create or replace function public.camp_wa_attiva(p_pin text, p_campagna text, p_attivo boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  if coalesce(p_attivo, false) and coalesce((select numero_id from public.wa_config where id = 1), '') = '' then
    raise exception 'Prima collega il numero WhatsApp' using hint = 'numero';
  end if;
  update public.camp_campagne set wa_attivo = coalesce(p_attivo, false) where id = p_campagna;
  if not found then raise exception 'Campagna non trovata' using hint = 'campagna'; end if;
  return public.camp_panoramica(p_pin);
end $$;

grant execute on function public.camp_panoramica(text), public.camp_wa_attiva(text, text, boolean) to anon, authenticated;


-- ================= OROLOGIO =================
-- ogni 2 minuti (stesso lavoro di 17-whatsapp-dialogo.sql): in più i WhatsApp della campagna
select cron.schedule('whatsapp-invia', '*/2 * * * *', $wa$
  select public.wa_pianifica();
  select public.camp_pianifica_wa();
  select net.http_post(
    url     := 'https://agbvmhpktilpaoabjkre.supabase.co/functions/v1/whatsapp-invia',
    body    := '{"azione":"invia"}'::jsonb,
    headers := '{"Content-Type":"application/json","apikey":"sb_publishable_2O5l8ZbQqGnwDXwxZnsZ2Q_0Mt1V8T7"}'::jsonb)
   where exists (select 1 from public.pren_prenotazioni where wa_stato = 'in_coda')
      or exists (select 1 from public.wa_uscita where stato = 'in_coda' and quando <= now()
                    and (tipo <> 'campagna' or public.camp_wa_ora_buona(now())));
$wa$);
