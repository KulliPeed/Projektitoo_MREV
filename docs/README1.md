# MART_STAR tähtmudel

Tähtmudel on andmebaasis skeemis `mart_star`.

| README1 objekt | Füüsiline objekt |
| --- | --- |
| `DIM_AEG` | `mart_star.dim_aeg` |
| `DIM_ETTEVOTE` | `mart_star.dim_ettevote` |
| `DIM_VANUSE_GRUPP` | `mart_star.dim_vanuse_grupp` |
| `FACT_MAKSUVOLG` | `mart_star.fact_maksuvolg` |

Olemasolev `mart` skeem sisaldab dashboard'i jaoks loodud vaateid ja Superseti cache tabeleid. `mart_star` on eraldi dimensioonmudel, mis vastab allolevale ER skeemile ega asenda praegust Superseti dashboard'i kihti.

## Faktitabeli grain

`mart_star.fact_maksuvolg` grain:

```text
üks rida = üks ettevõte + üks MTA snapshot_date.
```

`FACT_MAKSUVOLG.kuupaev` vastab MTA `snapshot_date` väärtusele. `mta_data_as_of` on faktitabelis lisainfo veerg, kuid graini ei määra. Kui ühel registrikoodil on samas MTA snapshotis mitu rida, koondatakse need üheks faktireaks registrikoodi ja snapshot-kuupäeva lõikes.

`FACT_MAKSUVOLG.juhatuse_muutuse_fakt` arvutatakse `stage.rik_kaardile_kantud_isikud` põhjal. Iga MTA snapshoti kuupäeva D kohta võrreldakse RIK juhatuse liikmete seisu kuupäeval D ja kuupäeval D-1. Kui ettevõttel lisandus juhatuse liige või varasem juhatuse liige puudub D päeval, siis `juhatuse_muutuse_fakt = true`. Kui RIK D/D-1 võrdlust ei saa teha, jääb faktirida alles ja väärtus on `false`.

## ER skeem

Mermaid diagramm kasutab kontseptuaalseid README1 nimesid. Füüsilised tabelid on ülal olevas vastavustabelis.

```mermaid
erDiagram
    DIM_ETTEVOTE ||--o{ FACT_MAKSUVOLG : "omab"
    DIM_AEG ||--o{ FACT_MAKSUVOLG : "toimub"
    DIM_VANUSE_GRUPP ||--o{ FACT_MAKSUVOLG : "vanus"

    DIM_AEG {
        date kuupaev PK
        int paev
        int kuu
        int aasta
        int kvartal
        int nadal
        string kuu_nimi
        string paeva_nimi
        boolean is_weekend
    }

    DIM_ETTEVOTE {
        int ettevote_id PK
        string registrikood UK
        string nimi
        string mta_nimi
        string rik_nimi
        string oiguslik_vorm
        string staatus
        boolean leitud_rikist
        date latest_mta_snapshot_date
        date latest_mta_data_as_of
        date latest_rik_snapshot_date
    }

    FACT_MAKSUVOLG {
        int fact_id PK
        int dim_ettevote_id FK
        date kuupaev FK
        float maksuvola_summa
        string maksuvola_vanuse_grupp FK
        boolean juhatuse_muutuse_fakt
        date mta_snapshot_date
        date mta_data_as_of
        date rik_snapshot_date
        date previous_rik_snapshot_date
        string registrikood
        float vaidlustatud_summa
        float tasumisgraafikus_summa
        int volg_vanus_paevades
        int lisatud_juhatuse_liikmeid
        int eemaldatud_juhatuse_liikmeid
        int praegune_juhatuse_liikmete_arv
        int eelmine_juhatuse_liikmete_arv
        boolean leitud_rikist
    }

    DIM_VANUSE_GRUPP {
        string maksuvola_vanuse_grupp PK
        int min_paevi
        int max_paevi
        int jarjestus
    }
```

## Superseti kasutus

Olemasolev Superseti dashboard võib jätkata `mart.v_*` vaadete ja `mart.superset_cache_*` tabelite kasutamist.

Kui soovitakse näidata klassikalist tähtmudelit, saab Supersetisse lisada uued datasetid:

- `mart_star.dim_ettevote`
- `mart_star.dim_aeg`
- `mart_star.dim_vanuse_grupp`
- `mart_star.fact_maksuvolg`
