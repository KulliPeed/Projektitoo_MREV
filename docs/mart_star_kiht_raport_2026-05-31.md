# MART_STAR kihi raport 2026-05-31

## Eesmärk

`mart_star` loodi selleks, et `docs/README1.md` kirjeldatud klassikaline tähtmudel oleks andmebaasis füüsiliselt olemas. Senine `mart` skeem jääb alles, sest see on töötav Superseti/dashboard'i kiht vaadete ja cache tabelitega.

`mart_star` on lisakiht, mitte olemasoleva `mart` asendus.

## Loodud objektid

| README1 objekt | Füüsiline objekt |
| --- | --- |
| `DIM_AEG` | `mart_star.dim_aeg` |
| `DIM_ETTEVOTE` | `mart_star.dim_ettevote` |
| `DIM_VANUSE_GRUPP` | `mart_star.dim_vanuse_grupp` |
| `FACT_MAKSUVOLG` | `mart_star.fact_maksuvolg` |

Failid:

- `db/migrations/130_create_mart_star_schema.sql`
- `quality/040_mart_star_quality_checks.sql`
- `scripts/refresh_mart_star.sh`
- `docs/README1.md`
- `docs/mart_star_kiht_raport_2026-05-31.md`

## Faktitabeli grain

`mart_star.fact_maksuvolg` grain:

```text
üks rida = üks ettevõte ühe MTA andmeseisu kuupäeva kohta,
kasutades viimast STAGE-is olemasolevat MTA snapshoti.
```

Viimane kasutatud MTA snapshot oli `2026-05-31`, andmeseisu kuupäevaga `2026-05-30`. Kui samal registrikoodil oli selles snapshotis mitu rida, koondati read üheks faktireaks registrikoodi lõikes. Faktitabeli unikaalsus on `UNIQUE (dim_ettevote_id, kuupaev)`, sest grain on ettevõte + MTA andmeseisu kuupäev.

## Allikad

Kasutatud allikad:

- `stage.mta_maksuvolglased`
- `stage.rik_ettevotted`
- `stage.rik_kaardile_kantud_isikud`
- `mart.v_latest_dates`
- `mart.v_juhatuse_muutused_viimane_paev`

RAW tabeleid tähtmudeli koostamisel ei kasutatud.

## Vanusegrupid

`mart_star.dim_vanuse_grupp` sisaldab 4 rida ja kasutab STAGE kihiga sama loogikat:

| Grupp | min_paevi | max_paevi |
| --- | ---: | ---: |
| `kuni 2 kuud` | 1 | 59 |
| `2-5 kuud` | 60 | 179 |
| `6-11 kuud` | 180 | 364 |
| `>= 1 aasta` | 365 | NULL |

## Käivituse tulemus

Refresh käivitati skriptiga:

```bash
scripts/refresh_mart_star.sh
```

Logi:

```text
logs/mart_star_refresh_2026-05-31_142044.log
```

Kokkuvõte:

| Näitaja | Väärtus |
| --- | ---: |
| `dim_ettevote` ridu | 18 082 |
| `dim_aeg` ridu | 13 |
| `dim_vanuse_grupp` ridu | 4 |
| `fact_maksuvolg` ridu | 18 082 |
| Faktide maksuvõla summa | 304 741 553.37 |
| Juhatuse muutusega faktiridu | 8 |
| RIK-ist leitud ettevõtteid faktis | 17 795 |

Vanusegruppide lõikes:

| Vanusegrupp | Faktiridu | Maksuvõla summa |
| --- | ---: | ---: |
| `kuni 2 kuud` | 3 296 | 12 702 086.76 |
| `2-5 kuud` | 3 194 | 27 599 495.35 |
| `6-11 kuud` | 2 653 | 33 556 462.49 |
| `>= 1 aasta` | 8 939 | 230 883 508.77 |

## Kontrollid

Fail `quality/040_mart_star_quality_checks.sql` kontrollis:

- kõik 4 `mart_star` objekti on olemas;
- `dim_aeg`, `dim_ettevote` ja `fact_maksuvolg` sisaldavad ridu;
- `dim_vanuse_grupp` sisaldab täpselt 4 rida;
- faktitabelis ei ole orbe `dim_ettevote`, `dim_aeg` ega `dim_vanuse_grupp` suhtes;
- faktide maksuvõla summa võrdub viimase STAGE MTA snapshoti registrikoodi lõikes koondatud summaga;
- faktiridade arv võrdub viimase STAGE MTA snapshoti unikaalsete registrikoodide arvuga;
- juhatuse muutuse arvud ei ole negatiivsed ega NULL;
- faktis ei ole vanusegruppe, mida dimensioonis ei ole;
- README1 vastavustabel on kooskõlas loodud füüsiliste objektidega.

Tulemus:

```text
FK kontrollid: OK
Faktisumma kontroll: OK, 304741553.37 = 304741553.37
Faktiridade kontroll: OK, 18082 = 18082
README1 vastavus: OK
Superseti SELECT õigused mart_star tabelitele: OK
```

## Superseti seos

Olemasolev Superseti dashboard võib jätkata `mart.v_*` vaadete ja `mart.superset_cache_*` tabelite kasutamist.

Kui soovitakse näidata klassikalist tähtmudelit, saab Supersetisse lisada uued datasetid:

- `mart_star.dim_ettevote`
- `mart_star.dim_aeg`
- `mart_star.dim_vanuse_grupp`
- `mart_star.fact_maksuvolg`

Dataset'e automaatselt ei loodud.

## Puutumata objektid

Olemasolevaid `raw`, `stage` ja `mart` skeeme ning andmeid ei kustutatud ega tühjendatud. Refresh tühjendab ja täidab ainult `mart_star` skeemi tabeleid.
