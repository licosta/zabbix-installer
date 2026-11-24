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

La red debe permitir descargar `repo.zabbix.com` y `packagecloud.io`. Si el IPv6
no tiene ruta util, el instalador lo detecta al ver que el indice no aterriza y
reintenta forzando IPv4. Cuando aun asi falla, deja la salida completa de
`apt-get update` en `/tmp/zabbix-apt-update.err` y el error indica si el indice
del repositorio quedo descargado o no.

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

| Zabbix | Repositorio oficial | TimescaleDB admitida |
| --- | --- | --- |
| 7.0 (LTS) | `repo.zabbix.com/zabbix/7.0/debian` | 2.13.0 - 2.30.x |
| 7.4 | `repo.zabbix.com/zabbix/7.4/stable/debian` | 2.13.0 - 2.30.x |
| 8.0 (LTS) | `repo.zabbix.com/zabbix/8.0/stable/debian` | 2.20.0 - 2.29.x |

La version de TimescaleDB se fija por version de Zabbix: el servidor Zabbix rechaza
arrancar con una version de TimescaleDB demasiado nueva. El rango no es arbitrario,
es el que fija el propio codigo de cada revision (`ZBX_TIMESCALE_MIN_SUPPORTED_VERSION`
y `ZBX_TIMESCALE_MAX_VERSION` en `include/zbx_dbversion_constants.h`).

El rango **cambia entre revisiones de una misma rama**: `8.0.0` admite hasta 2.29.x,
mientras que las revisiones posteriores de la rama 8.0 ya admiten 2.30.x y 2.31.x.
Por eso el instalador:

- instala siempre la revision mas nueva de la serie maxima admitida por la rama
  elegida, en lugar de "la ultima publicada" (el repositorio de packagecloud ya
  publica 2.32.x, que **ninguna** de estas ramas acepta: el servidor abortaria
  con `TimescaleDB version is too new`);
- comprueba en el nodo servidor la version de TimescaleDB de la base de datos
  contra el limite que declara el propio binario `zabbix-server` instalado, y
  avisa con el comando exacto a ejecutar si no encaja.

### Repositorio oficial de Zabbix

La fuente se fija siempre en la rama que publica los binarios: `stable` en 7.4 y
8.0, y `7.0/debian` en 7.0. La rama `release` publica **unicamente** el
metapaquete `zabbix-release` (Architecture: all) y ningun binario, de modo que
una fuente que apunte a ella no ofrece ni `zabbix-server-pgsql` ni
`zabbix-sql-scripts`.

El paquete que se valida es el que necesita de verdad el nodo: `zabbix-sql-scripts`
en el nodo de base de datos y `zabbix-server-pgsql` en el nodo servidor. La
validacion se hace contra la version que sirve **ese** repositorio y no contra
el candidato global de APT, porque los repos de Debian ofrecen Zabbix 7.0 y el
candidato caeria ahi si el indice del repositorio de Zabbix no estuviera
disponible.

`apt-get update` puede devolver 0 y dejar el indice sin descargar (la maquina
resuelve el host pero la transferencia se queda a medias, o el IPv6 no tiene
ruta util), y en ese caso `apt-cache` no encuentra ningun paquete aunque el
repositorio este bien configurado. Por eso el instalador no se fia del codigo
de salida: comprueba que el indice este en disco y reintenta con opciones cada
vez mas agresivas (normal, forzando IPv4 y regenerando la cache local de APT).

### Nodo servidor: host y agente

El esquema de Zabbix crea un host llamado `Zabbix server` cuya interfaz de
agente apunta a `127.0.0.1`. El agente2 del nodo servidor se configura en modo
activo con `Hostname` igual al nombre del equipo, de modo que el servidor
Zabbix no encontraba ese host (`host not found`) y no llegaba ningun item.

El instalador renombra ese host con el nombre del equipo y apunta su interfaz
de agente a la IP del servidor. La seleccion del host se hace por el nombre del
esquema y por la interfaz de agente en `127.0.0.1`, **nunca** por la tabla
`hosts_templates`: en Zabbix 8.0 esa tabla solo relaciona los hosts que tienen
plantilla asignada y no distingue las filas que son plantilla. Si la seleccion
no devuelve exactamente un host, no se modifica nada.

El esquema de Zabbix 8.0 cambio respecto a 7.0/7.4: no existe la tabla
`templates` (las plantillas son filas de `hosts`) y la tabla de interfaces se
llama `interface` en singular. El instalador detecta la variante.

El agente acepta conexiones entrantes del Zabbix server desde su IP y desde el
loopback (`Server=<IP del servidor>,127.0.0.1`): con solo `127.0.0.1` el
servidor rechazaba las consultas al agente y los items se quedaban sin valor.

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

Version 1.0.0, certificada en maquinas virtuales reales con Debian 13.7:

- **Zabbix 7.0 nativo** en dos nodos (servidor + base de datos).
- **Zabbix 7.4 nativo** en dos nodos (servidor + base de datos).
- **Zabbix 8.0 nativo** en dos nodos (servidor + base de datos).
- **Zabbix 8.0 en Docker**.

En las cuatro se verifico el arranque real de los servicios, el esquema importado en
la base de datos (con sus hypertables), la respuesta HTTP del frontend, el token de
la API y la recepcion de datos del agente.

Ademas se certifico un **despliegue nativo real** en dos nodos (base de datos y
servidor + frontend, Debian 13, 4 vCPU): esquema importado, 10 hypertables con
compresion activada por el propio `zabbix-server`, frontend respondiendo y datos
del agente llegando a la base de datos.

Nota: el paquete oficial de Zabbix 7.0 y 8.0 no activa la compresion de TimescaleDB
(la deja en manos de la propia aplicacion), mientras que el de 7.4 si la aplica.

### Detalle de la API en Zabbix 8.0

En la version 8.0 el campo `auth` del cuerpo JSON-RPC ya no se acepta. Tras
`user.login` hay que enviar el token en la cabecera HTTP:

```bash
curl -s -X POST http://<servidor>:8080/api_jsonrpc.php \
  -H 'Content-Type: application/json-rpc' \
  -H "Authorization: Bearer <token>" \
  -d '{"jsonrpc":"2.0","method":"host.get","params":{"output":["host"]},"id":1}'
```

En 7.0 y 7.4 el token se sigue pasando en el campo `auth` de primer nivel (verificado
en las dos versiones).
