-- =============================================================================
-- DASHBOARD — LE CATEGORIE DEGLI ARTICOLI DELLA CASSA (si esegue DOPO 23-cassa-articoli.sql)
-- La cassa manda solo codice e nome: la categoria (Pizze, Birre…) la tiene la dashboard.
-- · cassa_categorie: articolo (il nome come lo scrive la cassa) → categoria. Pre-compilata con
--   i 181 articoli venduti dal 30/04 al 25/10/2026; un articolo nuovo resta "Da sistemare".
-- · dash_cassa_categorie(): le categorie, nell'ordine in cui si mostrano.
-- · dash_cassa_articoli(pin, dal, al): ora con la categoria di ogni articolo e tutti gli articoli.
-- · dash_cassa_categoria_salva(pin, articolo, categoria): il titolare sposta un articolo.
-- Si può rieseguire: le categorie già scelte non si toccano.
-- =============================================================================

create table if not exists public.cassa_categorie (
  articolo   text primary key,
  categoria  text not null,
  aggiornato timestamptz not null default now()
);
alter table public.cassa_categorie enable row level security;

create or replace function public.dash_cassa_categorie() returns text[]
language sql immutable as $$
  select array['Antipasti', 'Primi', 'Secondi', 'Insalatone', 'Contorni', 'Pizze', 'Dolci',
               'Birre', 'Vini', 'Cocktail', 'Bevande', 'Caffè e amari', 'Menu e altro']
$$;

insert into public.cassa_categorie (articolo, categoria)
select unnest(v.articoli), v.categoria from (values
  ('Antipasti', array['INSALATA DI BACCALA', 'PIATTO DI CRUDO', 'BUFALA', 'GUAZZETTO DI MARE', 'BRUSCHETTA AL POMODORO',
    'CROSTINI MIX', 'MONTANARA', 'PEPATA DI COZZE', 'IL SOLITO', 'GRAN TAGLERE', 'COVACCINO OLIO']),
  ('Primi', array['CARBONARA DI MARE', 'SCOGLIO NAPOLETANO', 'SCOGLIO', 'CHITARRA CARRETTIERA', 'SORRENTINA',
    'PENNETTE POMODORO BASILICO', 'CARBONARA', 'RAVIOLI NERI', 'VONGOLE E BOTTARGA', 'GNOCCHI CECI E COZZE',
    'PENNE PESTO GAMBERI', 'GNOCCHI GENOVESE', 'TAGLIATELLE AL TARTUFO', 'TORTELLINI PP', 'AGNOLOTTI GORGO E NOCI',
    'RAVIOLI MUGELLANI']),
  ('Secondi', array['ORATA AL FORNO', 'SPIGOLA FERRI', 'BACCALA NAPOLETANO', 'SALMONE ALLA GRIGLIA', 'TAGLIATA MANZO',
    'HAMBURGER', 'AGNELLO SCOTTADITO', 'STRACCETTI DI POLLO', 'POLPETTE AL SUGO', 'PALLOTTE CACIO E OVA',
    'BACCALÀ AL LIMONE', 'SPADA ALLA MEDITERRANEA', 'ENTRECOTEAL CHIANTI', 'SPIEDINI DI POLLO', 'GAMBERONI GRIL',
    'PARMIGIANA', 'PARMIGIANA DI MELANZANE']),
  ('Insalatone', array['INS MIX', 'INS RUSTICHELLA', 'INS. NIZZARDA', 'INS.CAPRESE', 'INS CLASSICA']),
  ('Contorni', array['VERDUREGRIGLIATE', 'PATATINE FRITTE', 'FRIARIELLI', 'FAGIOLI', 'SPINACI']),
  ('Pizze', array['MARINARA', 'BIANCA', 'ROSSA', 'PROSCIUTTO e FUNGHI', 'WURSTEL E PATATINE', 'WURSTEL', 'TONNO E CIPOLLA',
    'MARGHERITA', 'NAPOLI', 'A FILETTO', '4 STAGIONI', 'SALSICCIA FRIARIELLI', 'CAPRICCIOSA', 'MEDITERRANEO', 'AMERICANA',
    'POSITANO', 'DIAVOLA', '4 FORMAGGI', 'VEGETARIANA', 'NERETO', 'TOSCANA', 'TABARRO', 'CAPRESE', 'BELL ITALIA', 'VICO',
    'VESUVIO', 'CILENTANA', 'PALINURO', 'PARTENOPEA', 'CHIUMMENZANA', 'VERDURELLA', 'CALZONE', 'FUNGACCIA', 'SALINA',
    'O SOLE MIO', 'MAIALINA', 'TARTUFINA', 'FAGOTTO', 'PRIMAVERA']),
  ('Dolci', array['CHEESECAKE', 'SORBETTO', 'BABA AL RUM', 'CREMA CATALANA', 'MATTONELLA AL CIOCCOLATO', 'TORTA CAPRESE',
    'TIRAMISU', 'TORTINO AL CIOCCOLATO']),
  ('Birre', array['BIRR.GLUTEN FREE', 'BIRRA ANALCOLICA', 'BIRRA 33', 'CHIARA MEDIA', 'CHIARA PICCOLA', 'ROSSA MEDIA',
    'ROSSA PICCOLA', 'BLANCHE MEDIA', 'BLANCHE PICCOLA', 'IPA MEDIA', 'IPA MEDIA MEDIA', 'IPA PICCOLA', 'CORONA', 'TENNETS',
    'PORETTI 33 ROSSA', 'ICNUSA NON FILTRATA']),
  ('Vini', array['CHIANTI CLASSICO', 'CHIANTI RISERVA', 'BRUNELLO DI MONTALCINO', 'MONTEPULCIANO', 'ROSSO DI MONTALCINO',
    'MORELLINO DI SCANSANO', 'PASSERINA', 'PECORINO', 'VERMENTINO', 'CHARDONNAY', 'CALICE DI PROSECCO', 'CHIANTI',
    'AGLIANICO', 'FALANGHINA', 'PROSECCO CA SALA', 'CALICE VINO ROSSO', 'CALICE VINO BIANCO', 'VINO 1L ROSSO',
    'VINO 1/2 ROSSO', '1\4 VINO ROSSO', 'VINO 1L BIANCO', 'VINO 1/2 BIANCO']),
  ('Cocktail', array['APEROL SPRTZ', 'CYNAR SPRITZ', 'CAMPARI SPRITZ', 'SELECT SPRITZ', 'HUGO SPRITZ', 'LIMONE SPRITZ',
    'MARTINI SPRITZ', 'NEGRONI', 'AMERICANO', 'GIN TONIC', 'VODKA TONIC', 'CUBA LIBRE']),
  ('Bevande', array['ACQUA NATURALE', 'ACQUA GASSATA', '1\2 NAT', 'COCA COLA', 'COCA ZERO', 'FANTA', 'LEMONSODA',
    'THE LIMONE', 'THE PESCA']),
  ('Caffè e amari', array['CAFFE', 'DOPPIO CAFFE', 'DECAFFEINATO', 'ORZO', 'Orzo', 'AMARI', 'FERNET', 'SAMBUCA',
    'GRAPPA BARRICATA', 'GRAPPA BIANCA', 'MONTENEGRO', 'JEGER', 'CYNAR', 'LIMONCELLO', 'JEFFERSON', 'CAPO', 'UNICUM',
    'BRANCAMENTA', 'RUM']),
  ('Menu e altro', array['MENU ESSENZIALE', 'PASTO COMPLETO'])
) v(categoria, articoli)
on conflict (articolo) do nothing;

-- gli articoli del periodo, ora con la categoria (e tutti, non solo i primi 80)
create or replace function public.dash_cassa_articoli(p_pin text, p_dal date, p_al date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  if p_dal is null or p_al is null or p_al < p_dal or p_al - p_dal > 400 then
    raise exception 'Periodo non valido' using hint = 'periodo';
  end if;
  return jsonb_build_object(
    'categorie',    to_jsonb(public.dash_cassa_categorie()),
    'sere',         (select count(*) from public.cassa_sere where sera between p_dal and p_al),
    'conDettaglio', (select count(*) from public.cassa_sere where sera between p_dal and p_al
                      and jsonb_typeof(dettaglio->'articoli') = 'array'),
    'sconti',  (select round(coalesce(sum((dettaglio->>'sconti')::numeric), 0), 2) from public.cassa_sere
                 where sera between p_dal and p_al and dettaglio ? 'sconti'),
    'coperto', (select round(coalesce(sum((dettaglio->>'coperto')::numeric), 0), 2) from public.cassa_sere
                 where sera between p_dal and p_al and dettaglio ? 'coperto'),
    'abbuono', (select round(coalesce(sum((dettaglio->>'abbuono')::numeric), 0), 2) from public.cassa_sere
                 where sera between p_dal and p_al and dettaglio ? 'abbuono'),
    'giorni',  (select coalesce(jsonb_agg(jsonb_build_object('g', sera, 'sconti', (dettaglio->>'sconti')::numeric,
                   'pezzi', (select coalesce(sum((a->>'qta')::numeric), 0) from jsonb_array_elements(dettaglio->'articoli') a))
                   order by sera), '[]'::jsonb)
                  from public.cassa_sere where sera between p_dal and p_al and jsonb_typeof(dettaglio->'articoli') = 'array'),
    'articoli', (select coalesce(jsonb_agg(jsonb_build_object('nome', t.nome, 'codice', t.codice, 'qta', t.qta, 'euro', t.euro,
                    'sconti', t.sconti, 'sere', t.sere, 'categoria', coalesce(k.categoria, 'Da sistemare'))
                    order by t.euro desc, t.nome), '[]'::jsonb)
                   from (select a->>'nome' as nome, min(a->>'codice') as codice, sum((a->>'qta')::numeric) as qta,
                                round(sum((a->>'euro')::numeric), 2) as euro,
                                round(sum(coalesce((a->>'sconti')::numeric, 0)), 2) as sconti, count(distinct c.sera) as sere
                           from public.cassa_sere c, jsonb_array_elements(c.dettaglio->'articoli') a
                          where c.sera between p_dal and p_al and jsonb_typeof(c.dettaglio->'articoli') = 'array'
                            and coalesce(a->>'nome', '') <> ''
                          group by a->>'nome' order by 4 desc limit 600) t
                   left join public.cassa_categorie k on k.articolo = t.nome));
end $$;
grant execute on function public.dash_cassa_articoli(text, date, date) to anon, authenticated;

-- il titolare sposta un articolo in un'altra categoria
create or replace function public.dash_cassa_categoria_salva(p_pin text, p_articolo text, p_categoria text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public.pr_controlla_pin(p_pin);
  if coalesce(trim(p_articolo), '') = '' or length(p_articolo) > 120 then
    raise exception 'Articolo non valido' using hint = 'articolo';
  end if;
  if not (p_categoria = any (public.dash_cassa_categorie())) then
    raise exception 'Categoria non valida' using hint = 'categoria';
  end if;
  insert into public.cassa_categorie (articolo, categoria) values (p_articolo, p_categoria)
  on conflict (articolo) do update set categoria = excluded.categoria, aggiornato = now();
  return jsonb_build_object('ok', true, 'articolo', p_articolo, 'categoria', p_categoria);
end $$;
grant execute on function public.dash_cassa_categoria_salva(text, text, text) to anon, authenticated;
