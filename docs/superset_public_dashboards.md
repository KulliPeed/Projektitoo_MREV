# Superset Public Dashboardid

Serveripoolne seadistus lubab Supersetis valikuliselt avalikke lugemisvaates dashboarde.
Superset tervikuna ei ole avalik: SQL Lab, admin-menüüd, kasutajad, rollid, datasetid ja andmebaasiühendused ei ole anonüümsele kasutajale mõeldud.

## Avalikustamine

Dashboardi avalikuks tegemiseks peab dashboardi omanik või admin tegema Superseti veebiliideses järgmised sammud:

1. Ava valmis dashboard.
2. Veendu, et dashboard on `Published`.
3. Ava dashboardi properties.
4. Lisa rollide alla `Public`.
5. Salvesta muudatus.
6. Testi dashboardi linki incognito/private aknas.

Avalikuks tohib teha ainult hindamiseks mõeldud valmis dashboardid.
Dashboardid, mille properties all ei ole `Public` rolli, peavad jääma anonüümselt suletuks.

Testimiseks sobib tavaline dashboardi link:

```text
https://planeggmobile.com:8443/superset/dashboard/<dashboard_id_or_slug>/
```

Puhtama vaaterežiimi jaoks saab lisada `standalone=1`:

```text
https://planeggmobile.com:8443/superset/dashboard/<dashboard_id_or_slug>/?standalone=1
```

## Serveri Seadistus

Seadistus asub failis:

```text
/home/pi/kool/projekt/superset/superset_config.py
```

Superseti Docker Compose service on `superset`.
Compose mountib konfiguratsiooni containerisse:

```text
./superset/superset_config.py:/app/pythonpath/superset_config.py:ro
```

Public dashboardide tugi on lubatud nende seadetega:

```python
AUTH_ROLE_PUBLIC = "Public"
PUBLIC_ROLE_LIKE = "Public"

FEATURE_FLAGS = {
    "DASHBOARD_RBAC": True,
}
```

Pärast configi muutmist tuleb Superset restartida ja õigused sünkroniseerida:

```bash
cd /home/pi/kool/projekt
docker compose -f docker-compose.yml -f docker-compose.superset.yml restart superset
docker compose -f docker-compose.yml -f docker-compose.superset.yml exec superset superset init
```

## Kontroll

Kontrolli, et Superset vastab ja ei anna 500 viga:

```bash
curl -k -I https://planeggmobile.com:8443/
```

Kontrolli brauseris:

- admin-kasutaja saab sisse logida;
- olemasolevad dashboardid avanevad loginiga nagu enne;
- dashboard avaneb incognito aknas ainult siis, kui properties all on roll `Public`;
- public kasutaja ei näe SQL Labi ega admin-menüüsid.

## Rollback

Live configist tehti enne muudatust varukoopia:

```text
/home/pi/kool/projekt/superset/superset_config.py.bak_public_dashboard
```

Taastamine:

```bash
cd /home/pi/kool/projekt
cp superset/superset_config.py.bak_public_dashboard superset/superset_config.py
docker compose -f docker-compose.yml -f docker-compose.superset.yml restart superset
docker compose -f docker-compose.yml -f docker-compose.superset.yml exec superset superset init
```
