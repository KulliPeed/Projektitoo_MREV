# Superseti MREV toimivuse kontroll

Aeg: 2026-05-29

## Leitud probleemid

1. Superseti chartidel puudus salvestatud `query_context`.
   - `/api/v1/chart/{id}/data/` tagastas enne parandust KPI ja bar chartidele vea `Chart has no query context saved`.
   - Top tabel tagastas `Error: Empty query?`.

2. MART vaated olid Superseti runtime jaoks liiga rasked.
   - Enne cache-kihi lisamist läksid need PostgreSQL päringud 30 sekundiga timeouti:
     - `mart.v_dashboard_kpi`
     - `mart.v_maksuvolg_juhatuse_muutus_vanusegrupp`
     - `mart.v_top_maksuvolglased ORDER BY maksuvolg DESC LIMIT 25`
     - `mart.v_maksuvolglased_juhatuse_muutusega` count
   - `mart.v_maksuvolg_vanusegruppide_kaupa` töötas, aga võttis umbes 4,3 sekundit.

3. Superseti dataset refresh endpoint tekitab selles Superseti versioonis logides vea `database "mart" does not exist`.
   - Põhjus: datetime detector proovib PostgreSQL catalog'ina kasutada schema nime `mart`.
   - See ei takistanud chartide tööd, aga risustas Superseti ja PostgreSQL logisid FATAL/ERROR kirjetega.

4. Eraldi andmekvaliteedi tähelepanek: viimases MTA seisus on iga registrikood kahekordselt.
   - `stage.mta_maksuvolglased` viimases `data_as_of` seisus: 37 442 rida, 18 721 unikaalset registrikoodi.
   - Seetõttu on `v_top_maksuvolglased` tabelis top read duublis. Seda ei parandatud selle töö käigus, sest see puudutab lähteandmete/importi ja MART kvaliteedireegleid laiemalt.

## Tehtud parandused

1. Lisatud `db/migrations/110_create_mart_superset_cache.sql`.
   - Loob/uuendab `mart.superset_cache_*` cache tabelid.
   - Suunab olemasolevad `mart.v_*` vaated cache tabelite peale.
   - Lisab Superseti jaoks vajalikud indeksid ja `ANALYZE`.
   - Annab `superset_readonly` kasutajale `SELECT` õigused.

2. Uuendatud `scripts/refresh_mart.sh`.
   - MART refresh loob kõigepealt vaated.
   - Seejärel värskendab Superseti cache-kihi.
   - Alles siis käivitab kvaliteedikontrollid.

3. Uuendatud `scripts/configure_superset_mrev.py`.
   - Chartidele salvestatakse nüüd `query_context`.
   - Olemasolevaid MREV charte uuendatakse, mitte ei jäeta vana vigast konfiguratsiooni alles.
   - Dataset refresh jäetakse vahele, et vältida Superseti datetime detectori `database "mart" does not exist` logiviga.

4. Superseti olemasolevad chartid uuendati API kaudu.

## Kontrollitulemused pärast parandust

PostgreSQL päringuajad pärast cache-kihi lisamist:

| Kontroll | Tulemus |
| --- | ---: |
| `mart.v_dashboard_kpi` | 8 ms |
| Maksuvõlg vanusegrupi kaupa | 14 ms |
| Juhatuse muutus vanusegrupi kaupa | 4 ms |
| Top 25 maksuvõlglased | 3 ms |
| Detailvaate count | 33 ms |

Superseti salvestatud chart data endpoint:

| Chart | Tulemus |
| --- | --- |
| MREV KPI - maksuvõlglaste arv | HTTP 200, 0,526 s, 1 rida |
| MREV KPI - maksuvõlg kokku | HTTP 200, 0,572 s, 1 rida |
| MREV KPI - juhatuse muutusega maksuvõlglased | HTTP 200, 0,520 s, 1 rida |
| MREV - maksuvõlg vanusegrupi kaupa | HTTP 200, 0,523 s, 4 rida |
| MREV - top maksuvõlglased | HTTP 200, 0,591 s, 25 rida |

MART kvaliteedikontrollid läbisid pärast muudatust.

Viimase kontrollkäivituse järel ei lisandunud PostgreSQL logisse uusi `database "mart" does not exist` kirjeid.

## Järgmised sammud

1. Ava Superset dashboard `MREV maksuvõlg ja juhatuse muutused` ja värskenda brauseris leht.
2. Kui top tabelis duplikaadid on segavad, tuleb järgmisena parandada MTA import või MART loogika nii, et viimase seisu kohta oleks üks rida registrikoodi kohta.
3. Pärast iga stage/MART andmevärskendust käivita `scripts/refresh_mart.sh`, sest Superset loeb nüüd cache-kihi kaudu.
