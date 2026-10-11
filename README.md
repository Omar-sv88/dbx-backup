# dbx-backup

Script en Bash para hacer **backup y restore de contenedores [distrobox](https://github.com/89luca89/distrobox)**, con soporte para **podman** y **docker** y un **menú interactivo** donde eliges si quieres copia de todos los contenedores o solo de algunos.

Automatiza el procedimiento oficial de distrobox ([Container save and restore](https://github.com/89luca89/distrobox/blob/main/docs/useful_tips.md#container-save-and-restore)) y le añade:

- Menú de selección (uno, varios, rango o todos).
- Copia del **HOME propio** de los contenedores creados con `--home`.
- Metadatos y verificación de integridad (sha256).
- Modo no interactivo para cron / systemd.

## Cómo funciona

**Backup** (por cada contenedor):

1. `container commit -p <contenedor> <imagen>`: snapshot del contenedor (se pausa unos segundos).
2. `save <imagen>` comprimido en un único archivo `.tar.*`.
3. Si el contenedor tiene HOME propio, ese directorio se empaqueta aparte.
4. Se guardan los metadatos y se borra la imagen intermedia.

**Restore**:

1. Comprueba el checksum del backup.
2. `load` de la imagen en el gestor elegido.
3. Restaura el HOME propio, si lo había.
4. `distrobox create --image <imagen> --name <contenedor>` (con `--root` y `--home` cuando corresponda).

## Requisitos

| | |
|---|---|
| Obligatorios | `bash` ≥ 4, `distrobox`, `podman` **o** `docker`, `tar` |
| Opcionales | `zstd` (compresión por defecto si existe), `pigz`, `pbzip2`, `pv` (barra de progreso), `sha256sum` |

Si no hay `zstd`, se usa `gzip`.

## Instalación

```bash
git clone https://github.com/Omar-sv88/dbx-backup dbx-backup
cd dbx-backup
chmod +x dbx-backup.sh

# Opcional: tenerlo en el PATH
install -Dm755 dbx-backup.sh ~/.local/bin/dbx-backup
```

## Uso

### Menú interactivo

```bash
./dbx-backup.sh
```

```
╭──────────────────────────────────────────────╮
│   Distrobox Backup / Restore  v1.0.0         │
│   By Omar Santos                             │
╰──────────────────────────────────────────────╯
  Gestor:  podman (rootless)
  Destino: /home/usuario/distrobox-backups

  1) Hacer backup
  2) Restaurar backup
  3) Ver contenedores
  4) Ver backups
  5) Cambiar gestor (podman ↔ docker)
  6) Alternar rootless / rootful
  7) Cambiar carpeta de backups
  q) Salir
```

En los menús de selección puedes escribir:

| Entrada | Significado |
|---|---|
| `2` | Solo el contenedor 2 |
| `1 3 5` | Los contenedores 1, 3 y 5 |
| `2-4` | Del 2 al 4 |
| `a` | Todos |
| `q` | Volver |

Los contenedores con HOME propio se muestran con `[home: /ruta]`, y los backups que incluyen HOME con `+home`.

### Línea de comandos

```bash
./dbx-backup.sh backup --all                 # backup de todos los contenedores
./dbx-backup.sh backup arch ubuntu           # backup de los indicados
./dbx-backup.sh backup                       # menú de selección para backup

./dbx-backup.sh restore                      # menú de selección para restaurar
./dbx-backup.sh restore ~/distrobox-backups/arch_20261011-120000.tar.zst
./dbx-backup.sh restore --all                # restaura todos los backups de la carpeta

./dbx-backup.sh list                         # lista los contenedores distrobox
./dbx-backup.sh backups                      # lista los backups disponibles
```

### Opciones

| Opción | Descripción |
|---|---|
| `-m, --manager podman\|docker` | Gestor a usar. Por defecto se autodetecta (prioriza podman) |
| `-r, --root` | Contenedores rootful (`sudo podman` / `sudo docker`) |
| `-d, --dir DIR` | Carpeta de backups. Por defecto `~/distrobox-backups` |
| `-c, --compress ALG` | `zstd`, `gzip`, `bzip2`, `xz` o `none` |
| `-k, --keep-image` | No borrar la imagen intermedia creada por el commit |
| `-H, --no-home` | No copiar el HOME propio de los contenedores |
| `-y, --yes` | No preguntar nada (para automatizar) |
| `-a, --all` | Aplicar a todos (con `backup` / `restore`) |
| `-h, --help` | Ayuda |
| `-v, --version` | Versión |

### Variables de entorno

| Variable | Equivale a |
|---|---|
| `DBX_BACKUP_DIR` | `--dir` |
| `DBX_CONTAINER_MANAGER` | `--manager` |
| `DBX_BACKUP_COMPRESSION` | `--compress` |

## Qué se genera

Por cada backup, en la carpeta de destino:

```
arch_20261011-120000.tar.zst          # imagen del contenedor
arch_20261011-120000.meta             # metadatos (nombre, imagen original, gestor, checksums…)
arch_20261011-120000.inspect.json     # inspect completo del contenedor (referencia)
dev_20261011-120000.tar.zst
dev_20261011-120000.home.tar.zst      # HOME propio (solo si el contenedor lo tiene)
...
```

Mantén juntos todos los archivos de un mismo backup: el `.meta` es el que enlaza la imagen con su HOME.

## Sobre el HOME

distrobox puede funcionar de dos formas:

- **HOME compartido con el host** (por defecto): tus archivos son los del host. **No se copian**; haz su backup aparte. El script lo avisa al terminar.
- **HOME propio** (`distrobox create --home /ruta`): el directorio se empaqueta junto a la imagen. Al restaurar te pregunta dónde dejarlo (por defecto, la ruta original), lo que permite moverlo a otra máquina.

Si el directorio de destino ya existe y no está vacío, pregunta si sobrescribir (fusionar), mantener el actual o cancelar. Con `-y` **nunca** sobrescribe.

> **Consejo:** la imagen se congela pausando el contenedor, pero el HOME se copia con el contenedor en marcha. Si algo escribe ahí (bases de datos, IDEs abiertos…), párala antes con `distrobox stop <nombre>` para una copia consistente.

## Automatizar con cron

```cron
# Backup semanal de todos los contenedores, domingos a las 03:00
0 3 * * 0  /home/usuario/.local/bin/dbx-backup -y backup --all >> /home/usuario/dbx-backup.log 2>&1
```

## Limitaciones

El restore recrea el contenedor con `distrobox create` usando **nombre, imagen, `--root` y `--home`**. Otras opciones con las que se creara originalmente **no se restauran automáticamente**, por ejemplo:

- Volúmenes adicionales (`--volume`), `--nvidia`, `--init`, `--additional-flags`, hooks…
- Los volúmenes montados no forman parte de la imagen.

Se guarda el `*.inspect.json` de cada contenedor para que puedas consultar la configuración original y volver a aplicarla si la necesitas.

Otras notas:

- Los backups pueden ocupar varios GB, ya que contienen toda la imagen del contenedor.
- El contenedor se pausa durante el `commit`.
- Un backup hecho con podman puede restaurarse con docker y viceversa, pero el formato de imagen puede variar; si algo falla, restaura con el mismo gestor.

## Referencias

- [distrobox: Container save and restore](https://github.com/89luca89/distrobox/blob/main/docs/useful_tips.md#container-save-and-restore)
- [distrobox: `create`](https://github.com/89luca89/distrobox/blob/main/docs/usage/distrobox-create.md)
