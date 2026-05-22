```mermaid
erDiagram
    DIM_ETTEVOTE ||--o{ FACT_MAKSUVOLG : "omab"
    DIM_AEG ||--o{ FACT_MAKSUVOLG : "toimub"

    DIM_ETTEVOTE {
        string registrikood PK
        string nimi
    }
    FACT_MAKSUVOLG {
        int id PK
        string registrikood FK
        date kuupaev FK
        float summa
        string vanuse_grupp
        boolean juhatuse_muutus
    }
