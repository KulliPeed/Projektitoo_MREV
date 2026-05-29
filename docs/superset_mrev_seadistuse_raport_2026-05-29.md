# Superseti MREV seadistuse raport

Töö tehtud: 2026-05-29 17:21:59

## Kontrollid ja API

- Superset vastas aadressil `http://127.0.0.1:8088`: ok. HTTP 200
- Login API: ok. Login API tagastas access tokeni.
- CSRF token: ok. CSRF token saadi.
- Database connection: olemas (ID 1). Sama nimega database connection oli juba olemas; URI-d ei prinditud ega muudetud.
- Connection test API: ok. Superseti database test_connection endpoint õnnestus.

## Database connection

- Nimi: `MREV andmeprojekt MART`
- SQLAlchemy URI kasutab `superset_readonly` kasutajat ja andmebaasi `andmeprojekt`.
- URI ja parooli ei kuvata raportis ega logis.

## Datasetid

- `mart.v_dashboard_kpi`: olemas (ID 1). Dataset oli juba olemas.
- `mart.v_maksuvolg_vanusegruppide_kaupa`: olemas (ID 2). Dataset oli juba olemas.
- `mart.v_maksuvolg_juhatuse_muutus_vanusegrupp`: olemas (ID 3). Dataset oli juba olemas.
- `mart.v_top_maksuvolglased`: olemas (ID 4). Dataset oli juba olemas.
- `mart.v_maksuvolglased_juhatuse_muutusega`: olemas (ID 5). Dataset oli juba olemas.
- `mart.v_viimased_maksuvolglased_rik_andmetega`: olemas (ID 6). Dataset oli juba olemas.

## Dataset refresh

- `mart.v_dashboard_kpi`: ok. Dataset columns refresh õnnestus.
- `mart.v_maksuvolg_vanusegruppide_kaupa`: ok. Dataset columns refresh õnnestus.
- `mart.v_maksuvolg_juhatuse_muutus_vanusegrupp`: ok. Dataset columns refresh õnnestus.
- `mart.v_top_maksuvolglased`: ok. Dataset columns refresh õnnestus.
- `mart.v_maksuvolglased_juhatuse_muutusega`: ok. Dataset columns refresh õnnestus.
- `mart.v_viimased_maksuvolglased_rik_andmetega`: ok. Dataset columns refresh õnnestus.

## Dashboard ja chartid

- Dashboard: olemas (ID 1). Dashboard oli juba olemas.
- Dashboardi chartide sidumine: ok (ID 1). Chartide sidumine dashboardiga õnnestus API kaudu.
- MREV KPI - maksuvõlglaste arv: olemas (ID 1). Chart oli juba olemas.
- MREV KPI - maksuvõlg kokku: olemas (ID 2). Chart oli juba olemas.
- MREV KPI - juhatuse muutusega maksuvõlglased: olemas (ID 3). Chart oli juba olemas.
- MREV - maksuvõlg vanusegrupi kaupa: olemas (ID 4). Chart oli juba olemas.
- MREV - top maksuvõlglased: olemas (ID 5). Chart oli juba olemas.

## Kasutajad

- tuuli: vahele jäetud. Tuuli/Külli kasutajaid ei loodud, sest .env.superset failis puuduvad paroolid/e-mailid.
- kulli: vahele jäetud. Tuuli/Külli kasutajaid ei loodud, sest .env.superset failis puuduvad paroolid/e-mailid.

## Andmete muutmise kinnitus

- Skript kasutas ainult Superseti REST API-t Superseti metadata objektide loomiseks.
- PostgreSQL `raw`, `stage` ja `mart` andmeid ei muudetud.
- `.env.superset` faili ega paroole GitHubi ei lisatud.

## Käsitsi sammud vajadusel

- Täiendavaid käsitsi samme ei ole vaja, kui dashboard kuvab chartid ootuspäraselt.

## Järgmised sammud

- Logi Supersetisse kasutajaga `andrus_admin` ja kontrolli `Data -> Datasets` vaadet.
- Ava dashboard `MREV maksuvõlg ja juhatuse muutused` ja kontrolli chartide paigutust.
- Kui mõni chart vajab visuaalset häälestust, tee see Superseti UI-s.
