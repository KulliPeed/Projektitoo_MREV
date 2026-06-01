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
    }
    DIM_ETTEVOTE {
        int ettevote_id PK
        string registrikood UK
        string nimi
    }
    FACT_MAKSUVOLG {
        int id PK
        int dim_ettevote_id FK
        date kuupaev FK
        float maksuvola_summa
        string maksuvola_vanuse_grupp FK
        boolean juhatuse_muutuse_fakt
    }
    DIM_VANUSE_GRUPP {
        string maksuvola_vanuse_grupp PK
        int min_paevi
        int max_paevi
        int jarjestus
    }
