# MART_STAR kihi raport 2026-05-31

> Uuendus 2026-06-01: juhatuse muutuse arvutus viidi vana `mart` vaate pealt STAGE-põhiseks. Täpne kirjeldus on failis `docs/mart_star_juhatuse_muutus_stage_pohine_2026-06-01.md`.

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
kasutades iga data_as_of kuupäeva kohta hiliseimat STAGE-is olemasolevat MTA snapshoti.
```

Kui sama `data_as_of` kuupäev esineb mitmes MTA snapshotis, valitakse selle andmeseisu hiliseim snapshot. Näiteks `2026-05-26` andmeseis oli STAGE-is kahes snapshotis; faktis kasutatakse selle kuupäeva jaoks ainult hilisemat snapshotit.

Faktitabeli unikaalsus on `UNIQUE (dim_ettevote_id, kuupaev)`, sest grain on ettevõte + MTA andmeseisu kuupäev.

## Allikad

Kasutatud allikad:

- `stage.mta_maksuvolglased`
- `stage.rik_ettevotted`
- `stage.rik_kaardile_kantud_isikud`
- `mart_star.v_juhatuse_muutus_paeviti`

RAW tabeleid tähtmudeli koostamisel ei kasutatud. Seisuga 2026-06-01 arvutatakse juhatuse muutuse lipp STAGE RIK juhatuse liikmete snapshotite põhjal abivaates `mart_star.v_juhatuse_muutus_paeviti`.

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

Lõplik edukas logi:

```text
logs/mart_star_refresh_2026-05-31_171050.log
```

Kokkuvõte:

| Näitaja | Väärtus |
| --- | ---: |
| `dim_ettevote` ridu | 22 366 |
| `dim_aeg` ridu | 13 |
| `dim_vanuse_grupp` ridu | 4 |
| `fact_maksuvolg` ridu | 172 193 |
| Faktis MTA andmeseisu kuupäevi | 9 |
| Faktide maksuvõla summa | 2 826 491 012.76 |
| Juhatuse muutusega faktiridu | 72 |
| RIK-ist leitud faktiridu | 169 468 |

Kuupäevade lõikes:

| Kuupäev | Faktiridu | Maksuvõla summa |
| --- | ---: | ---: |
| `2026-05-21` | 21 560 | 336 548 235.87 |
| `2026-05-22` | 20 023 | 319 542 775.35 |
| `2026-05-23` | 19 448 | 315 391 629.49 |
| `2026-05-24` | 19 354 | 314 862 986.65 |
| `2026-05-26` | 18 721 | 311 235 643.19 |
| `2026-05-27` | 18 479 | 310 246 935.92 |
| `2026-05-28` | 18 307 | 307 576 101.24 |
| `2026-05-29` | 18 219 | 306 345 151.68 |
| `2026-05-30` | 18 082 | 304 741 553.37 |

Vanusegruppide lõikes:

| Vanusegrupp | Faktiridu | Maksuvõla summa |
| --- | ---: | ---: |
| `kuni 2 kuud` | 39 061 | 168 789 255.07 |
| `2-5 kuud` | 28 432 | 266 033 431.74 |
| `6-11 kuud` | 24 140 | 308 808 691.03 |
| `>= 1 aasta` | 80 560 | 2 082 859 634.92 |

## Kontrollid

Fail `quality/040_mart_star_quality_checks.sql` kontrollis:

- kõik 4 `mart_star` objekti on olemas;
- `dim_aeg`, `dim_ettevote` ja `fact_maksuvolg` sisaldavad ridu;
- `dim_vanuse_grupp` sisaldab täpselt 4 rida;
- `dim_ettevote` ridade arv võrdub valitud MTA lõigetes esinevate unikaalsete registrikoodide arvuga;
- faktitabelis ei ole orbe `dim_ettevote`, `dim_aeg` ega `dim_vanuse_grupp` suhtes;
- faktis on kõik valitud MTA `data_as_of` kuupäevad;
- faktide maksuvõla summa võrdub valitud STAGE MTA snapshotite registrikoodi lõikes koondatud summaga;
- kuupäeva kaupa faktiridade arv ja summa klapivad STAGE valitud snapshotitega;
- faktiridade arv võrdub valitud STAGE MTA lõigete ettevõte+kuupäev ridade arvuga;
- faktis ei ole ettevõte+kuupäev duplikaate;
- juhatuse muutuse arvud ei ole negatiivsed ega NULL;
- faktis ei ole vanusegruppe, mida dimensioonis ei ole;
- README1 vastavustabel on kooskõlas loodud füüsiliste objektidega.

Tulemus:

```text
FK kontrollid: OK
Kuupäevade kontroll: OK, 9 kuupäeva 2026-05-21 kuni 2026-05-30
Faktisumma kontroll: OK, 2826491012.76 = 2826491012.76
Faktiridade kontroll: OK, 172193 = 172193
Grain duplikaatide kontroll: OK
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
