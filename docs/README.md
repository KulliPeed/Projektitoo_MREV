# Makseraskustes ettevõtete juhatuse muutuste varajane tuvastamine

## Äriküsimus

Eesmärgiks on välja selgitada, kui palju on maksuvõlas ettevõtteid, mille juhatus on muutunud viimase päeva jooksul ning milline on nende ettevõtete maksuvõla kogusumma päevase seisuga, jaotatuna võla vanuse gruppidesse (kuni 2 kuud, 2-5 kuud, 6-11 kuud, ≥ 1 aasta).
Selleks loodud juhtimislaud võimaldab saada varajase ja ajakohase ülevaate ettevõtetest, millel esinevad makseraskused koos juhatuse muutustega ning jälgida selliste ettevõtete arvu ja jaotust ajas. Püstitus on maksuhalduri vajadusest lähtuvalt ent võimalik on võtta kasutusele ka ettevõtetes sidudes kliendibaasiga ja hinnata seeläbi varakult riske kliendi käitumises. Kasu saajateks on Maksu- ja Tolliamet, ettevõtted, krediidihalduse ettevõtted ja pankrotihaldurid, kuna juhatuse vahetus võib viidata probleemsete võlgadega ettevõtetele. 

**Mõõdikud:**

1. Juhatuse muutusega maksuvõlglaste arv viimase päeva seisuga.
2. Juhatuse muutusega maksuvõlglaste maksuvõlg viimase päeva seisuga.
3. Maksuvõlglaste arv kokku viimase päeva seisuga.
4. Viimase 7 päeva lõikes juhatuse muutusega ettevõtete maksuvõla kogusumma võla vanuse gruppides.
5. Viimase päeva seisuga juhatuse liikme vahetusega maksuvõlglaste nimekiri.
6. Viimase 7 päeva kohta juhatuse muutusega ja muutusteta maksuvõlglaste arv.


## Arhitektuur

```mermaid
flowchart LR
    %% Andmeallikad
    source1[EMTA maksuvõla andmed] --> ingest["Sissevõtt Cron cheduleriga:<br/>09:30 MTA ja 12:00 RIK <br/>bash wrapper/Python/SQL"]
    source2[RIK äriregistri andmed] --> ingest

    %% Andmebaas (PostgreSQL)
    subgraph db[PostgreSQL]
        raw[(raw)]
        stage[(stage)]
        mart[(mart)]
    end

    %% Andmetöötlus
    ingest --> raw
    raw --> transform1["Puhastamine, ühtlustamine<br/>bash wrapper/Python/SQL"]

    transform1 --> stage
    stage --> transform2["Ühendamine, rikastamine<br/>bash wrapper/Python/SQL"]

    transform2 --> mart

    %% Tarbimine
    mart --> dashboard["Näidikulaud (Superset)"]
    raw -->  source3[Andmekvaliteedi testid]
    stage --> source3[Andmekvaliteedi testid]
    mart --> source3[Andmekvaliteedi testid]
  
```

Täpsem kirjeldus: [`docs/arhitektuur.md`](https://github.com/KulliPeed/Projektitoo_MREV/blob/main/docs/arhitektuur.md)

## Andmestik

| Allikas | Tüüp | Ajas muutuv? | Roll |
|---------|------|--------------|------|
| [EMTA maksuvõla avaandmed](https://ncfailid.emta.ee/s/XKJLjtynFeYdGyC/download/maksuvolglaste_nimekiri.csv) | CSV | Jah, 1 kord päevas | Sisend ettevõtete maksuvõla olemasolu ja selle vanuse tuvastamisel |
| [RIK Äriregistri avaandmed, kaardile kantud isikud](https://avaandmed.ariregister.rik.ee/sites/default/files/avaandmed/ettevotja_rekvisiidid__kaardile_kantud_isikud.json.zip) | JSON | Jah, 1 kord päevas | Sisend juhatuse liikmete seoste ja nende muutuste tuvastamisel |

## Stack

| Komponent | Tööriist |
|-----------|---------|
| Sissevõtt | Python / SQL / Bash wrapper + cron |
| Transformatsioon | Python / SQL / Bash wrapper |
| Andmehoidla | PostgreSQL |
| Näidikulaud | Superset |
| Orkestreerimine | cron |

## Käivitamine

```bash
# 1. Klooni repo ja liigu kausta
git clone <https://github.com/KulliPeed/Projektitoo_MREV.git>
cd <Projektitoo_MREV>

# 2. Kopeeri keskkonnamuutujad
cp .env.example .env
# Muuda .env failis paroolid ja muud seaded vastavalt vajadusele

# 3. Käivita teenused
docker compose up -d --build

# 4. [Vabatahtlik: käivita sissevõtt käsitsi esimesel korral]
# docker compose exec pipeline python scripts/run_pipeline.py run-all
```

Airflow (kui kasutatakse): http://localhost:8080 (kasutaja: airflow / parool: airflow)
Näidikulaud: http://localhost:[PORT]

## Saladused ja konfiguratsioon

Kõik paroolid, secret key väärtused ja andmebaasi DSN-id peavad olema `.env` või `.env.superset` failides. Päris `.env` ja `.env.superset` faile ei tohi GitHubi commit'ida. Repos peab olema ainult näidisfail, näiteks `.env.superset.example` ja  `.env.example`.

| Muutuja | Tähendus | Näide |
|---|---|---|
| `DB_PASSWORD` või `POSTGRES_PASSWORD` | PostgreSQL parool raw loaderite ja quality runneri jaoks | `<redigeeritud>` |
| `RUN_DATA_QUALITY_CHECKS` | Kas 13:30 pipeline käivitab quality runneri | `false` vaikimisi, `true` kui vaja |
| `DATA_QUALITY_FAIL_PIPELINE` | Kas quality FAIL katkestab pipeline'i | `false` vaikimisi |
| `SUPERSET_SECRET_KEY` | Superseti secret key | `<redigeeritud>` |
| `SUPERSET_METADATA_DB_URI` | Superseti metadata DB SQLAlchemy DSN | `<redigeeritud>` |
| `SUPERSET_READONLY_DB_USER` | Superseti lugemisroll | `superset_readonly` |
| `SUPERSET_READONLY_DB_PASSWORD` | Superseti lugemisrolli parool | `<redigeeritud>` |

## Andmevoog lühidalt

1. **Sissevõtt** —  Cron käivitab skriptid, mis laevad MTA CSV ja RIK JSON ZIP failid alla.
2. **Laadimine** — Andmed laaditakse RAW kihti.
3. **Transformatsioon** — [Kirjelda peamised arvutused ja mudelid]  `refresh_stage_incremental.sh` leiab puuduvad RAW snapshotid ja värskendab ainult vajalikud kuupäevad. `refresh_mart_star.sh` ehitab faktitabeli, ühendab MTA ja RIKi andmed ja arvutab vajalikud faktid (nt juhatuse muutuse, võla vanuse grupid jm) ja dimensioonid stage andmete põhjal.
4. **Testimine** — `run_data_quality_checks.py` kirjutab 18 andmekvaliteedi testi erinevate kihtide (raw, stage, mart) andmete kontrollimiseks, mis salvestuvad `quality` skeemi  (sh. quality.data_quality_results tabelisse) ja kuvatakse ka dashboardil.
5. **Näidikulaud** — Näidikulaud näitab viimase päeva juhatuse vahetusega maksuvõlgnike nimekirja, juhatuse vahetusega ettevõtete arvu ja maksuvõlga, nende muutust ajas ning maksuvõlga maksuvõla vanusegruppides. Lisaks ka andmekvaliteedi testide tulemusi.

## Andmekvaliteedi testid

Projekt kontrollib järgmist:

| Testi number | Testi nimi                       | Testi kontrollid                                                                 | DB kiht    | Allikas    |
|--------------|----------------------------------|-------------------------------------------------------------------------------|------------|------------|
| TEST 1       | fact_foreign_key_integrity       | FACT tabelis leidub võõrvõtmeid, millel puudub vaste dimensioonides.         | FACT       | MART_STAR  |
| TEST 2       | raw_data_as_of_idempotent        | RAW kihis on mitu snapshoti sama kuupäevaga.                                 | RAW        | MTA        |
| TEST 3       | raw_rik_download_success         | RIK andmete allalaadimine ebaõnnestus või ridade arv puudub.                 | RAW        | RIK        |
| TEST 4       | rik_raw_stage_parity             | RIK RAW ja STAGE ridade arv ei klapi.                                        | RAW_STAGE  | RIK        |
| TEST 5       | stage_fact_maksuvolg_sum_parity  | Maksuvõla summa STAGE ja FACT kihis ei klapi lubatud piirides.               | STAGE_FACT | MTA        |
| TEST 6       | stage_rik_bad_registrikood       | RIK registrikood ei vasta formaadile või on tühi.                             | STAGE      | RIK        |
| TEST 7       | stage_rik_duplicate_registrikood | RIK snapshotis esineb duplikaatregistrikoode.                                 | STAGE      | RIK        |
| TEST 8       | stage_mta_negative_maksuvolg     | MTA maksuvõlg sisaldab negatiivseid väärtusi.                                 | STAGE      | MTA        |
| TEST 9       | mart_star_snapshot_parity        | FACT snapshotide arv ei klapi STAGE snapshotidega.                            | MART_STAR  | MART_STAR  |
| TEST 10      | raw_mta_date_fields_not_null     | MTA andmetes puuduvad kuupäevaväljad või sisaldavad NULL väärtusi.            | RAW        | MTA        |
| TEST 11      | stage_mta_bad_registrikood       | MTA registrikood ei vasta formaadile või puudub.                              | STAGE      | MTA        |
| TEST 12      | fact_grain_uniqueness            | FACT tabelis esineb duplikaatridu sama ettevõtte ja kuupäeva kohta.           | FACT       | MART_STAR  |
| TEST 13      | stage_mta_null_maksuvolg         | MTA maksuvõlg sisaldab NULL väärtusi.                                         | STAGE      | MTA        |
| TEST 14      | raw_mta_download_success         | MTA andmete allalaadimine ebaõnnestus või ridade arv puudub.                 | RAW        | MTA        |
| TEST 15      | raw_source_structure_consistency | Allikandmete struktuur või veerunimed on muutunud.                            | RAW        | RIK        |
| TEST 16      | mta_raw_stage_parity             | MTA RAW ja STAGE ridade arv ei klapi.                                         | RAW_STAGE  | MTA        |
| TEST 17      | mart_star_required_columns       | MART_STAR veerud puuduvad.                                                    | MART_STAR  | MART_STAR  |
| TEST 18      | fact_juhatuse_muutuse_not_null   | FACT tabelis juhatuse_muutuse_fakt sisaldab NULL väärtusi.                   | FACT       | MART_STAR  |

Testide tulemused: salvestatakse quality.data_quality_results tabelisse ja on nähtavad dashboardil.

## Projekti struktuur

```
.
├── README.md
├── compose.yml
├── .env.example
├── .gitignore
├── docs/
│   ├── arhitektuur.md      ← nädal 1 väljund
│   └── progress.md         ← nädal 2 väljund
└── ...                     ← ülejäänud projektifailid
```

## Kokkuvõte, puudused ja võimalikud edasiarendused

**Kokkuvõte:**
- Soovitud andmevoog toimib otsast lõpuni ja on terviklik (andmed laetakse automaatselt andmebaasi ja tulemid kajastuvad juhtimislaual). Automaatne päevane pipeline laeb MTA ja RIK andmed, ehitab stage ja mart_star kihid ning võimaldab tulemusi Supersetis vaadata.
- Juhtimislaud kajastab õiget tulemit, vastab äriküsimusele ja kuvab ajas muutuvust.
- Piisaval hulgal andmekvaliteedi kontrolle on loodud ja toovad välja olulisemad esineda võivad andmekvaliteedi probleemid juhtimislaual. Andmekvaliteedi tulemused kirjutatakse eraldi quality skeemi.
- RAW import on idempotentne ja logib tegevused admin.raw_import_audit tabelisse.

**Puudused:**
- Kvaliteedi testid toovad välja mõningad probleemid mida ei peaks lugema veaks (nendega ei jõudnud tegeleda): nt. MTA andmed ei vasta formaadile aga MTA andmetes registrikood ei pea olema numbri formaadis, kuna nende hulgas esineb ka mitteresidente, kelle registrikood algab tähekombinatsiooniga. Andmekvaliteedi test "stage_mta_bad_registrikood" loeb sellised hetkel veaks.
- Skriptide puhastamisega ei jõudnud tegeleda.
- Andmekvaliteedi FAIL/WARN teavitusi me ei jõudnud luua, tekitasime ainult kokkuvõtte dashboardile.

**Mis edasi:**
- kõrvaldaks eelpool nimetatud puudused
- README kõrvale võiks luua docs/runbook.md, mis kirjeldab, kuidas süsteemi töös hoida, monitoorida ja probleemide korral parandada.

## Meeskond

| Nimi | Tööjaotuse roll |
|------|------|
| Andrus Säde | Andmeallika omanik |
| Andrus Säde/Tuuli Hani/Külli Peeduli | Transformatsioonide omanik |
| Tuuli Hani/Külli Peeduli | Kvaliteedi omanik |
| Külli Peeduli/Tuuli Hani | Näidikulaua omanik |

Iga rolli juurde märgitud esimene isik on põhivastutaja ja teised märgitud on kaasvastutajad
