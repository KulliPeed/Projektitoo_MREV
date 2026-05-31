# Edenemisraport


## Mis on valmis

- [x] Docker Compose käivitab kõik teenused - käivitab
- [x] Andmeid saadakse allikast kätte - andmed laaduvad igapäevaselt
- [x] Andmed laetakse `staging` kihti - Staging kihis on mitme päeva andmestik
- [x] Vähemalt üks transformatsioon toimib - toimivad kõik plaanitud transformatsioonid v.a juhatuse muutuse fakt, mida on vaja veel korrigeerida
- [x] Vähemalt üks näidikulaud on nähtaval - nähtaval on dashboard koos 5 visuaaliga
- [x] Vähemalt üks andmekvaliteedi test läbib - RAW ja STAGE andmekvaliteedi testid on loodud, nt STAGE kontrollid: RAW/STAGE rea-arvu pariteet, MTA tüübiteisendused, negatiivsed või puuduvad summad, kuupäevad, RIK registrikoodid ja duplikaadid.

## Järgmised sammud
- juhatuse muutuse arvutuse korrigeerimine
- kvaliteedi testid peame ühte tabelisse kokku kirjutama- kvaliteedi testide tabelisse (hetkel kirjutame logidesse)
- dashboardi vaated vajavad ka muutmist: 1)peale juhatuse liikme muutuse arvutuse korrigeerimist vaadete täiendamine, 2) kvaliteedi testi tulemused viia ka dashboardile
- peame kustutama mart kihist mart. algusega vaated ja jätma alles ainult mart_star. tabelid

## Mis takistab

- aega on vähe

## Kontrollpunkt

Käsk, millega saab kontrollida, et töövoog töötab:

```bash
cd /home/pi/kool/projekt

# 1. RAW -> STAGE
./scripts/refresh_stage_incremental.sh

# 2. STAGE -> MART / Superset cache
./scripts/refresh_mart.sh

# 3. Kontroll: dashboardi KPI-vaade annab tulemuse
docker exec -i andmeprojekt_postgres psql -U andrus -d andmeprojekt -c "
SELECT
  COUNT(DISTINCT registrikood) AS "Maksuvõlglaste arv"
FROM (
  SELECT
    f.*,
    e.nimi AS ettevote_nimi,
    e.mta_nimi,
    e.rik_nimi,
    e.registrikood AS ettevote_registrikood,
    e.oiguslik_vorm,
    e.staatus,
    e.leitud_rikist AS ettevote_leitud_rikist,
    e.latest_mta_snapshot_date,
    e.latest_mta_data_as_of,
    e.latest_rik_snapshot_date
  FROM mart_star.fact_maksuvolg AS f
  LEFT JOIN mart_star.dim_ettevote AS e
    ON f.dim_ettevote_id = e.ettevote_id
) AS virtual_table
WHERE
  mta_data_as_of >= TO_DATE('2026-05-30', 'YYYY-MM-DD')
  AND mta_data_as_of < TO_DATE('2026-05-31', 'YYYY-MM-DD')
LIMIT 5000
"

Oodatav tulemus: Dashboard kuvab välja eelmise päeva maksuvõlglaste arvu.
