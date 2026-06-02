# Cron pipeline raport 2026-06-02

## Eesmärk

Kontrollida ja parandada igapäevane MREV andmepipeline, et cron käivitaks järjestuse:

1. RAW MTA import
2. RAW RIK import
3. STAGE incremental refresh
4. MART_STAR refresh

Tulemus peab olema see, et Superseti MART_STAR andmed on pärast päevaseid RAW laadimisi värsked.

## Enne muudatust

pi kasutaja crontab oli varundatud faili:

`/home/pi/kool/projekt/backups/cron/pi_crontab_before_2026-06-02_101909.txt`

Algne crontab:

```cron
# RIK Äriregistri snapshot iga päev kell 12:00
0 12 * * * /home/pi/kool/projekt/scripts/paevane_rik_snapshot.sh

# MTA maksuvõlglaste CSV allalaadimine ja PostgreSQL raw import iga päev kell 07:00
0 7 * * * /home/pi/kool/projekt/scripts/paevane_mta_maksuvolglased.sh

# STAGE kihi incremental refresh pärast päevaseid RAW laadimisi.
# Kasutab flock'i, et eelmine STAGE refresh ei kattuks järgmisega.
30 13 * * * /usr/bin/flock -n /tmp/mrev_stage_refresh.lock /home/pi/kool/projekt/scripts/refresh_stage_incremental.sh >/dev/null 2>&1

# MART kihi refresh pärast STAGE refreshi.
# Superseti dashboard loeb MART vaateid/cache tabeleid.
30 15 * * * /usr/bin/flock -n /tmp/mrev_mart_refresh.lock /home/pi/kool/projekt/scripts/refresh_mart.sh >/dev/null 2>&1
```

Probleemid:

- STAGE ja vana MART refresh olid eraldi cron ridadena.
- MART_STAR refresh ei olnud cron-is.
- Vana `refresh_mart.sh` käis edasi, kuigi Superseti jaoks on vaja MART_STAR kihti.

Root kasutajal crontabi ei olnud: `no crontab for root`.

## Pärast muudatust

Lõplik pi kasutaja crontab:

```cron
# MTA maksuvõlglaste CSV allalaadimine ja PostgreSQL RAW import iga päev kell 07:00
0 7 * * * /home/pi/kool/projekt/scripts/paevane_mta_maksuvolglased.sh

# RIK Äriregistri snapshot allalaadimine ja PostgreSQL RAW import iga päev kell 12:00
0 12 * * * /home/pi/kool/projekt/scripts/paevane_rik_snapshot.sh

# RAW -> STAGE -> MART_STAR värskendus iga päev pärast RIK laadimist
30 13 * * * /home/pi/kool/projekt/scripts/paevane_pipeline_refresh.sh >/dev/null 2>&1
```

Muudatus:

- 07:00 MTA RAW import jäi alles.
- 12:00 RIK RAW import jäi alles.
- 13:30 lisati üks terviklik wrapper: `scripts/paevane_pipeline_refresh.sh`.
- Eraldi STAGE cron rida eemaldati.
- Vana MART cron rida `refresh_mart.sh` eemaldati.

## Loodud skriptid

### `scripts/paevane_pipeline_refresh.sh`

Wrapper teeb ühe lukustatud jooksuna:

1. kuvab RAW, STAGE ja MART_STAR viimased kuupäevad enne refreshi;
2. käivitab `scripts/refresh_stage_incremental.sh`;
3. käivitab `scripts/refresh_mart_star.sh`;
4. kuvab RAW, STAGE ja MART_STAR viimased kuupäevad pärast refreshi;
5. kontrollib, kas MTA järgi pipeline on värske.

Logi nimi on kujul:

`logs/paevane_pipeline_refresh_YYYY-MM-DD_HHMMSS.log`

Wrapper kasutab lukku:

`/tmp/mrev_pipeline_refresh.lock`

### `scripts/check_pipeline_freshness.sh`

Kontrollskript kuvab:

- iga kihi viimase kuupäeva;
- `raw_mta_max`;
- `stage_mta_max`;
- `mart_star_fact_max`;
- STAGE MTA snapshotite arvu;
- MART_STAR faktitabeli kuupäevade arvu;
- `pipeline_fresh`;
- `snapshot_count_ok`.

## Käsitsi kontroll enne wrapperit

Enne käsitsi wrapperi käivitust oli seis:

```text
mart_star_fact        2026-05-31
raw_mta               2026-06-02
raw_rik               2026-06-01
stage_mta             2026-05-31
stage_rik_ettevotted  2026-05-31
stage_rik_isikud      2026-05-31
```

Freshness:

```text
raw_mta_max=2026-06-02
stage_mta_max=2026-05-31
mart_star_fact_max=2026-05-31
stage_mta_snapshot_count=10
mart_star_fact_snapshot_count=10
pipeline_fresh=f
snapshot_count_ok=t
```

Järeldus: MTA RAW oli uuem kui STAGE ja MART_STAR. Pipeline oli vananenud.

## Käsitsi wrapperi test

Käivitatud:

```bash
./scripts/paevane_pipeline_refresh.sh
```

Peamine wrapperi logi:

`logs/paevane_pipeline_refresh_2026-06-02_102317.log`

Seotud logid:

- `logs/stage_incremental_refresh_2026-06-02_102318.log`
- `logs/stage_snapshot_refresh_2026-06-01_20260602_102355.log`
- `logs/stage_snapshot_refresh_2026-06-02_20260602_103844.log`
- `logs/mart_star_refresh_2026-06-02_104806.log`

Tulemus:

```text
tulemus=OK
kestus_sekundites=1937
```

STAGE incremental refresh töötles:

- 2026-06-01: MTA RAW olemas, RIK RAW olemas, kvaliteedikontroll OK.
- 2026-06-02: MTA RAW olemas, RIK RAW puudus, MTA STAGE laadis 17 997 rida ja kvaliteedikontroll OK.

Märkus: käsitsi test algas 2026-06-02 kell 10:23, enne RIK päevast 12:00 croni. Seetõttu oli `raw_rik` viimane kuupäev 2026-06-01 ja 2026-06-02 RIK osa jäi teadlikult vahele staatusega `SKIPPED: RAW puudub`.

MART_STAR refresh:

```text
dim_ettevote_ridu            22407
dim_aeg_ridu                 15
dim_vanuse_grupp_ridu        4
mta_kuupaevi_faktis          12
fact_maksuvolg_ridu          226951
fact_maksuvola_summa         3745719933.55
juhatuse_muutusega_faktiridu 65
rik_vordluseta_mta_kuupaevi  1
tulemus=OK
```

`rik_vordluseta_mta_kuupaevi=1` on ootuspärane, sest 2026-06-02 RIK RAW ei olnud käsitsi testi ajal veel laetud.

## Kontroll pärast wrapperit

Wrapperi lõpus ja sõltumatu `scripts/check_pipeline_freshness.sh` käivitusega kontrollitud seis:

```text
mart_star_fact        2026-06-02
raw_mta               2026-06-02
raw_rik               2026-06-01
stage_mta             2026-06-02
stage_rik_ettevotted  2026-06-01
stage_rik_isikud      2026-06-01
```

Freshness:

```text
raw_mta_max=2026-06-02
stage_mta_max=2026-06-02
mart_star_fact_max=2026-06-02
stage_mta_snapshot_count=12
mart_star_fact_snapshot_count=12
pipeline_fresh=t
snapshot_count_ok=t
```

Järeldus: MTA põhine RAW -> STAGE -> MART_STAR pipeline on värske ja MART_STAR kuupäevad klapivad STAGE MTA snapshotitega.

## Kui pipeline muutub uuesti vanaks

Kontroll:

```bash
cd /home/pi/kool/projekt
./scripts/check_pipeline_freshness.sh
```

Kui `pipeline_fresh=f`, siis:

1. kontrolli, kas päeva RAW logid on olemas:
   - `logs/maksuvolglased_YYYY-MM-DD.log`
   - `logs/rik_snapshot_YYYY-MM-DD.log`
2. kui RAW import ebaõnnestus, paranda RAW import ja käivita vastav RAW skript uuesti;
3. käivita:
   ```bash
   ./scripts/paevane_pipeline_refresh.sh
   ```
4. kontrolli uuesti:
   ```bash
   ./scripts/check_pipeline_freshness.sh
   ```
5. kui wrapper ebaõnnestub, vaata viimast logi:
   ```bash
   ls -lt logs/paevane_pipeline_refresh_*.log
   ```

Kui käsitsi kontroll toimub enne 12:00, võib RIK viimane kuupäev olla eelmise päeva oma. Tavapärases cron järjestuses käib RIK import 12:00 ja terviklik pipeline 13:30.

## Progress fail

`docs/progress.md` faili projektis ei olnud, seega seda ei uuendatud ega loodud.

## Kokkuvõte

Cron on parandatud nii, et päevane pipeline käivitab pärast RAW laadimisi ühe wrapperiga STAGE incremental refreshi ja MART_STAR refreshi. Käsitsi test lõpetas tulemusega OK ning lõplik freshness-kontroll näitas:

```text
pipeline_fresh=t
snapshot_count_ok=t
```
