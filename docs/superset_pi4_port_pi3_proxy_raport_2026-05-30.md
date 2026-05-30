# Superseti Pi4 pordi ja Pi3 HTTPS proxy kontroll

Aeg: 2026-05-30

## Eesmärk

Teha Pi4 Dockeris töötav Superset LAN-is Pi3 proxy jaoks kättesaadavaks aadressil:

```text
http://192.168.3.30:8088
```

ning kontrollida, et Pi3 ajutine HTTPS proxy port `8443` suunab Superseti poole.

## Tehtud muudatused Pi4 peal

1. `docker-compose.superset.yml` port mapping on:

```yaml
ports:
  - "8088:8088"
```

See asendab vana ainult localhosti külge seotud mappingu `127.0.0.1:8088:8088`.

2. `superset/superset_config.py` reverse proxy seaded:

```python
ENABLE_PROXY_FIX = True
PREFERRED_URL_SCHEME = "https"
```

3. Superseti konteiner recreate'iti sama compose kombinatsiooniga, millega ta oli loodud:

```bash
docker compose   -f /home/pi/kool/projekt/docker-compose.yml   -f /home/pi/kool/projekt/docker-compose.superset.yml   up -d --force-recreate superset
```

Volume'e ei kustutatud ja `docker compose down -v` ei kasutatud.

## Pi4 kontrollid

Compose teenused:

```text
postgres
superset
adminer
```

Pi4 IP:

```text
192.168.3.30
```

Konteineri port mapping pärast recreate'i:

```text
0.0.0.0:8088
[::]:8088
```

`docker ps` näitas Superseti kohta:

```text
0.0.0.0:8088->8088/tcp, :::8088->8088/tcp
```

HTTP testid Pi4 peal:

```text
curl -I http://localhost:8088       -> HTTP/1.1 302 FOUND
curl -I http://192.168.3.30:8088    -> HTTP/1.1 302 FOUND
```

See tähendab, et Superset ei ole enam ainult localhostis ja Pi3 saab LAN IP kaudu ühenduda.

## Pi3 proxy kontroll LAN-ist

Pi4 pealt testitud Pi3 nginx ajutine HTTPS proxy:

```text
curl -k -I https://192.168.3.10:8443 -H 'Host: planeggmobile.com'
```

Tulemus:

```text
HTTP/1.1 302 FOUND
Server: nginx/1.22.1
Location: /superset/welcome/
```

See kinnitab, et Pi3 `8443` nginx proxy jõuab Supersetini.

Pi3 SSH kaudu kontrolli ei saanud teha, sest SSH autentimine ei õnnestunud:

```text
Permission denied (publickey,password)
```

## Olemasolev põhiveeb ei muutunud

Kontrollid:

```text
curl -k -I https://192.168.3.10 -H 'Host: planeggmobile.com' -> HTTP/1.1 200 OK
curl -k -I https://planeggmobile.com                         -> HTTP/1.1 200 OK
```

Mõlemad vastasid WordPressi / olemasoleva saidi päistega, mitte Supersetiga.

## Välise URL-i seis

Kohalikust võrgust test:

```text
curl -k -I https://planeggmobile.com:8443
```

andis:

```text
Failed to connect to planeggmobile.com port 8443
```

Pi4 ja Pi3 proxy pool on korras. Välise URL-i jaoks on veel vaja ruuteris port forward:

```text
WAN TCP 8443 -> Pi3 192.168.3.10 TCP 8443
```

Olemasolevaid `80` ja `443` suunamisi ei tohi muuta, sest need kuuluvad päris `planeggmobile.com` saidile.

## Kokkuvõte

Pi4 Superset on LAN-is kättesaadav:

```text
http://192.168.3.30:8088
```

Pi3 ajutine HTTPS proxy töötab LAN-ist:

```text
https://192.168.3.10:8443
```

Tavaline `https://planeggmobile.com` jäi olemasoleva päris saidi peale.

Väliseks kasutuseks on vaja ainult ruuteri `8443 -> Pi3:8443` port forwardit.
