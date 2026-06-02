# MART_STAR juhatuse muutus STAGE põhjal 2026-06-01

## Miks muudatus tehti

Varasem `mart_star.fact_maksuvolg.juhatuse_muutuse_fakt` sõltus vana `mart` kihi vaatest `mart.v_juhatuse_muutused_viimane_paev`. See ei sobinud lõpliku tähtmudeli jaoks, sest juhatuse muutuse tunnus peab tulema otse STAGE kihist ja olema arvutatud iga MTA snapshot-kuupäeva kohta.

Muudatuse järel arvutab `mart_star` juhatuse muutuse `stage.rik_kaardile_kantud_isikud` põhjal ning vana `mart` juhatuse muutuse vaadet enam ei kasutata.

## Ärireegel

Faktitabeli grain:

```text
üks rida = ettevõte + MTA snapshot_date
```

`mart_star.fact_maksuvolg.kuupaev = stage.mta_maksuvolglased.snapshot_date`.

Iga MTA snapshot-kuupäeva D kohta võrreldakse:

```text
RIK juhatuse liikmed kuupäeval D
versus
RIK juhatuse liikmed kuupäeval D - 1
```

Kui ettevõttel on D päeval juhatuse liikmeid lisandunud või D-1 juhatuse liige D päeval puudub, siis `juhatuse_muutuse_fakt = true`. Kui võrdlust ei saa teha, jääb faktirida alles ja `juhatuse_muutuse_fakt = false`.

Juhatuse liikme võrdlusvõti:

```sql
COALESCE(
    NULLIF(btrim(isikukood), ''),
    'NAME:' || lower(COALESCE(NULLIF(btrim(isik_nimi), ''), '')) ||
    '|ROLE:' || COALESCE(NULLIF(btrim(roll), ''), '') ||
    '|START:' || COALESCE(rolli_alguskuupaev::text, '')
)
```

Arvesse lähevad ainult read, kus `on_juhatuse_liige = true`.

## Loodud või muudetud objektid

- `mart_star.juhatuse_muutus_paeviti`
- `mart_star.v_juhatuse_muutus_paeviti`
- `mart_star.fact_maksuvolg`
- `db/migrations/130_create_mart_star_schema.sql`
- `quality/040_mart_star_quality_checks.sql`
- `scripts/refresh_mart_star.sh`
- `docs/README1.md`

## Eelkontrollid

MTA STAGE snapshotid:

| snapshot_date | data_as_of | ridu | unikaalseid registrikoode |
| --- | --- | ---: | ---: |
| 2026-05-22 | 2026-05-21 | 21 561 | 21 560 |
| 2026-05-23 | 2026-05-22 | 20 025 | 20 023 |
| 2026-05-24 | 2026-05-23 | 19 451 | 19 448 |
| 2026-05-25 | 2026-05-24 | 19 355 | 19 354 |
| 2026-05-26 | 2026-05-26 | 18 721 | 18 721 |
| 2026-05-27 | 2026-05-26 | 18 721 | 18 721 |
| 2026-05-28 | 2026-05-27 | 18 480 | 18 479 |
| 2026-05-29 | 2026-05-28 | 18 309 | 18 307 |
| 2026-05-30 | 2026-05-29 | 18 221 | 18 219 |
| 2026-05-31 | 2026-05-30 | 18 083 | 18 082 |

RIK `stage.rik_kaardile_kantud_isikud` snapshotid on olemas kuupäevadel `2026-05-19` kuni `2026-05-31`. Kõigi 10 MTA snapshot-kuupäeva jaoks oli olemas nii RIK sama päeva snapshot kui ka eelneva päeva snapshot.

Puuduliku RIK D/D-1 võrdlusega MTA kuupäevi: `0`.

## Käivituse tulemus

Refresh käivitati skriptiga:

```bash
scripts/refresh_mart_star.sh
```

Edukalt läbinud logi:

```text
logs/mart_star_refresh_2026-06-01_230842.log
```

Kokkuvõte:

| Näitaja | Väärtus |
| --- | ---: |
| MTA snapshot-kuupäevi faktis | 10 |
| `fact_maksuvolg` ridu | 190 914 |
| `dim_ettevote` ridu | 22 366 |
| Maksuvõlg kokku | 3 137 726 655.95 |
| Juhatuse muutusega faktiridu | 65 |
| RIK D/D-1 võrdluseta MTA kuupäevi | 0 |

Juhatuse muutusega faktiridu kuupäevade kaupa:

| kuupaev | fact_rows | juhatuse_muutusega_fact_rows |
| --- | ---: | ---: |
| 2026-05-22 | 21 560 | 16 |
| 2026-05-23 | 20 023 | 13 |
| 2026-05-24 | 19 448 | 0 |
| 2026-05-25 | 19 354 | 0 |
| 2026-05-26 | 18 721 | 1 |
| 2026-05-27 | 18 721 | 6 |
| 2026-05-28 | 18 479 | 10 |
| 2026-05-29 | 18 307 | 7 |
| 2026-05-30 | 18 219 | 4 |
| 2026-05-31 | 18 082 | 8 |

## Kvaliteedikontrollid

`quality/040_mart_star_quality_checks.sql` läbis järgmised kontrollid:

- kõik `mart_star` objektid ja abivaade on olemas;
- faktis on kõik 10 MTA snapshot-kuupäeva;
- `fact_maksuvolg.kuupaev = mta_snapshot_date` kõigil ridadel;
- faktisumma klapib STAGE snapshotite summaga: `3137726655.95 = 3137726655.95`;
- faktiridade arv klapib STAGE ettevõte+snapshot grainiga: `190914 = 190914`;
- kuupäeva kaupa read ja summad klapivad STAGE kihiga;
- faktis ei ole ettevõte+snapshot duplikaate;
- `mart_star.v_juhatuse_muutus_paeviti` sisaldab 190 914 rida ja klapib faktitabeli grainiga;
- faktis olev juhatuse muutuse lipp ja lisatud/eemaldatud liikmete arvud klapivad abivaatega;
- `juhatuse_muutuse_fakt` ei ole NULL;
- negatiivseid juhatuse liikmete arve ei ole;
- vanusegruppide FK kontroll on OK.

Koodikontrollis ei jäänud `db/migrations/130_create_mart_star_schema.sql`, `quality/040_mart_star_quality_checks.sql` ega `scripts/refresh_mart_star.sh` sisse vana `mart.v_juhatuse_muutused_viimane_paev` või `FROM/JOIN mart.*` sõltuvust.

## Puutumata objektid

RAW ja STAGE tabeleid ei muudetud. Olemasolevat Superseti dashboardi ei muudetud. Refresh tühjendab ja täidab ainult `mart_star` skeemi tabeleid.
