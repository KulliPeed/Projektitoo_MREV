# MART_STAR lihtsustamise raport 2026-06-02

## Eesmärk

Vana `mart` dashboard/cache skeem eemaldati ja `mart_star` muudeti lõplikuks lihtsaks tähtskeemiks, mis vastab README1/pildi mudelile:

- `mart_star.dim_ettevote`
- `mart_star.dim_aeg`
- `mart_star.dim_vanuse_grupp`
- `mart_star.fact_maksuvolg`

Faktitabeli grain:

```text
üks rida = üks ettevõte + üks MTA snapshot_date
```

`fact_maksuvolg.kuupaev` tähendab MTA snapshoti kuupäeva.

## Backupid

Enne kustutamist tehti schema-only backupid:

- `backups/mart_cleanup/mart_schema_before_2026-06-02_113543.sql`
- `backups/mart_cleanup/mart_star_schema_before_2026-06-02_113543.sql`

Backupid sisaldavad ainult skeemikirjeldust, mitte tabeliandmeid.

## Eelkontroll

Enne muudatust olid olemas skeemid:

```text
mart
mart_star
raw
stage
```

Vana `mart` skeemi objektid enne kustutamist:

```text
mart.superset_cache_dashboard_kpi                         BASE TABLE
mart.superset_cache_juhatuse_muutused_viimane_paev        BASE TABLE
mart.superset_cache_latest_dates                          BASE TABLE
mart.superset_cache_maksuvolg_juhatuse_muutus_vanusegrupp BASE TABLE
mart.superset_cache_maksuvolg_vanusegruppide_kaupa        BASE TABLE
mart.superset_cache_maksuvolglased_juhatuse_muutusega     BASE TABLE
mart.superset_cache_top_maksuvolglased                    BASE TABLE
mart.superset_cache_viimased_maksuvolglased_rik_andmetega BASE TABLE
mart.v_dashboard_kpi                                      VIEW
mart.v_juhatuse_muutused_viimane_paev                     VIEW
mart.v_latest_dates                                       VIEW
mart.v_maksuvolg_juhatuse_muutus_vanusegrupp              VIEW
mart.v_maksuvolg_vanusegruppide_kaupa                     VIEW
mart.v_maksuvolglased_juhatuse_muutusega                  VIEW
mart.v_top_maksuvolglased                                 VIEW
mart.v_viimased_maksuvolglased_rik_andmetega              VIEW
```

Vana `mart_star` sisaldas enne lihtsustamist 6 objekti ja 66 veerukirjet, sh `mart_star.juhatuse_muutus_paeviti`, `mart_star.v_juhatuse_muutus_paeviti` ja palju lisaveerge faktis. Need eemaldati, sest lõplik pildi mudel vajab ainult nelja tabelit ja nende põhilisi veerge.

## Superseti vana MART sõltuvus

Superseti metadata DB-s olid enne kustutamist järgmised `mart` datasetid:

```text
1  mart.v_dashboard_kpi
2  mart.v_maksuvolg_vanusegruppide_kaupa
3  mart.v_maksuvolg_juhatuse_muutus_vanusegrupp
4  mart.v_top_maksuvolglased
5  mart.v_maksuvolglased_juhatuse_muutusega
6  mart.v_viimased_maksuvolglased_rik_andmetega
```

Nendega seotud chartid:

```text
mart.v_dashboard_kpi:
- MREV KPI - juhatuse muutusega maksuvõlglased
- MREV KPI - maksuvõlg kokku
- MREV KPI - maksuvõlglaste arv

mart.v_maksuvolg_vanusegruppide_kaupa:
- MREV - maksuvõlg vanusegrupi kaupa

mart.v_top_maksuvolglased:
- MREV - top maksuvõlglased
```

Datasetid `mart.v_maksuvolg_juhatuse_muutus_vanusegrupp`, `mart.v_maksuvolglased_juhatuse_muutusega` ja `mart.v_viimased_maksuvolglased_rik_andmetega` olid metadata järgi olemas, aga chartide seos puudus.

Kuna ülesande eesmärk oli vana `mart` eemaldada, võivad need Superseti datasetid/chartid pärast kustutamist katki olla ja vajavad käsitsi eemaldamist või ümbertegemist `mart_star` tabelitele. Superseti metadata objekte automaatselt ei kustutatud.

## Tehtud Muudatus

Käivitatud skript:

```bash
./scripts/refresh_mart_star.sh
```

Logi:

```text
logs/mart_star_refresh_2026-06-02_115502.log
```

Tulemus:

```text
mart schema removed = yes
tulemus = OK
kestus_sekundites = 328
```

Migratsioonis tehti:

```sql
DROP SCHEMA IF EXISTS mart CASCADE;
DROP SCHEMA IF EXISTS mart_star CASCADE;
CREATE SCHEMA mart_star;
```

Seejärel loodi ainult neli tähtskeemi tabelit.

## Lõplik MART_STAR Struktuur

`mart_star.dim_ettevote`:

```text
ettevote_id bigint PK
registrikood text UK
nimi text
```

`mart_star.dim_aeg`:

```text
kuupaev date PK
paev integer
kuu integer
aasta integer
```

`mart_star.dim_vanuse_grupp`:

```text
maksuvola_vanuse_grupp text PK
min_paevi integer
max_paevi integer
jarjestus integer
```

`mart_star.fact_maksuvolg`:

```text
id bigint PK
dim_ettevote_id bigint FK
kuupaev date FK
maksuvola_summa numeric(18,2)
maksuvola_vanuse_grupp text FK
juhatuse_muutuse_fakt boolean
```

Märkus: pildil on `maksuvola_summa` loogiliselt float, aga PostgreSQL-is kasutatakse `numeric(18,2)`, sest rahasummade jaoks on see täpsem.

## Täitmisloogika

`dim_ettevote` täidetakse kõigi ettevõtetega, kes esinevad `stage.mta_maksuvolglased` tabelis. Nime valikul eelistati viimase RIK snapshoti nime; kui seda polnud, kasutati uusimat MTA nime.

`dim_aeg` täidetakse kõigi MTA snapshot kuupäevadega.

`dim_vanuse_grupp` täidetakse STAGE andmetes päriselt esinevate gruppidega:

```text
kuni 2 kuud       1-59 päeva
2-5 kuud          60-179 päeva
6-11 kuud         180-364 päeva
>= 1 aasta        365+ päeva
```

`fact_maksuvolg` täidetakse `stage.mta_maksuvolglased` põhjal registrikoodi ja `snapshot_date` lõikes.

Juhatuse muutuse boolean arvutati ajalooliselt STAGE RIK juhatuse liikmete snapshotite põhjal. Iga MTA kuupäeva jaoks leitakse lähim sama päeva või varasem RIK snapshot ja võrreldakse seda sellele eelnenud RIK snapshotiga. Fallback `false` kõigile ridadele ei kasutatud.

## Kvaliteedikontroll

`quality/040_mart_star_quality_checks.sql` läbis.

Objektid:

```text
mart_star.dim_aeg          OK
mart_star.dim_ettevote     OK
mart_star.dim_vanuse_grupp OK
mart_star.fact_maksuvolg   OK
```

Veergude kontroll: 17 oodatud veergu, kõik OK.

Rea-arvud:

```text
mart_star.dim_aeg          12
mart_star.dim_ettevote     22407
mart_star.dim_vanuse_grupp 4
mart_star.fact_maksuvolg   226951
```

Faktikuupäevad:

```text
stage_snapshot_count = 12
fact_snapshot_count  = 12
ok = true
```

Faktisumma:

```text
fact summa = 3745719933.55
```

Juhatuse muutuse read:

```text
juhatuse_muutuse_fakt true rows = 65
null_juhatuse_muutuse_fakt = 0
```

FK kontrollid:

```text
fact -> dim_aeg          0 bad rows OK
fact -> dim_ettevote     0 bad rows OK
fact -> dim_vanuse_grupp 0 bad rows OK
```

Grain duplikaadid:

```text
duplicate_company_snapshot_keys = 0
```

## Kuupäevade Kaupa Kontroll

Faktiridade arv klappis iga STAGE MTA kuupäeva distinct registrikoodide arvuga:

```text
2026-05-22  21560
2026-05-23  20023
2026-05-24  19448
2026-05-25  19354
2026-05-26  18721
2026-05-27  18721
2026-05-28  18479
2026-05-29  18307
2026-05-30  18219
2026-05-31  18082
2026-06-01  18041
2026-06-02  17996
```

Maksuvõla summa klappis iga kuupäeva kohta; kõik `ok = true`.

## Superseti Õigused

`superset_readonly` õigused:

```text
schema_usage              true
dim_ettevote_select       true
dim_aeg_select            true
dim_vanuse_grupp_select   true
fact_select               true
```

## RAW/STAGE Ohutus

RAW ja STAGE rea-arvud enne ning pärast jäid samaks:

```text
raw_mta              226965
raw_rik_isikud       5212371
stage_mta            226965
stage_rik_ettevotted 5212371
stage_rik_isikud     7246768
```

RAW ja STAGE tabeleid ei kustutatud, ei tühjendatud ega uuendatud käsitsi.

PostgreSQL Docker volume'it, Superseti metadata DB-d, `data/raw`, `backups` ja `logs` katalooge ei kustutatud.

## Järelkontroll

Pärast refreshi olid olemas skeemid:

```text
mart_star
raw
stage
```

`mart` skeemi enam ei ole.

Pipeline freshness:

```text
raw_mta_max = 2026-06-02
stage_mta_max = 2026-06-02
mart_star_fact_max = 2026-06-02
stage_mta_snapshot_count = 12
mart_star_fact_snapshot_count = 12
pipeline_fresh = true
snapshot_count_ok = true
```

## Kokkuvõte

Töö õnnestus. Vana `mart` skeem eemaldati, `mart_star` sisaldab ainult pildi järgi vajalikke nelja tabelit ja faktitabel sisaldab kõiki STAGE MTA snapshot kuupäevi. Superseti vana `mart` sõltuvus on raportis dokumenteeritud; metadata objekte ei kustutatud.
