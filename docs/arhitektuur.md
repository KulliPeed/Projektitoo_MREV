# Arhitektuur

## Äriküsimus

Kui palju on maksuvõlas ettevõtteid, mille juhatus on muutunud viimase päeva jooksul ning milline on nende ettevõtete maksuvõla kogusumma päevase seisuga, jaotatuna võla vanuse gruppidesse (kuni 2 kuud, 2-5 kuud, 6-11 kuud, ≥ 1 aasta)?

## Mõõdikud

1. **Juhatuse muutus** - ettevõttel loetakse juhatuse muutus toimunuks, kui võrreldes eelmise päeva (või viimase olemasoleva kuupäeva) andmetega:
lisandus vähemalt üks uus juhatuse liige või
vähemalt ühe varasema juhatuse liikme seos lõppes.
2. **Võla vanus päevades** - arvutatakse EMTA maksuvõla avaandmetes veergude "Andmed on seisuga" ja "vanima tasumata nõude tasumise tähtpäev" vahe päevades.
3. **Võla vanuse grupp** - maksuvõla vanuse päevade vahemik, klassifitseerituna: 1–59 päeva (kuni 2 kuud),
60–179 päeva (2–5 kuud),
180–364 päeva (6–11 kuud),
≥ 365 päeva (≥ 12 kuud / 1 aasta).

## Andmeallikad

| Allikas | Tüüp | Ajas muutuv? | Roll |
|---------|------|--------------|------|
| [EMTA maksuvõla avaandmed](https://ncfailid.emta.ee/s/XKJLjtynFeYdGyC/download/maksuvolglaste_nimekiri.csv) | CSV | Jah, 1 kord päevas | Sisend ettevõtete maksuvõla olemasolu ja selle vanuse tuvastamisel |
| [RIK Äriregistri avaandmed, kaardile kantud isikud](https://avaandmed.ariregister.rik.ee/sites/default/files/avaandmed/ettevotja_rekvisiidid__kaardile_kantud_isikud.json.zip) | JSON | Jah, 1 kord päevas | Sisend juhatuse liikmete seoste ja nende muutuste tuvastamisel |
> Esimesed katsetused tehtud, andmete sissevõtt õnnestub.
## Andmevoog

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

## Andmebaasi kihid

| Kiht | Roll |
|------|------|
| `raw` | Hoiab allika andmeid töötlemata kujul. |
| `staging` | Puhastatud ja ühtlustatud andmed. |
| `mart` | Hoiab transformeeritud ja äriloogikat sisaldavaid tabeleid. |

## Tööjaotus

| Roll | Vastutus | Täitja |
|------|----------|--------|
| Andmeallika omanik | Kirjutab sissevõtu loogika ja hoiab failide allalaadimise töös | Andrus |
| Transformatsioonide omanik | Kirjutab intermediate ja mart kihi mudelid ning mõõdikute arvutuse | Andrus/Külli/Tuuli |
| Kvaliteedi omanik | Kirjutab testid ja vaatab läbi ebaõnnestunud kontrollid | Tuuli/Külli |
| Näidikulaua omanik | Ehitab näidikulaua, visualiseeringud seotuna äriküsimusega | Külli/Tuuli |

>Iga rolli juurde märgitud esimene isik on põhivastutaja ja teised märgitud on kaasvastutajad
## Riskid

| Risk | Mõju | Maandus |
|------|------|---------|
| Risk 1 — EMTA päeva andmed jäävad puudu | Puudulikud või ebatäpsed tulemused | Veateavitus juhtimislaual + uus andmete laadimise/sissevõtu käivitus  |
| Risk 2 -  RIK päeva andmed jäävad puudu | Puudulikud või ebatäpsed tulemused | Veateavitus juhtimislaual + uus andmete laadimise/sissevõtu käivitus |
| Risk 3 -  allikandmete struktuur on muutunud | andmed jäävad uuendamata | Veateavitus juhtimislaual + koodimuudatus ja andmete sissevõtu taaskäivitus |
| Risk 4 - võla summa puudub | ei klassifitseeru võlaga ettevõtteks | Kui viimases saadaolevas snapshotis võla summa puudus, jätab ettevõtte kirje järgmisse kihti (staging) lisamata |

## Privaatsus ja turve

Kasutatakse ainult avalikke andmeid (avaandmed), mis ei vaja eraldi kaitset. Andmebaasi ligipääsuandmed hoitakse .env failis

