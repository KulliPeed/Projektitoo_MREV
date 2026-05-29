# MREV Superseti seadistus

Automaatseadistus käib projektikataloogist:

```bash
scripts/configure_superset_mrev.sh
```

Wrapper laadib `.env.superset` faili, käivitab `scripts/configure_superset_mrev.py`
ja kirjutab logi `logs/superset_mrev_config_YYYY-MM-DD_HHMMSS.log`.

Skript loob või kasutab olemasolevat Superseti database connectionit nimega
`MREV andmeprojekt MART`, mis ühendub PostgreSQL andmebaasiga `andmeprojekt`
kasutajana `superset_readonly`.

Seadistatavad datasetid:

```text
mart.v_dashboard_kpi
mart.v_maksuvolg_vanusegruppide_kaupa
mart.v_maksuvolg_juhatuse_muutus_vanusegrupp
mart.v_top_maksuvolglased
mart.v_maksuvolglased_juhatuse_muutusega
mart.v_viimased_maksuvolglased_rik_andmetega
```

Raport kirjutatakse `docs/superset_mrev_seadistuse_raport_YYYY-MM-DD.md`.
`.env.superset` ja logid ei kuulu GitHubi.
