# zabbix-install.sh

Instalador interactivo de Zabbix para despliegues en clientes, en dos modos:

- **Opcion 1 - Nativa distribuida** sobre Debian 13 (Trixie), en dos nodos:
  - Nodo **Servidor Zabbix**: server + frontend (nginx/PHP-FPM) + agent2
  - Nodo **Base de datos**: PostgreSQL 17 + TimescaleDB con el esquema importado
- **Opcion 2 - Contenerizada**: instala Docker y Docker Compose, genera
  `docker-compose.yml` en el directorio actual y levanta el stack con persistencia.

## Requisitos

- Debian 13 (Trixie) x86_64, con acceso a internet para descargar paquetes.
- Ejecucion con permisos de administrador (`sudo`).
- Para el modo nativo: dos maquinas (servidor y base de datos) con red IP entre ellas.

## Uso

```bash
git clone https://github.com/licosta/zabbix-installer.git
cd zabbix-installer
sudo ./zabbix-install.sh
```

El script va guiado por menus: rol del nodo, version de Zabbix, direccion IP del
servidor y de la base de datos, puerto del frontend, zona horaria y contrasena de
la base de datos. Al final muestra un resumen de la instalacion antes de ejecutarla.

### Variables de entorno

| Variable | Efecto |
| --- | --- |
| `ZBX_NO_COLOR=1` | Desactiva la salida con colores (util en logs). |
| `ZBX_ASSUME_YES=1` | No pide confirmaciones: despliegue desatendido. |

## Versiones soportadas

| Zabbix | Repositorio oficial | TimescaleDB |
| --- | --- | --- |
| 7.0 (LTS) | `repo.zabbix.com/zabbix/7.0/debian` | 2.29.2 |
| 7.4 | `repo.zabbix.com/zabbix/7.4/stable/debian` | 2.30.2 |
| 8.0 (LTS) | `repo.zabbix.com/zabbix/8.0/stable/debian` | 2.29.2 |

La version de TimescaleDB se fija por version de Zabbix: el servidor Zabbix rechaza
arrancar con una version de TimescaleDB demasiado nueva.

## Orden de ejecucion (modo nativo)

1. En el **nodo de base de datos**, ejecutar el script y elegir la opcion 2
   (Nodo Base de Datos), indicando la IP del servidor Zabbix: ese sera el unico
   origen permitido para conectarse a PostgreSQL.
2. En el **nodo servidor**, ejecutar el script y elegir la opcion 1
   (Nodo Servidor Zabbix), indicando la IP del nodo de base de datos y la misma
   contrasena.

El frontend queda accesible en `http://<IP-servidor>:<puerto>` con las credenciales
por defecto `Admin` / `zabbix` (cambiar tras el primer acceso).

## Modo Docker

El script instala Docker y Docker Compose, crea la estructura de directorios
(`zabbix/alertscripts`, `externalscripts`, `snmptraps`, `export`, `certs`),
escribe `.env` con las credenciales (permisos 600) y genera
`docker-compose.yml`. El stack incluye PostgreSQL 17 con TimescaleDB, el servidor
Zabbix y el frontend nginx. Para aplicarlo en el servidor:

```bash
cd <directorio-del-stack>
docker compose up -d
docker compose ps
```

## Estado

Version 1.0.0, certificada en maquinas virtuales reales con Debian 13.7
(Zabbix 7.4 nativo en dos nodos y Zabbix 8.0 en Docker): esquema de la base de
datos importado, hypertables creadas, servicios activos y frontend respondiendo.
