# Makseraskustes ettevõtete juhatuse muutuste varajane tuvastamine

> **Juhend:** Asenda kõik nurksulgudes vormid oma sisuga enne esitamist. Kustuta see juhendrida.

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
    source1[EMTA maksuvõla andmed] --> ingest["Sissevõtt<br/>bash wrapper/Python/SQL"]
    source2[RIK äriregistri andmed] --> ingest

    %% Scheduler / orkestreerimine
    cron["Cron (scheduler)"] --> ingest

    %% Andmebaas (PostgreSQL)
    subgraph db[PostgreSQL]
        raw[(raw)]
        staging[(staging)]
        mart[(mart)]
    end

    %% Andmetöötlus
    ingest --> raw
    raw --> transform1["Puhastamine, ühtlustamine<br/>bash wrapper/Python/SQL"]

    transform1 --> staging
    staging --> transform2["Ühendamine, rikastamine<br/>bash wrapper/Python/SQL"]

    transform2 --> mart

    %% Tarbimine
    mart --> dashboard["Näidikulaud (Superset)"]
    raw -->  source3[Andmekvaliteedi testid]
    staging --> source3[Andmekvaliteedi testid]
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
| Sissevõtt | [Python / SQL / Bash wrapper] |
| Transformatsioon | [Python / SQL / Bash wrapper] |
| Andmehoidla | PostgreSQL |
| Näidikulaud | [Superset] |
| Orkestreerimine | [cron] |

## Käivitamine

```bash
# 1. Klooni repo ja liigu kausta
git clone <repo-url>
cd <projekti-kaust>

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

Kõik saladused (paroolid, API võtmed, andmebaasi URL-id) on `.env` failis. Repos on ainult `.env.example`, mis näitab vajalike muutujate struktuuri ilma tegelike väärtusteta. Päris `.env` faili ei tohi GitHubi panna - see on `.gitignore`-s.

Vajalikud muutujad:

| Muutuja | Tähendus | Näide |
|---------|----------|-------|
| `DB_PASSWORD` | PostgreSQL parool | (saladus) |
| `[teised]` | ... | ... |

## Andmevoog lühidalt

1. **Sissevõtt** — [Kirjelda, kuidas andmed allikast kätte saadakse]
2. **Laadimine** — Andmed laaditakse `raw` kihti
3. **Transformatsioon** — [Kirjelda peamised arvutused ja mudelid]
4. **Testimine** — 18 andmekvaliteedi testi erinevate kihtide (raw, staging, mart) andmete kontrollimiseks, mis salvestuvad tabelisse quality.data_quality_results ja kuvatakse ka dashboardil.
5. **Näidikulaud** — Näidikulaud näitab viimase päeva juhatuse vahetusega maksuvõlgnike nimekirja, juhatuse vahetusega ettevõtete arvu ja maksuvõlga, nende muutust ajas ning maksuvõlga maksuvõla vanusegruppides. Lisaks ka andmekvaliteedi testide tulemused.

## Andmekvaliteedi testid

Projekt kontrollib järgmist:

1. [Test 1 - nt: kasutajate ID on unikaalne]
2. [Test 2 - nt: tellimuse summa pole null]
3. [Test 3 - nt: kuupäev jääb vahemikku 2020-2026]
[Lisa rohkem, kui sul on]

Testide tulemused: [kuhu salvestatakse / kuidas vaadata]

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
- [Loetle, mis on lõpule viidud, mis töötab hästi]

**Puudused:**
- [Loetle ausalt, mis jäi tegemata - see ei mõjuta hinnet negatiivselt, vaid aitab hinnata]

**Mis edasi:**
- [Mida tahaksid edasi teha, kui aega oleks rohkem]

## Meeskond

| Nimi | Roll |
|------|------|
| Andrus Säde | Andmeallika omanik |
| Andrus Säde/Tuuli Hani/Külli Peeduli | Transformatsioonide omanik |
| Tuuli Hani/Külli Peeduli | Kvaliteedi omanik |
| Külli Peeduli/Tuuli Hani | Näidikulaua omanik |

Iga rolli juurde märgitud esimene isik on põhivastutaja ja teised märgitud on kaasvastutajad
