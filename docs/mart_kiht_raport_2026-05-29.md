# MART kihi raport

Koostatud: 2026-05-29  
Andmebaas: `andmeprojekt`

## Kokkuvõte

MART kiht loodi PostgreSQL-i `mart` skeemi tavaliste vaadetena. RAW ja STAGE
tabeleid ei muudetud. MART loeb ärivaadetes ainult järgmistest stage tabelitest:

- `stage.mta_maksuvolglased`
- `stage.rik_ettevotted`
- `stage.rik_kaardile_kantud_isikud`

`/home/pi/kool/projekt` ei ole Git repo (`git status` tagastas: `fatal: not a git repository`).

## Lisatud failid

- `db/migrations/100_create_mart_views.sql`
- `quality/030_mart_quality_checks.sql`
- `scripts/refresh_mart.sh`
- `docs/mart_kiht_raport_2026-05-29.md`

## Loodud MART vaated

| Vaade | Kirjeldus |
| --- | --- |
| `mart.v_latest_dates` | Ühe rea vaade viimaste MTA ja RIK kuupäevadega. |
| `mart.v_maksuvolg_vanusegruppide_kaupa` | Viimase MTA seisu maksuvõlg võla vanusegruppide kaupa. |
| `mart.v_viimased_maksuvolglased_rik_andmetega` | Viimase MTA seisu maksuvõlglased koos viimase RIK ettevõtte snapshotiga. |
| `mart.v_juhatuse_muutused_viimane_paev` | Viimase ja eelmise RIK snapshoti juhatuse võrdlus ettevõtte kaupa. |
| `mart.v_maksuvolglased_juhatuse_muutusega` | Maksuvõlglaste ühendvaade RIK ühildumise ja juhatuse muutuse tunnusega. |
| `mart.v_maksuvolg_juhatuse_muutus_vanusegrupp` | Maksuvõla koond võla vanusegrupi ja juhatuse muutuse järgi. |
| `mart.v_dashboard_kpi` | Üherealine KPI vaade Superseti jaoks. |
| `mart.v_top_maksuvolglased` | Suurima maksuvõlaga ettevõtete tabelivaade ilma `LIMIT` piiranguta. |

## Kasutatud kuupäevad

| Näitaja | Väärtus |
| --- | --- |
| Viimane MTA `snapshot_date` | `2026-05-27` |
| Viimane MTA `data_as_of` | `2026-05-26` |
| Viimane RIK `snapshot_date` | `2026-05-27` |
| Eelmine RIK `snapshot_date` | `2026-05-26` |

## Kvaliteedikontrollide tulemused

Käivitatud skript: `./scripts/refresh_mart.sh`  
Edukas logi: `logs/mart_refresh_2026-05-29_091625.log`  
Tulemus: `OK`

| Kontroll | Tulemus |
| --- | --- |
| MART objektid eksisteerivad | OK, 8 vaadet |
| `mart.v_latest_dates` | OK, 1 rida |
| `mart.v_maksuvolg_vanusegruppide_kaupa` | OK, 4 rida |
| `mart.v_viimased_maksuvolglased_rik_andmetega` | OK, 37 442 rida |
| `mart.v_juhatuse_muutused_viimane_paev` | OK, 320 894 rida |
| `mart.v_maksuvolglased_juhatuse_muutusega` | OK, 37 442 rida |
| `mart.v_maksuvolg_juhatuse_muutus_vanusegrupp` | OK, 6 rida |
| `mart.v_dashboard_kpi` | OK, 1 rida |
| `mart.v_top_maksuvolglased` | OK, 37 442 rida |
| MTA viimase seisu ridade pariteet | OK, stage 37 442 = mart 37 442 |
| Maksuvõla summa pariteet | OK, stage 622 471 286.38 = mart 622 471 286.38 |
| RIK ühildumise määr | OK, 98.47% |
| Juhatuse muutuse loogika | OK, 0 negatiivset arvu, 0 loogikaviga |
| Dashboard KPI mitte-negatiivsed arvud | OK |

## KPI tulemused

| Näitaja | Väärtus |
| --- | ---: |
| MTA ridu viimases seisus | 37 442 |
| RIKiga ühildunud | 36 868 |
| RIKita | 574 |
| RIK ühildumise määr | 98.47% |
| Maksuvõlg kokku | 622 471 286.38 |
| Juhatuse muutusega maksuvõlglasi | 12 |
| Juhatuse muutusega maksuvõlg kokku | 115 936.02 |
| Juhatuse muutusega maksuvõlglaste osakaal | 0.03% |

## Maksuvõlg vanusegruppide kaupa

| MTA seis | Võla vanusegrupp | Ettevõtteid | Maksuvõlg | Vaidlustatud | Tasumisgraafikus |
| --- | --- | ---: | ---: | ---: | ---: |
| 2026-05-26 | `>= 1 aasta` | 17 900 | 463 111 580.50 | 5 253 804.48 | 27 917 943.78 |
| 2026-05-26 | `2-5 kuud` | 6 300 | 60 405 667.82 | 198 812.94 | 33 998 595.50 |
| 2026-05-26 | `6-11 kuud` | 5 360 | 68 544 251.22 | 23 545.14 | 27 755 058.44 |
| 2026-05-26 | `kuni 2 kuud` | 7 882 | 30 409 786.84 | 0.00 | 13 826 245.62 |

## Superseti soovitatavad datasetid

- `mart.v_dashboard_kpi`
- `mart.v_maksuvolg_vanusegruppide_kaupa`
- `mart.v_maksuvolg_juhatuse_muutus_vanusegrupp`
- `mart.v_top_maksuvolglased`
- `mart.v_maksuvolglased_juhatuse_muutusega`

Soovitatavad esimesed graafikud:

1. KPI kaart: maksuvõlglaste arv, maksuvõla summa, juhatuse muutusega ettevõtete arv.
2. Tulpdiagramm: maksuvõla summa võla vanusegrupi kaupa.
3. Tulpdiagramm: juhatus muutus / ei muutunud maksuvõla summa järgi.
4. Tabel: top maksuvõlglased.
5. Tabel: juhatuse muutusega maksuvõlglased.

## Jõudlusmärkus

Vaated on Superseti jaoks kasutatavad. Kõige kallim osa on
`mart.v_juhatuse_muutused_viimane_paev`, sest see võrdleb viimase kahe RIK
snapshoti juhatuse liikmeid. Praegune refresh koos kontrollidega lõpetas edukalt
260 sekundiga. Kui dashboard hakkab seda vaadet tihti pärima, tasub järgmise
sammuna kaaluda selle vaate või sellest sõltuva KPI-kihi materialiseerimist MART
skeemis.

## Käsitsi kontrollimiseks

```sql
SELECT * FROM mart.v_latest_dates;

SELECT * FROM mart.v_dashboard_kpi;

SELECT *
FROM mart.v_maksuvolg_vanusegruppide_kaupa
ORDER BY volg_vanuse_grupp;

SELECT *
FROM mart.v_maksuvolg_juhatuse_muutus_vanusegrupp
ORDER BY volg_vanuse_grupp, juhatus_muutus;

SELECT *
FROM mart.v_top_maksuvolglased
ORDER BY maksuvolg DESC
LIMIT 20;

SELECT *
FROM mart.v_maksuvolglased_juhatuse_muutusega
WHERE juhatus_muutus = true
ORDER BY maksuvolg DESC
LIMIT 50;
```
