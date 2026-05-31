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
-

## Mis takistab

- aega on vähe

## Kontrollpunkt

Käsk, millega saab kontrollida, et töövoog töötab:

```bash
# [Lisa siia käsk, mis näitab, et andmed liiguvad allikast näidikulauani]
# Näiteks:
docker compose exec pipeline python scripts/run_pipeline.py check
```

Oodatav tulemus: [Kirjelda, mida töötav süsteem väljastab]
