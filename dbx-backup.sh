#!/usr/bin/env bash
# =============================================================================
#  dbx-backup.sh — Backup y restore de contenedores distrobox (podman / docker)
#
#  Basado en el procedimiento oficial de distrobox ("Container save and restore"):
#    1. <gestor> container commit -p <contenedor> <imagen>
#    2. <gestor> save <imagen> | <compresor> > backup.tar.xx
#    3. <gestor> load < backup.tar.xx
#    4. distrobox create --image <imagen> --name <contenedor>
#  Además, si el contenedor tiene HOME propio (--home), lo empaqueta aparte y
#  lo restaura antes de recrear el contenedor.
#
#  Uso rápido:
#    ./dbx-backup.sh                 # menú interactivo
#    ./dbx-backup.sh backup --all    # backup de todos los contenedores
#    ./dbx-backup.sh backup arch     # backup de uno (o varios) por nombre
#    ./dbx-backup.sh restore         # menú de restauración
#    ./dbx-backup.sh -h              # ayuda completa
# =============================================================================

set -o pipefail
shopt -s nullglob

VERSION="1.0.0"

# ---------------------------- Configuración ----------------------------------
BACKUP_DIR="${DBX_BACKUP_DIR:-$HOME/distrobox-backups}"
MANAGER="${DBX_CONTAINER_MANAGER:-}"   # podman | docker (vacío = autodetectar)
COMPRESSION="${DBX_BACKUP_COMPRESSION:-}" # zstd | gzip | bzip2 | xz | none
IMAGE_PREFIX="dbx-backup"
ROOTFUL=0       # 1 = contenedores rootful (sudo podman / sudo docker)
KEEP_IMAGE=0    # 1 = no borrar la imagen intermedia tras el backup
ASSUME_YES=0    # 1 = no preguntar (modo no interactivo)
BACKUP_HOME=1   # 1 = copiar también el HOME propio (--home) de cada contenedor
SHARED_HOME=()  # contenedores que usan el HOME del host (no se copia)
HOME_ARCHIVE="" # archivo del HOME generado en el último backup
RESTORED_HOME="" # ruta donde se restauró el HOME

MGR=()          # comando real del gestor (p.ej. "podman" o "sudo docker")
COMP=()         # comando de compresión
DECOMP=()       # comando de descompresión
EXT=""          # extensión del archivo de backup
SELECTED_IDX=() # índices elegidos en los menús

# ------------------------------ Colores --------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_C=$'\e[36m'
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_0=$'\e[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_C=""; C_BOLD=""; C_DIM=""; C_0=""
fi

info() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
ok()   { printf '%s ✔ %s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s [!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()  { printf '%s ✘ %s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()  { err "$*"; exit 1; }

confirm() { # confirm "pregunta" [y|n]
  (( ASSUME_YES )) && return 0
  local def=${2:-n} ans hint="[s/N]"
  [[ $def == y ]] && hint="[S/n]"
  read -r -p "$1 $hint " ans || return 1
  ans=${ans:-$def}
  [[ $ans =~ ^[sSyY] ]]
}

pause() { (( ASSUME_YES )) || read -r -p "${C_DIM}Pulsa Enter para continuar…${C_0}" _ || true; }

human_size() { du -h "$1" 2>/dev/null | cut -f1; }

# ------------------------- Gestor de contenedores ----------------------------
detect_manager() {
  if [[ -z $MANAGER ]]; then
    if command -v podman >/dev/null 2>&1; then MANAGER=podman
    elif command -v docker >/dev/null 2>&1; then MANAGER=docker
    else die "No se ha encontrado ni podman ni docker."
    fi
  fi
  case $MANAGER in
    podman|docker) ;;
    *) die "Gestor no soportado: '$MANAGER' (usa podman o docker)." ;;
  esac
  command -v "$MANAGER" >/dev/null 2>&1 || die "'$MANAGER' no está instalado."

  if (( ROOTFUL )); then
    MGR=(sudo "$MANAGER")
  elif [[ $MANAGER == docker ]] && ! docker info >/dev/null 2>&1; then
    # Docker sin acceso para el usuario → distrobox lo usaría con --root (sudo)
    warn "Tu usuario no tiene acceso directo a docker; se usará 'sudo docker' (modo --root)."
    ROOTFUL=1
    MGR=(sudo docker)
  else
    MGR=("$MANAGER")
  fi
}

manager_label() {
  local mode="rootless"
  (( ROOTFUL )) && mode="rootful"
  printf '%s (%s)' "$MANAGER" "$mode"
}

switch_manager() {
  local other=podman
  [[ $MANAGER == podman ]] && other=docker
  if ! command -v "$other" >/dev/null 2>&1; then
    warn "'$other' no está instalado; se mantiene $MANAGER."
    return
  fi
  MANAGER=$other
  ROOTFUL=0
  detect_manager
  ok "Gestor cambiado a $(manager_label)."
}

toggle_rootful() {
  if (( ROOTFUL )); then ROOTFUL=0; else ROOTFUL=1; fi
  detect_manager
  ok "Modo actual: $(manager_label)."
}

# ------------------------------ Compresión -----------------------------------
setup_compression() {
  if [[ -z $COMPRESSION ]]; then
    if command -v zstd >/dev/null 2>&1; then COMPRESSION=zstd; else COMPRESSION=gzip; fi
  fi
  case $COMPRESSION in
    zstd)  command -v zstd >/dev/null 2>&1 || die "zstd no está instalado."
           COMP=(zstd -T0 -q -c); EXT="tar.zst" ;;
    gzip)  if command -v pigz >/dev/null 2>&1; then COMP=(pigz -c); else COMP=(gzip -c); fi
           EXT="tar.gz" ;;
    bzip2) if command -v pbzip2 >/dev/null 2>&1; then COMP=(pbzip2 -c); else COMP=(bzip2 -c); fi
           EXT="tar.bz2" ;;
    xz)    COMP=(xz -T0 -c); EXT="tar.xz" ;;
    none)  COMP=(cat); EXT="tar" ;;
    *)     die "Compresión no soportada: '$COMPRESSION' (zstd, gzip, bzip2, xz, none)." ;;
  esac
}

set_decompressor() { # según la extensión del archivo
  case $1 in
    *.tar.zst)          DECOMP=(zstd -dc) ;;
    *.tar.gz|*.tgz)     if command -v pigz >/dev/null 2>&1; then DECOMP=(pigz -dc); else DECOMP=(gzip -dc); fi ;;
    *.tar.bz2|*.tar.bz) DECOMP=(bzip2 -dc) ;;
    *.tar.xz)           DECOMP=(xz -dc) ;;
    *.tar)              DECOMP=(cat) ;;
    *) return 1 ;;
  esac
  command -v "${DECOMP[0]}" >/dev/null 2>&1 || { err "Falta '${DECOMP[0]}' para descomprimir $1"; return 1; }
}

progress() { # usa pv si está disponible para mostrar progreso
  if command -v pv >/dev/null 2>&1 && [[ -t 2 ]]; then pv; else cat; fi
}

# ------------------------------ Utilidades -----------------------------------
sanitize() { # nombre válido para una imagen (minúsculas, sin caracteres raros)
  local s
  s=$(tr '[:upper:]' '[:lower:]' <<<"$1")
  s=${s//[^a-z0-9_.-]/-}
  printf '%s' "$s"
}

meta_get() { # meta_get archivo.meta clave
  [[ -f $1 ]] || return 0
  grep -m1 "^$2=" "$1" | cut -d= -f2-
}

container_exists() {
  "${MGR[@]}" container inspect "$1" >/dev/null 2>&1
}

# HOME del contenedor si es propio (creado con --home); vacío si comparte el del host
container_home() {
  local h
  h=$("${MGR[@]}" container inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null \
        | sed -n 's/^HOME=//p' | head -n1)
  [[ $h == "$HOME" || $h == "${HOME%/}" ]] && h=""
  printf '%s' "$h"
}

# Lista de contenedores distrobox: nombre|imagen|estado
list_containers() {
  "${MGR[@]}" ps -a --filter "label=manager=distrobox" \
    --format '{{.Names}}|{{.Image}}|{{.Status}}' 2>/dev/null | sort
}

# Lista de backups (archivos .tar.*) en BACKUP_DIR, más recientes primero
list_backup_files() {
  local f
  for f in "$BACKUP_DIR"/*.tar.zst "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.tgz \
           "$BACKUP_DIR"/*.tar.bz2 "$BACKUP_DIR"/*.tar.bz "$BACKUP_DIR"/*.tar.xz \
           "$BACKUP_DIR"/*.tar; do
    [[ $f == *.home.tar* ]] && continue   # los HOME van ligados a su backup principal
    printf '%s\t%s\n' "$(stat -c %Y "$f" 2>/dev/null || echo 0)" "$f"
  done | sort -rn | cut -f2-
}

# ------------------------- Menú de selección ---------------------------------
# select_items "Título" elem1 elem2 …  → rellena SELECTED_IDX (índices 0-based)
select_items() {
  local title=$1; shift
  local -a items=("$@")
  local n=${#items[@]} i input tok a b valid
  SELECTED_IDX=()

  echo
  printf '%s%s%s\n' "$C_BOLD" "$title" "$C_0"
  for i in "${!items[@]}"; do
    printf '  %s%2d)%s %s\n' "$C_G" $((i + 1)) "$C_0" "${items[i]}"
  done
  printf '  %s a)%s Todos\n' "$C_G" "$C_0"
  printf '  %s q)%s Volver\n' "$C_G" "$C_0"

  while true; do
    read -r -p "Selección (ej: 2  |  1 3 5  |  2-4  |  a): " input || return 1
    case $input in
      q|Q|"") return 1 ;;
      a|A|todos|all)
        for ((i = 0; i < n; i++)); do SELECTED_IDX+=("$i"); done
        return 0 ;;
    esac
    SELECTED_IDX=(); valid=1
    for tok in ${input//,/ }; do
      if [[ $tok =~ ^([0-9]+)-([0-9]+)$ ]]; then
        a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
        if (( a >= 1 && b <= n && a <= b )); then
          for ((i = a; i <= b; i++)); do SELECTED_IDX+=($((i - 1))); done
        else valid=0; fi
      elif [[ $tok =~ ^[0-9]+$ ]] && (( 10#$tok >= 1 && 10#$tok <= n )); then
        SELECTED_IDX+=($((10#$tok - 1)))
      else
        valid=0
      fi
    done
    if (( valid && ${#SELECTED_IDX[@]} )); then
      mapfile -t SELECTED_IDX < <(printf '%s\n' "${SELECTED_IDX[@]}" | sort -nu)
      return 0
    fi
    warn "Selección no válida, prueba otra vez."
  done
}

# -------------------------------- BACKUP -------------------------------------
# Empaqueta el HOME propio de un contenedor → rellena HOME_ARCHIVE
backup_home() {
  local name=$1 home=$2 base=$3 harch errf
  local -a ps
  HOME_ARCHIVE=""
  if [[ ! -d $home ]]; then
    warn "[$name] Su HOME '$home' no existe en el host; no se copia."
    return 0
  fi
  harch="${base}.home.${EXT}"
  errf="${harch}.err"
  info "[$name] Copiando HOME propio ($home, $(du -sh "$home" 2>/dev/null | cut -f1))…"
  tar -C "$home" -cf - . 2>"$errf" | progress | "${COMP[@]}" > "${harch}.part"
  ps=("${PIPESTATUS[@]}")
  if (( ps[2] != 0 )); then
    err "[$name] Error al comprimir el HOME."
    rm -f "${harch}.part" "$errf"
    return 1
  fi
  if (( ps[0] == 1 )); then
    warn "[$name] Algunos archivos del HOME cambiaron durante la copia (normal si el contenedor está en uso)."
  elif (( ps[0] != 0 )); then
    warn "[$name] tar no pudo leer algunos archivos del HOME; el resto se ha copiado:"
    head -n 5 "$errf" | sed 's/^/      /' >&2
  fi
  rm -f "$errf"
  mv -f "${harch}.part" "$harch"
  HOME_ARCHIVE=$(basename "$harch")
  ok "[$name] HOME copiado: $harch ($(human_size "$harch"))"
}

backup_one() {
  local name=$1 ts safe tag base archive orig_image home sha home_sha="" size

  container_exists "$name" || { err "[$name] El contenedor no existe."; return 1; }

  ts=$(date +%Y%m%d-%H%M%S)
  safe=$(sanitize "$name")
  tag="${IMAGE_PREFIX}/${safe}:${ts}"
  base="${BACKUP_DIR}/${name}_${ts}"
  archive="${base}.${EXT}"

  orig_image=$("${MGR[@]}" container inspect --format '{{.Config.Image}}' "$name" 2>/dev/null)
  home=$(container_home "$name")
  [[ -z $home ]] && SHARED_HOME+=("$name")

  info "[$name] Creando snapshot (commit)…"
  if ! "${MGR[@]}" container commit -p "$name" "$tag" >/dev/null 2>&1; then
    warn "[$name] El commit pausando el contenedor ha fallado; reintentando sin pausar…"
    if ! "${MGR[@]}" container commit "$name" "$tag" >/dev/null; then
      err "[$name] No se ha podido crear la imagen."
      return 1
    fi
  fi

  info "[$name] Exportando y comprimiendo ($COMPRESSION)…"
  if ! "${MGR[@]}" save "$tag" | progress | "${COMP[@]}" > "${archive}.part"; then
    err "[$name] Error al exportar la imagen."
    rm -f "${archive}.part"
    (( KEEP_IMAGE )) || "${MGR[@]}" rmi "$tag" >/dev/null 2>&1
    return 1
  fi
  mv -f "${archive}.part" "$archive"

  # HOME propio (--home): se copia aparte, ligado a este backup
  HOME_ARCHIVE=""
  local home_failed=0
  if [[ -n $home ]]; then
    if (( BACKUP_HOME )); then
      backup_home "$name" "$home" "$base" || home_failed=1
      if [[ -n $HOME_ARCHIVE ]] && command -v sha256sum >/dev/null 2>&1; then
        home_sha=$(sha256sum "${BACKUP_DIR}/${HOME_ARCHIVE}" | cut -d' ' -f1)
      fi
    else
      warn "[$name] Tiene HOME propio ($home) pero se ha desactivado su copia (-H)."
    fi
  fi

  # Metadatos para poder restaurar con el mismo nombre/configuración
  "${MGR[@]}" container inspect "$name" > "${base}.inspect.json" 2>/dev/null || rm -f "${base}.inspect.json"
  sha=""
  command -v sha256sum >/dev/null 2>&1 && sha=$(sha256sum "$archive" | cut -d' ' -f1)
  cat > "${base}.meta" <<EOF
# dbx-backup v${VERSION}
name=${name}
image_tag=${tag}
original_image=${orig_image}
manager=${MANAGER}
rootful=${ROOTFUL}
custom_home=${home}
archive=$(basename "$archive")
sha256=${sha}
home_archive=${HOME_ARCHIVE}
home_sha256=${home_sha}
date=$(date -Iseconds)
host=${HOSTNAME:-$(uname -n)}
EOF

  if (( ! KEEP_IMAGE )); then
    "${MGR[@]}" rmi "$tag" >/dev/null 2>&1 || warn "[$name] No se pudo borrar la imagen intermedia $tag."
  fi

  size=$(human_size "$archive")
  ok "[$name] Backup listo: $archive ($size)"
  (( home_failed == 0 ))
}

run_backups() { # run_backups nombre1 nombre2 …
  local name total=$# okc=0
  local -a failed=()
  mkdir -p "$BACKUP_DIR" || die "No se puede crear $BACKUP_DIR"
  setup_compression
  SHARED_HOME=()
  echo
  info "Destino: $BACKUP_DIR  ·  Gestor: $(manager_label)  ·  Compresión: $COMPRESSION"
  for name in "$@"; do
    if backup_one "$name"; then okc=$((okc + 1)); else failed+=("$name"); fi
  done
  echo
  ok "Backups completados: $okc/$total"
  (( ${#failed[@]} )) && warn "Fallaron: ${failed[*]}"
  if (( ${#SHARED_HOME[@]} )); then
    echo "${C_DIM}Nota: ${SHARED_HOME[*]} comparte(n) tu HOME del host; ese HOME no se incluye (haz su copia aparte).${C_0}"
  fi
  (( ${#failed[@]} == 0 ))
}

menu_backup() {
  local -a lines names labels
  local l n img st i
  mapfile -t lines < <(list_containers)
  if (( ${#lines[@]} == 0 )); then
    warn "No hay contenedores distrobox con $(manager_label)."
    pause; return
  fi
  local h hinfo
  for l in "${lines[@]}"; do
    IFS='|' read -r n img st <<<"$l"
    names+=("$n")
    h=$(container_home "$n")
    if [[ -n $h ]]; then hinfo="  ${C_C}[home: $h]${C_0}"; else hinfo=""; fi
    labels+=("$(printf '%-22s %s%-40s %s%s%s' "$n" "$C_DIM" "$img" "$st" "$C_0" "$hinfo")")
  done
  select_items "Contenedores distrobox ($(manager_label)) — ¿de cuáles quieres backup?" "${labels[@]}" || return
  local -a chosen=()
  for i in "${SELECTED_IDX[@]}"; do chosen+=("${names[i]}"); done
  echo
  echo "Se hará backup de: ${C_BOLD}${chosen[*]}${C_0}"
  echo "${C_DIM}Los contenedores en marcha se pausan unos segundos durante el commit.${C_0}"
  confirm "¿Continuar?" y || return
  run_backups "${chosen[@]}"
  pause
}

# -------------------------------- RESTORE ------------------------------------
# Restaura el HOME empaquetado → rellena RESTORED_HOME con la ruta usada
restore_home() {
  local harch=$1 target=$2 hsha=$3 ans
  RESTORED_HOME=""
  if [[ -n $hsha ]] && command -v sha256sum >/dev/null 2>&1; then
    if ! printf '%s  %s\n' "$hsha" "$harch" | sha256sum -c --quiet - >/dev/null 2>&1; then
      err "El checksum del HOME no coincide: el archivo puede estar corrupto."
      confirm "¿Restaurar el HOME de todas formas?" n || return 1
    fi
  fi
  if (( ! ASSUME_YES )); then
    read -r -p "Ruta donde restaurar el HOME del contenedor [$target]: " ans || true
    [[ -n $ans ]] && target=${ans/#\~/$HOME}
  fi
  if [[ -d $target && -n $(ls -A "$target" 2>/dev/null) ]]; then
    if (( ASSUME_YES )); then
      warn "El HOME '$target' ya existe y no está vacío; se deja como está (no se sobrescribe)."
      RESTORED_HOME=$target
      return 0
    fi
    warn "El directorio '$target' ya existe y no está vacío."
    read -r -p "  [s] Sobrescribir (fusionar)  [m] Mantener el actual  [c] Cancelar: " ans || return 1
    case $ans in
      s|S) ;;
      m|M) RESTORED_HOME=$target; return 0 ;;
      *) return 1 ;;
    esac
  fi
  set_decompressor "$harch" || return 1
  mkdir -p "$target" || { err "No se puede crear $target"; return 1; }
  info "Restaurando HOME en $target…"
  if ! "${DECOMP[@]}" "$harch" | progress | tar -xpf - -C "$target"; then
    err "Error al extraer el HOME en $target"
    return 1
  fi
  RESTORED_HOME=$target
  ok "HOME restaurado en $target"
}

restore_one() {
  local archive=$1 base meta name sha home bk_root bk_mgr out loaded newname ans
  [[ -f $archive ]] || { err "No existe: $archive"; return 1; }
  command -v distrobox >/dev/null 2>&1 || die "distrobox no está instalado."

  base=${archive%.tar*}
  base=${base%.tgz}
  meta="${base}.meta"
  name=$(meta_get "$meta" name)
  [[ -z $name ]] && name=$(basename "$base")
  sha=$(meta_get "$meta" sha256)
  home=$(meta_get "$meta" custom_home)
  bk_root=$(meta_get "$meta" rootful)
  bk_mgr=$(meta_get "$meta" manager)

  echo
  info "Restaurando ${C_BOLD}$name${C_0} desde $(basename "$archive")"
  [[ -n $bk_mgr && $bk_mgr != "$MANAGER" ]] && \
    warn "El backup se hizo con $bk_mgr y vas a restaurarlo con $MANAGER (debería funcionar)."
  [[ $bk_root == 1 && $ROOTFUL == 0 ]] && \
    warn "El contenedor original era rootful; si quieres mantenerlo así usa la opción -r."

  if [[ -n $sha ]] && command -v sha256sum >/dev/null 2>&1; then
    info "Verificando integridad (sha256)…"
    if ! printf '%s  %s\n' "$sha" "$archive" | sha256sum -c --quiet - >/dev/null 2>&1; then
      err "El checksum no coincide: el archivo puede estar corrupto."
      confirm "¿Restaurar de todas formas?" n || return 1
    fi
  fi

  # Nombre del contenedor destino
  newname=$name
  if (( ! ASSUME_YES )); then
    read -r -p "Nombre del contenedor a crear [$name]: " ans || true
    [[ -n $ans ]] && newname=$ans
  fi
  while container_exists "$newname"; do
    if (( ASSUME_YES )); then
      newname="${newname}-restored"
      warn "Ya existe un contenedor con ese nombre; se usará '$newname'."
      continue
    fi
    warn "Ya existe un contenedor llamado '$newname'."
    read -r -p "  [r] Reemplazarlo  [n] Usar otro nombre  [c] Cancelar: " ans || return 1
    case $ans in
      r|R)
        confirm "Se BORRARÁ el contenedor '$newname' actual. ¿Seguro?" n || continue
        DBX_CONTAINER_MANAGER=$MANAGER distrobox rm -f "${root_flag[@]}" "$newname" \
          || { err "No se pudo borrar '$newname'."; return 1; } ;;
      n|N) read -r -p "  Nuevo nombre: " newname || return 1 ;;
      *) return 1 ;;
    esac
  done

  set_decompressor "$archive" || return 1
  info "Cargando imagen en $(manager_label)…"
  if ! out=$("${DECOMP[@]}" "$archive" | progress | "${MGR[@]}" load 2>&1); then
    err "Error al cargar la imagen:"; printf '%s\n' "$out" >&2
    return 1
  fi
  loaded=$(sed -n 's/^Loaded image[^:]*: *//p' <<<"$out" | tail -n1)
  [[ -z $loaded ]] && loaded=$(meta_get "$meta" image_tag)
  [[ -z $loaded ]] && { err "No se pudo determinar el nombre de la imagen cargada."; return 1; }
  ok "Imagen cargada: $loaded"

  local -a args=(create --yes --name "$newname" --image "$loaded")
  (( ROOTFUL )) && args+=(--root)
  if [[ -n $home ]]; then
    local harch hname
    hname=$(meta_get "$meta" home_archive)
    harch="$(dirname "$archive")/$hname"
    if [[ -n $hname && -f $harch ]]; then
      restore_home "$harch" "$home" "$(meta_get "$meta" home_sha256)" || return 1
      args+=(--home "$RESTORED_HOME")
    else
      [[ -n $hname ]] && warn "No se encuentra el archivo del HOME ($hname); se creará vacío."
      if [[ -d $home ]]; then
        args+=(--home "$home")
      elif confirm "El contenedor usaba HOME propio '$home', que no existe aquí. ¿Crearlo vacío?" y; then
        mkdir -p "$home" && args+=(--home "$home")
      fi
    fi
  fi

  info "Creando contenedor con distrobox…"
  if ! DBX_CONTAINER_MANAGER=$MANAGER distrobox "${args[@]}"; then
    err "distrobox create ha fallado."
    return 1
  fi
  ok "Contenedor '$newname' restaurado. Entra con: distrobox enter $newname"
}

run_restores() {
  local f okc=0 total=$#
  local -a failed=()
  local -a root_flag=()
  (( ROOTFUL )) && root_flag=(--root)
  for f in "$@"; do
    if restore_one "$f"; then okc=$((okc + 1)); else failed+=("$(basename "$f")"); fi
  done
  echo
  ok "Restauraciones completadas: $okc/$total"
  (( ${#failed[@]} )) && warn "Fallaron: ${failed[*]}"
  (( ${#failed[@]} == 0 ))
}

backup_label() {
  local f=$1 base meta name date mgr
  base=${f%.tar*}; meta="${base}.meta"
  name=$(meta_get "$meta" name); [[ -z $name ]] && name=$(basename "$base")
  date=$(meta_get "$meta" date); date=${date%%+*}; date=${date/T/ }
  [[ -z $date ]] && date=$(date -r "$f" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
  mgr=$(meta_get "$meta" manager); [[ -z $mgr ]] && mgr="?"
  local hname hinfo=""
  hname=$(meta_get "$meta" home_archive)
  [[ -n $hname && -f "$(dirname "$f")/$hname" ]] && \
    hinfo="  ${C_C}+home ($(human_size "$(dirname "$f")/$hname"))${C_0}"
  printf '%-22s %s%-20s %-7s %6s  %s%s%s' "$name" "$C_DIM" "$date" "$mgr" "$(human_size "$f")" "$(basename "$f")" "$C_0" "$hinfo"
}

menu_restore() {
  local -a files labels chosen=()
  local f i
  mapfile -t files < <(list_backup_files)
  if (( ${#files[@]} == 0 )); then
    warn "No hay backups en $BACKUP_DIR"
    pause; return
  fi
  for f in "${files[@]}"; do labels+=("$(backup_label "$f")"); done
  select_items "Backups en $BACKUP_DIR — ¿cuáles quieres restaurar?" "${labels[@]}" || return
  for i in "${SELECTED_IDX[@]}"; do chosen+=("${files[i]}"); done
  run_restores "${chosen[@]}"
  pause
}

# ------------------------------ Listados -------------------------------------
show_containers() {
  local -a lines; local l n img st
  mapfile -t lines < <(list_containers)
  echo
  printf '%sContenedores distrobox — %s%s\n' "$C_BOLD" "$(manager_label)" "$C_0"
  if (( ${#lines[@]} == 0 )); then echo "  (ninguno)"; return; fi
  printf '  %s%-22s %-40s %s%s\n' "$C_DIM" "NOMBRE" "IMAGEN" "ESTADO" "$C_0"
  for l in "${lines[@]}"; do
    IFS='|' read -r n img st <<<"$l"
    printf '  %-22s %-40s %s\n' "$n" "$img" "$st"
  done
}

show_backups() {
  local -a files; local f
  mapfile -t files < <(list_backup_files)
  echo
  printf '%sBackups en %s%s\n' "$C_BOLD" "$BACKUP_DIR" "$C_0"
  if (( ${#files[@]} == 0 )); then echo "  (ninguno)"; return; fi
  for f in "${files[@]}"; do printf '  %s\n' "$(backup_label "$f")"; done
}

# ----------------------------- Menú principal --------------------------------
main_menu() {
  local opt d
  while true; do
    echo
    printf '%s╭──────────────────────────────────────────────╮%s\n' "$C_C" "$C_0"
    printf '%s│%s   %sDistrobox Backup / Restore%s  v%-14s%s│%s\n' "$C_C" "$C_0" "$C_BOLD" "$C_0" "$VERSION" "$C_C" "$C_0"
    printf '%s│%s   %s%-43s%s%s│%s\n' "$C_C" "$C_0" "$C_DIM" "By Omar Santos" "$C_0" "$C_C" "$C_0"
    printf '%s╰──────────────────────────────────────────────╯%s\n' "$C_C" "$C_0"
    printf '  Gestor:  %s\n  Destino: %s\n\n' "$(manager_label)" "$BACKUP_DIR"
    echo "  1) Hacer backup"
    echo "  2) Restaurar backup"
    echo "  3) Ver contenedores"
    echo "  4) Ver backups"
    echo "  5) Cambiar gestor (podman ↔ docker)"
    echo "  6) Alternar rootless / rootful"
    echo "  7) Cambiar carpeta de backups"
    echo "  q) Salir"
    read -r -p "Opción: " opt || exit 0
    case $opt in
      1) menu_backup ;;
      2) menu_restore ;;
      3) show_containers; pause ;;
      4) show_backups; pause ;;
      5) switch_manager ;;
      6) toggle_rootful ;;
      7) read -r -p "Nueva carpeta [$BACKUP_DIR]: " d || true
         [[ -n $d ]] && BACKUP_DIR=${d/#\~/$HOME} ;;
      q|Q) exit 0 ;;
      *) warn "Opción no válida." ;;
    esac
  done
}

# ---------------------------------- Ayuda ------------------------------------
usage() {
  cat <<EOF
${C_BOLD}dbx-backup.sh${C_0} v${VERSION} — Backup y restore de contenedores distrobox

${C_BOLD}Uso:${C_0}
  dbx-backup.sh [opciones] [comando] [argumentos]

${C_BOLD}Comandos:${C_0}
  menu                       Menú interactivo (por defecto)
  backup --all               Backup de todos los contenedores distrobox
  backup NOMBRE [NOMBRE…]    Backup de los contenedores indicados
  backup                     Menú de selección para backup
  restore ARCHIVO [ARCHIVO…] Restaura los backups indicados (.tar.zst/.gz/.bz2/.xz/.tar)
  restore --all              Restaura todos los backups de la carpeta
  restore                    Menú de selección para restaurar
  list                       Lista los contenedores distrobox
  backups                    Lista los backups disponibles

${C_BOLD}Opciones:${C_0}
  -m, --manager podman|docker  Gestor a usar (por defecto: autodetecta, prioriza podman)
  -r, --root                   Contenedores rootful (sudo podman / sudo docker)
  -d, --dir DIR                Carpeta de backups (por defecto: ~/distrobox-backups)
  -c, --compress ALG           zstd | gzip | bzip2 | xz | none (por defecto: zstd si existe, si no gzip)
  -k, --keep-image             No borrar la imagen intermedia creada por el commit
  -H, --no-home                No copiar el HOME propio (--home) de los contenedores
  -y, --yes                    No preguntar nada (útil para cron/systemd)
  -h, --help                   Esta ayuda

${C_BOLD}Variables de entorno:${C_0}
  DBX_BACKUP_DIR, DBX_CONTAINER_MANAGER, DBX_BACKUP_COMPRESSION

${C_BOLD}Ejemplos:${C_0}
  dbx-backup.sh                              # menú
  dbx-backup.sh -y backup --all              # backup de todo sin preguntar
  dbx-backup.sh -m docker backup ubuntu      # solo 'ubuntu' usando docker
  dbx-backup.sh restore ~/distrobox-backups/arch_20261011-120000.tar.zst

${C_BOLD}HOME de los contenedores:${C_0}
  · Contenedores creados con --home (HOME propio): ese directorio se empaqueta en
    NOMBRE_FECHA.home.tar.* junto a la imagen y se restaura en su ruta (o la que elijas).
  · Contenedores que comparten tu HOME del host: ese HOME no se copia (haz su copia aparte).
EOF
}

# ---------------------------------- Main -------------------------------------
main() {
  local cmd="" all=0
  local -a pos=()
  while (( $# )); do
    case $1 in
      -m|--manager)  MANAGER=${2:?Falta el gestor}; shift ;;
      -r|--root)     ROOTFUL=1 ;;
      -d|--dir)      BACKUP_DIR=${2:?Falta la carpeta}; shift ;;
      -c|--compress) COMPRESSION=${2:?Falta el algoritmo}; shift ;;
      -k|--keep-image) KEEP_IMAGE=1 ;;
      -H|--no-home)  BACKUP_HOME=0 ;;
      -y|--yes)      ASSUME_YES=1 ;;
      -a|--all)      all=1 ;;
      -h|--help)     usage; exit 0 ;;
      -v|--version)  echo "$VERSION"; exit 0 ;;
      -*)            die "Opción desconocida: $1 (usa -h)" ;;
      *)             if [[ -z $cmd ]]; then cmd=$1; else pos+=("$1"); fi ;;
    esac
    shift
  done

  detect_manager

  case ${cmd:-menu} in
    menu)
      main_menu ;;
    backup)
      if (( all )); then
        local -a names
        mapfile -t names < <(list_containers | cut -d'|' -f1)
        (( ${#names[@]} )) || die "No hay contenedores distrobox con $(manager_label)."
        run_backups "${names[@]}"
      elif (( ${#pos[@]} )); then
        run_backups "${pos[@]}"
      else
        menu_backup
      fi ;;
    restore)
      if (( all )); then
        local -a files
        mapfile -t files < <(list_backup_files)
        (( ${#files[@]} )) || die "No hay backups en $BACKUP_DIR"
        run_restores "${files[@]}"
      elif (( ${#pos[@]} )); then
        run_restores "${pos[@]}"
      else
        menu_restore
      fi ;;
    list)    show_containers ;;
    backups) show_backups ;;
    *)       die "Comando desconocido: $cmd (usa -h)" ;;
  esac
}

main "$@"
