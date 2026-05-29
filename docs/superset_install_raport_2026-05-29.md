# Superseti paigalduse raport

Koostatud: 2026-05-29
Projekt: `andmeprojekt`
Host: Raspberry Pi 4 / `aarch64`

## Kokkuvõte

Apache Superset paigaldati Docker Compose kaudu andmeprojekti kõrvale. Superset
töötab eraldi konteineris `andmeprojekt_superset`, kasutab metadata andmebaasina
PostgreSQL andmebaasi `superset_meta` ning on lokaalselt kättesaadav aadressil:

```text
http://127.0.0.1:8088
```

Väline ligipääs ei ole seadistatud. Ruuteri porte ei avatud. PostgreSQL ja
Adminer ei saanud selle töö käigus uut avalikku ligipääsu.

## Eeltingimuste kontroll

MART kiht oli enne Superseti paigaldust olemas. Kontrollitud `mart` skeemi
vaated:

- `mart.v_dashboard_kpi`
- `mart.v_juhatuse_muutused_viimane_paev`
- `mart.v_latest_dates`
- `mart.v_maksuvolg_juhatuse_muutus_vanusegrupp`
- `mart.v_maksuvolg_vanusegruppide_kaupa`
- `mart.v_maksuvolglased_juhatuse_muutusega`
- `mart.v_top_maksuvolglased`
- `mart.v_viimased_maksuvolglased_rik_andmetega`

KPI kontroll:

| Näitaja | Väärtus |
| --- | ---: |
| MTA andmeseis | 2026-05-26 |
| RIK snapshot | 2026-05-27 |
| MTA ettevõtteid | 37 442 |
| RIK ühildumise määr | 98.47% |
| Maksuvõlg kokku | 622 471 286.38 |

## Arhitektuur ja image

Hosti arhitektuur:

```text
aarch64
```

Docker:

- Docker Engine: 27.5.1
- Docker Compose: 2.33.0
- Docker OS/Arch: `linux/arm64`

`apache/superset:latest` manifest sisaldas `linux/arm64` platformi, seega
ametlikku image'it sai kasutada.

## Lisatud failid

```text
.gitignore
.env.superset.example
docker-compose.superset.yml
superset/Dockerfile
superset/superset_config.py
scripts/setup_superset_postgres.sh
docs/superset_install_raport_2026-05-29.md
```

Lokaalselt loodi ka:

```text
.env.superset
```

Seda faili ei tohi GitHubi lisada. Fail sisaldab Superseti secret key'd,
metadata andmebaasi parooli, read-only kasutaja parooli ja algse admin-kasutaja
parooli.

## Dockerfile'i märkus

Superseti ametlik image kasutab `/app/.venv` keskkonda, kuid selles keskkonnas
ei ole `pip` käsufaili. Seetõttu paigaldab `superset/Dockerfile`
`psycopg2-binary` otse Superseti venv site-packages kausta:

```dockerfile
RUN pip install --no-cache-dir --target /app/.venv/lib/python3.10/site-packages psycopg2-binary
```

Import kontroll õnnestus:

```text
psycopg2 ok 2.9.12
```

## PostgreSQL seadistus

Loodi või uuendati rollid:

- `superset_meta`
- `superset_readonly`

Loodi metadata andmebaas:

- `superset_meta`

`superset_meta` on Superseti enda sisemine andmebaas kasutajate, dashboard'ide,
datasetite ja muude Superseti objektide jaoks.

`superset_readonly` on andmeprojekti analüüsiühenduse kasutaja. Sellele anti:

```sql
GRANT CONNECT ON DATABASE andmeprojekt TO superset_readonly;
GRANT USAGE ON SCHEMA mart TO superset_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA mart TO superset_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA mart
GRANT SELECT ON TABLES TO superset_readonly;
```

Lisaks eemaldati otse antud õigused `raw` ja `stage` skeemidelt.

Kontrollitud tulemus:

- `superset_readonly` saab lugeda `mart` vaateid.
- `raw` skeemi päring ebaõnnestub õiguste puudumisega.
- `stage` skeemi päring ebaõnnestub õiguste puudumisega.

Töötava Superseti konteineri seest tehtud ühendustest:

```text
mart_connection_ok 2026-05-26 2026-05-27
raw_access_denied ProgrammingError
```

## Superseti init

Käivitatud käsud:

```bash
docker compose -f docker-compose.yml -f docker-compose.superset.yml build superset
docker compose -f docker-compose.yml -f docker-compose.superset.yml run --rm superset superset db upgrade
docker compose -f docker-compose.yml -f docker-compose.superset.yml run --rm superset superset fab create-admin ...
docker compose -f docker-compose.yml -f docker-compose.superset.yml run --rm superset superset init
docker compose -f docker-compose.yml -f docker-compose.superset.yml up -d superset
```

Admin kasutaja loodi:

```text
andrus_admin
```

Parool on ainult lokaalses `.env.superset` failis. Seda raportisse ega GitHubi
ei kirjutatud.

## Käivituse kontroll

Konteiner:

```text
andmeprojekt_superset
```

Lõplik Docker seis:

```text
projekt-superset   Up, healthy   127.0.0.1:8088->8088/tcp
```

HTTP kontroll:

```text
curl -I http://127.0.0.1:8088/
HTTP/1.1 302 FOUND
Location: /superset/welcome/
```

Logi näitas, et Gunicorn käivitus ja kuulab pordil 8088:

```text
Starting gunicorn 23.0.0
Listening at: http://0.0.0.0:8088
Using worker: gthread
```

Logis on hoiatus, et rate limit kasutab in-memory storage'it. See on lokaalse
testpaigalduse jaoks aktsepteeritav, kuid tootmiskasutuses tuleks Supersetile
lisada Redis või muu sobiv backend.

## Ligipääs

Superset on seotud ainult Pi4 localhostiga:

```yaml
ports:
  - "127.0.0.1:8088:8088"
```

Sama masina brauseris:

```text
http://127.0.0.1:8088
```

Teisest arvutist kasuta SSH tunnelit:

```bash
ssh -L 8088:127.0.0.1:8088 pi@PI4_IP
```

Seejärel ava oma arvutis:

```text
http://localhost:8088
```

Välise ligipääsu jaoks tuleb teha eraldi otsus, näiteks Tailscale või HTTPS
reverse proxy. Seda selles ülesandes ei seadistatud.

## Andmeühenduse lisamine Superseti UI-s

Superseti andmebaasiühendust ei lisatud automaatselt metadata andmebaasi, sest
see eeldaks parooli salvestamist importfaili või Superseti metadata otse
muutmist. Ühendus testiti konteineri seest SQLAlchemy kaudu ja töötab.

Lisa ühendus UI kaudu:

```text
Settings -> Data -> Database Connections -> + DATABASE
```

SQLAlchemy URI:

```text
postgresql+psycopg2://superset_readonly:<PAROOL>@andmeprojekt_postgres:5432/andmeprojekt
```

Parool võta lokaalsest failist:

```text
.env.superset
SUPERSET_READONLY_DB_PASSWORD
```

Testi ühendust Superseti nupuga `Test Connection`.

## Datasetid, mida lisada

Lisa Supersetis:

```text
Data -> Datasets -> + Dataset
```

Soovitatavad datasetid:

- `mart.v_dashboard_kpi`
- `mart.v_maksuvolg_vanusegruppide_kaupa`
- `mart.v_maksuvolg_juhatuse_muutus_vanusegrupp`
- `mart.v_top_maksuvolglased`
- `mart.v_maksuvolglased_juhatuse_muutusega`
- `mart.v_viimased_maksuvolglased_rik_andmetega`

Esimese dashboard'i jaoks piisab neist:

- `mart.v_dashboard_kpi`
- `mart.v_maksuvolg_vanusegruppide_kaupa`
- `mart.v_maksuvolg_juhatuse_muutus_vanusegrupp`
- `mart.v_top_maksuvolglased`

## Soovitatavad esimesed chartid

1. KPI: maksuvõlg kokku
   - Dataset: `mart.v_dashboard_kpi`
   - Metric: `maksuvolg_summa`

2. KPI: maksuvõlglaste arv
   - Dataset: `mart.v_dashboard_kpi`
   - Metric: `mta_ettevotteid`

3. Tulpdiagramm: maksuvõlg vanusegruppide kaupa
   - Dataset: `mart.v_maksuvolg_vanusegruppide_kaupa`
   - X: `volg_vanuse_grupp`
   - Y: `maksuvolg_summa`

4. Tulpdiagramm: juhatus muutus / ei muutunud
   - Dataset: `mart.v_maksuvolg_juhatuse_muutus_vanusegrupp`
   - Mõõde: `juhatus_muutus`
   - Mõõdik: `maksuvolg_summa`

5. Tabel: top maksuvõlglased
   - Dataset: `mart.v_top_maksuvolglased`
   - Sorteeri: `maksuvolg DESC`

## Tuuli ja Külli kasutajad

Tuuli ja Külli kasutajaid ei loodud, sest e-posti aadresse ja ajutisi paroole
ei olnud turvaliselt antud.

Soovitatav luua UI kaudu:

```text
Settings -> Security -> List Users -> + User
```

Soovitatav roll projekti praeguses faasis:

```text
Alpha
```

Andmebaasi turvapiir on siiski `superset_readonly` kasutaja. Isegi kui kasutaja
on Supersetis Alpha rollis, kasutab andmeühendus PostgreSQL-is read-only rolli.

## Käivitamine, peatamine ja logid

Käivita:

```bash
docker compose -f docker-compose.yml -f docker-compose.superset.yml up -d superset
```

Peata:

```bash
docker compose -f docker-compose.yml -f docker-compose.superset.yml stop superset
```

Logid:

```bash
docker logs -f andmeprojekt_superset
```

Metadata migratsiooni korduskäivitus, kui Superseti versioon muutub:

```bash
docker compose -f docker-compose.yml -f docker-compose.superset.yml run --rm superset superset db upgrade
docker compose -f docker-compose.yml -f docker-compose.superset.yml run --rm superset superset init
```

## Turvamärkused

- `.env.superset` ei ole GitHubi jaoks.
- Superset on seotud ainult `127.0.0.1:8088` külge.
- PostgreSQL porti `5432` ei avatud internetti.
- Admineri porti `8080` ei avatud internetti.
- Ruuteri port forwardingut ei seadistatud.
- Väliligipääs vajab eraldi Tailscale või HTTPS reverse proxy otsust.

Paigalduse käigus avastati, et üks ajutine testkäsk pani read-only parooli
protsessireale. Test peatati ja `superset_readonly` parool roteeriti kohe
uueks; PostgreSQL roll ning `.env.superset` uuendati ja Superseti konteiner
loodi uuesti.

## Lõppseis

Superset on paigaldatud ja töötab.

Valmis:

- Docker image buildib ametliku `apache/superset:latest` arm64 image'i baasil.
- `psycopg2-binary` on Superseti keskkonnas olemas.
- `superset_meta` metadata andmebaas on olemas.
- `superset_readonly` kasutaja on olemas.
- `superset_readonly` saab lugeda `mart` skeemi.
- `superset_readonly` ei saa lugeda `raw` ega `stage` skeeme.
- Superset admin kasutaja `andrus_admin` on loodud.
- Superset konteiner töötab ja on `healthy`.
- HTTP kontroll `127.0.0.1:8088` vastab.

Järgmine töö:

- Lisa Superseti UI-s andmeühendus `andmeprojekt` andmebaasile.
- Lisa MART vaated datasetitena.
- Loo esimesed KPI ja tabeli chartid.
- Loo Tuuli ja Külli kasutajad, kui nende e-postid ja ajutised paroolid on
  turvaliselt antud.
