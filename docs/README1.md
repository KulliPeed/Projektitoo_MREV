```mermaid
erDiagram
    DIM_ETTEVOTE ||--o{ FACT_MAKSUVOLG : "omab"
    DIM_AEG ||--o{ FACT_MAKSUVOLG : "toimub"

    DIM_AEG {
        date kuupaev PK
        int paev
        int kuu
        int aasta
    }
    DIM_ETTEVOTE {
        string registrikood PK
        string nimi
    }
    FACT_MAKSUVOLG {
        int id PK
        string registrikood FK
        date kuupaev FK
        float maksuvola_summa
        string maksuvola_vanuse_grupp
        boolean juhatuse_muutuse_fakt
    }
