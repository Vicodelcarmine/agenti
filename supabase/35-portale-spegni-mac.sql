-- =============================================================================
-- PORTALE CAPODANNOFIRENZE.IT: SPENTA LA STRADA DAL MAC (si esegue DOPO 34-portale-server.sql)
-- Dal 10/11/2026 il portale lo legge il server da solo, ogni ora (funzione "portale-capodanno").
-- La strada di prima (attività sul Mac + chiave + cassetta) non serve più: chiave tolta,
-- cassetta svuotata, nessuna di quelle funzioni si può più chiamare dal sito.
-- Si può rieseguire.
-- =============================================================================
update public.portale_config set chiave_hash = null where id = 1;
delete from public.portale_deposito;
revoke execute on function public.portale_deposita(jsonb) from anon, authenticated;
revoke execute on function public.pren_portale_importa(text, text, boolean) from anon, authenticated;
revoke execute on function public.pren_da_portale(text, jsonb, boolean) from anon, authenticated;
select cron.alter_job((select jobid from cron.job where jobname = 'portale-capodanno'), active := true);
