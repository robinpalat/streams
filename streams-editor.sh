#!/usr/bin/env bash
# streams-editor — elige streams de una lista grande (all.m3u) y arma tu playlist (streams.m3u)
# Uso:  streams-editor.sh [all.m3u] [streams.m3u]
# Por defecto: ~/streams/all.m3u y ~/streams/streams.m3u (o variables ALL_FILE / FAV_FILE).
# Dependencias: yad, git (opcional). Opcionales: vlc (o $PLAYER), xclip / wl-paste.
# Si los archivos están dentro de un repositorio git, al guardar hace commit y push
# automáticamente (así se publica en GitHub). Necesita git con credenciales ya configuradas.
# Al guardar, prueba cada stream de streams.m3u (necesita curl) y elimina de esa lista, sin
# preguntar, los que no responden. all.m3u no se toca. Ajustes (variables de entorno):
#   CHECK_ONLINE=0 desactiva la prueba · CHECK_TIMEOUT=10 segundos por intento
#   CHECK_JOBS=16 pruebas en paralelo · CHECK_HOST=https://github.com (para detectar si hay red)
# Lista grande "en vivo": el script solo guarda la URL (ALL_URL) y la descarga cada vez que abres
# el editor, o con el botón "Actualizar lista". La copia local es una caché; en ese modo la lista
# grande es de solo lectura y solo se guarda y publica streams.m3u.
#   ALL_URL=""  usa el archivo local all.m3u sin descargar (modo anterior)
#   ALL_REFRESH=0  no descarga al abrir (para trabajar sin conexión)

ALL_URL="${ALL_URL-https://iptv-org.github.io/iptv/languages/spa.m3u}"
ALL_REFRESH="${ALL_REFRESH:-1}"
LIVE=0; [[ -n $ALL_URL ]] && LIVE=1
if ((LIVE)); then ALL_DEFAULT="${XDG_CACHE_HOME:-$HOME/.cache}/streams-editor/all.m3u"
else ALL_DEFAULT="$HOME/streams/all.m3u"; fi
ALL_FILE="${1:-${ALL_FILE:-$ALL_DEFAULT}}"
FAV_FILE="${2:-${FAV_FILE:-$HOME/streams/streams.m3u}}"
PLAYER="${PLAYER:-vlc}"
TITLE="Editor de streams"
CHECK_ONLINE="${CHECK_ONLINE:-1}"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-10}"
CHECK_JOBS="${CHECK_JOBS:-16}"
CHECK_HOST="${CHECK_HOST:-https://github.com}"

# Línea #EXTINF: grupo 1 = cabecera hasta la coma que separa el nombre, grupo 3 = nombre.
# Respeta comas dentro de atributos entre comillas (tvg-logo="...", group-title="...").
EXTINF_RE='^(#EXTINF:([^,"]|"[^"]*")*,)(.*)$'

VIEW=all                          # lista que se está viendo: all | fav
names=(); urls=(); blocks=(); marks=()      # lista activa (blocks = líneas # previas a la URL)
A_names=(); A_urls=(); A_blocks=(); A_head=""   # all.m3u
F_names=(); F_urls=(); F_blocks=(); F_head=""   # streams.m3u
vis=()          # índices que se muestran ahora
filter=""       # texto del buscador; vacío = mostrar todo
fwords=()       # palabras del filtro (en minúsculas)
status=""       # mensaje de una sola vez para la cabecera
report=""       # resultado de la prueba online (se muestra al terminar de guardar)

trim() {  # sin subshell: resultado en $REPLY
  REPLY=$1
  REPLY=${REPLY#"${REPLY%%[![:space:]]*}"}
  REPLY=${REPLY%"${REPLY##*[![:space:]]}"}
}

esc() {  # escapa para el markup del --text de yad
  local s=$1
  s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}
  printf '%s' "$s"
}

# ---------- archivos M3U ----------
parse_extinf() {  # $1 = línea #EXTINF  ->  EI_HEAD, EI_NAME
  if [[ $1 =~ $EXTINF_RE ]]; then
    EI_HEAD=${BASH_REMATCH[1]}; EI_NAME=${BASH_REMATCH[3]}
  elif [[ $1 == *,* ]]; then
    EI_HEAD="${1%,*},"; EI_NAME=${1##*,}
  else
    EI_HEAD="$1,"; EI_NAME=""
  fi
}

# Lee $1 y deja el resultado en LF_names, LF_urls, LF_blocks, LF_head.
# Conserva todo lo que hay antes de cada URL (tvg-logo, group-title, #EXTVLCOPT...).
load_file() {
  LF_names=(); LF_urls=(); LF_blocks=(); LF_head=""
  [[ -f $1 ]] || return 0
  local line blk="" name="" u
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    case $line in
      "#EXTM3U"*) LF_head=$line ;;
      "#EXTINF:"*) parse_extinf "$line"; name=$EI_NAME; blk+=${blk:+$'\n'}$line ;;
      "#"*)        blk+=${blk:+$'\n'}$line ;;
      "")          ;;
      *) trim "$line"; u=$REPLY
         trim "${name:-$u}"
         LF_names+=("$REPLY"); LF_urls+=("$u"); LF_blocks+=("$blk")
         blk=""; name="" ;;
    esac
  done < "$1"
}

# Cambia el nombre dentro del bloque de una entrada. $1 = bloque, $2 = nombre  ->  $REPLY
rename_block() {
  local blk=$1 name=$2 line out="" done_=0
  if [[ -z $blk ]]; then REPLY=""; return; fi
  while IFS= read -r line; do
    if ((!done_)) && [[ $line == "#EXTINF:"* ]]; then
      parse_extinf "$line"; line="${EI_HEAD}${name}"; done_=1
    fi
    out+=${out:+$'\n'}$line
  done <<< "$blk"
  REPLY=$out
}

# Descarga ALL_URL a ALL_FILE (la caché). Solo reemplaza la copia si lo descargado es una lista M3U válida.
refresh_all() {
  local tmp n
  command -v curl >/dev/null || { status="No se pudo actualizar la lista: falta curl."; return 1; }
  mkdir -p "$(dirname "$ALL_FILE")" || return 1
  tmp=$(mktemp) || return 1
  if curl -fsSL -m 30 --connect-timeout 10 -o "$tmp" "$ALL_URL" 2>/dev/null \
     && head -c 64 "$tmp" | grep -q '^#EXTM3U' && grep -q '^#EXTINF' "$tmp"; then
    chmod 644 "$tmp" && mv -f "$tmp" "$ALL_FILE"
    n=$(grep -c '^#EXTINF' "$ALL_FILE")
    status="Lista actualizada desde la URL: $n canales."
    return 0
  fi
  rm -f "$tmp"
  if [[ -f $ALL_FILE ]]; then
    status="No se pudo descargar la lista (¿sin conexión?). Se usa la copia local del $(date -r "$ALL_FILE" '+%F %H:%M')."
  else
    status="No se pudo descargar la lista y no hay copia local."
  fi
  return 1
}

load_all() {
  load_file "$ALL_FILE"
  A_names=("${LF_names[@]}"); A_urls=("${LF_urls[@]}"); A_blocks=("${LF_blocks[@]}"); A_head=$LF_head
}

# Botón "Actualizar lista": descarga de nuevo y recarga la lista grande.
reload_all() {
  refresh_all
  load_all
  [[ $VIEW == all ]] && unstash
  filter=""
}

# write_m3u ARCHIVO CABECERA ARRAY_NOMBRES ARRAY_URLS ARRAY_BLOQUES [plain]
# Modo normal: conserva cada entrada tal cual (atributos, tvg-logo...).
# Modo "plain": escribe "#EXTINF:-1, Nombre" sin atributos (sin tvg-logo); solo se
#   conservan líneas auxiliares como #EXTVLCOPT, necesarias para reproducir.
# Si el contenido no cambió, no toca el archivo (no genera commits vacíos).
write_m3u() {
  local file=$1 head=$2 mode=${6:-} tmp i l
  local -n _wn=$3 _wu=$4 _wb=$5
  mkdir -p "$(dirname "$file")" || return 1
  tmp=$(mktemp) || return 1
  {
    if [[ $mode == plain ]]; then printf '#EXTM3U\n'; else printf '%s\n' "${head:-#EXTM3U}"; fi
    for i in "${!_wu[@]}"; do
      if [[ $mode == plain ]]; then
        printf '#EXTINF:-1, %s\n' "${_wn[i]}"
        while IFS= read -r l; do
          [[ -n $l && $l != "#EXTINF:"* ]] && printf '%s\n' "$l"
        done <<< "${_wb[i]}"
      elif [[ ${_wb[i]} == *"#EXTINF:"* ]]; then
        printf '%s\n' "${_wb[i]}"
      else
        [[ -n ${_wb[i]} ]] && printf '%s\n' "${_wb[i]}"
        printf '#EXTINF:-1,%s\n' "${_wn[i]}"
      fi
      printf '%s\n' "${_wu[i]}"
    done
  } > "$tmp"
  if [[ -f $file ]] && cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 0; fi
  chmod 644 "$tmp" && mv -f "$tmp" "$file"
}

save_all() {  # guarda las dos listas
  stash
  if ((!LIVE)); then write_m3u "$ALL_FILE" "$A_head" A_names A_urls A_blocks || return 1; fi
  write_m3u "$FAV_FILE" "" F_names F_urls F_blocks plain   # mi playlist: formato simple, sin tvg-logo
}

# commit (si hay cambios) + push de cada archivo que esté en un repo git.
publish() {
  local f dir files=("$ALL_FILE" "$FAV_FILE")
  ((LIVE)) && files=("$FAV_FILE")
  for f in "${files[@]}"; do
    dir=$(dirname "$f")
    git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || continue
    git -C "$dir" add -- "$f" || return 1
    if ! git -C "$dir" diff --cached --quiet -- "$f"; then
      git -C "$dir" commit -q -m "Actualizar $(basename "$f") ($(date '+%F %T'))" -- "$f" || return 1
    fi
    git -C "$dir" push -q || return 1
  done
}

# ---------- prueba online ----------
# probe_stream URL BLOQUE ARCHIVO_TEMP  ->  0 si el stream responde, 1 si no.
# Respeta #EXTVLCOPT http-user-agent / http-referrer. Dos intentos antes de darlo por caído.
# Un timeout con datos ya recibidos (un directo que sigue fluyendo) cuenta como "online".
probe_stream() {
  local url=$1 blk=$2 tmpf=$3 ua="VLC/3.0.20 LibVLC/3.0.20" ref="" l code attempt
  while IFS= read -r l; do
    case $l in
      "#EXTVLCOPT:http-user-agent="*) ua=${l#*=} ;;
      "#EXTVLCOPT:http-referrer="*|"#EXTVLCOPT:http-referer="*) ref=${l#*=} ;;
    esac
  done <<< "$blk"
  local args=(-sL -m "$CHECK_TIMEOUT" --connect-timeout 6 -A "$ua" -r 0-2047 -o "$tmpf" -w '%{http_code}')
  [[ -n $ref ]] && args+=(-e "$ref")
  for attempt in 1 2; do
    code=$(curl "${args[@]}" "$url" 2>/dev/null)
    if [[ $code == 200 || $code == 206 ]]; then
      # una página HTML con código 200 suele ser un mensaje de error, no un stream
      head -c 512 "$tmpf" 2>/dev/null | grep -aqiE '<!doctype|<html' || return 0
    fi
    ((attempt==1)) && sleep 2
  done
  return 1
}

# Quita de mi playlist (F_*) los streams que no responden. No pregunta nada.
# Sin red, cancelada, o si fallan TODOS, no elimina nada (para no vaciar la lista por un problema de red).
prune_offline() {
  report=""
  [[ $CHECK_ONLINE == 1 ]] || return 0
  stash
  local total=${#F_urls[@]} tmpd i n pid
  ((total)) || return 0
  command -v curl >/dev/null || { report="No se comprobaron los streams: falta curl."; return 0; }
  if ! curl -sI -m 8 "$CHECK_HOST" >/dev/null 2>&1; then
    report="Sin conexión a internet: se omitió la comprobación y no se eliminó ningún stream."
    return 0
  fi

  tmpd=$(mktemp -d) || return 0
  (
    for i in "${!F_urls[@]}"; do
      while (($(jobs -rp | wc -l) >= CHECK_JOBS)); do wait -n; done
      (
        if probe_stream "${F_urls[i]}" "${F_blocks[i]}" "$tmpd/$i.body"; then echo OK; else echo FAIL; fi > "$tmpd/$i.tmp"
        rm -f "$tmpd/$i.body"; mv -f "$tmpd/$i.tmp" "$tmpd/$i.res"
      ) &
    done
    wait
  ) &
  pid=$!

  {
    while :; do
      n=$(find "$tmpd" -maxdepth 1 -name '*.res' | wc -l)
      echo $((n*100/total)); echo "# Comprobando streams: $n de $total"
      ((n>=total)) && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.3
    done
  } | yad --progress --auto-close --no-buttons --center --width=440 \
          --title="Comprobando streams" --text="Comprobando streams…"

  n=$(find "$tmpd" -maxdepth 1 -name '*.res' | wc -l)
  if ((n < total)); then   # ventana cerrada antes de terminar
    kill "$pid" 2>/dev/null
    rm -rf "$tmpd"
    report="Comprobación interrumpida: no se eliminó ningún stream."
    return 0
  fi

  local -A isdead=(); local ndead=0
  for i in "${!F_urls[@]}"; do
    if [[ $(<"$tmpd/$i.res") == FAIL ]]; then isdead[$i]=1; ndead=$((ndead+1)); fi
  done
  rm -rf "$tmpd"

  ((ndead)) || return 0
  if ((ndead == total)); then
    report="Ningún stream respondió (¿problema de red?): no se eliminó ninguno."
    return 0
  fi

  local nn=() nu=() nb=() gone=()
  for i in "${!F_urls[@]}"; do
    if [[ -n ${isdead[$i]} ]]; then gone+=("${F_names[i]}")
    else nn+=("${F_names[i]}"); nu+=("${F_urls[i]}"); nb+=("${F_blocks[i]}"); fi
  done
  F_names=("${nn[@]}"); F_urls=("${nu[@]}"); F_blocks=("${nb[@]}")
  [[ $VIEW == fav ]] && unstash

  if ((ndead == 1)); then report="Se eliminó 1 stream sin conexión de mi playlist:"
  else report="Se eliminaron $ndead streams sin conexión de mi playlist:"; fi
  for ((i=0; i<${#gone[@]} && i<15; i++)); do report+=$'\n'"• ${gone[i]}"; done
  ((${#gone[@]} > 15)) && report+=$'\n'"… y $((${#gone[@]}-15)) más"
}

show_report() {
  yad --info --center --width=480 --timeout=20 --text="$(esc "$report")" --button="OK:0"
}

# ---------- cambio de lista ----------
stash() {  # guarda la lista activa en su copia (A_* o F_*)
  case $VIEW in
    all) A_names=("${names[@]}"); A_urls=("${urls[@]}"); A_blocks=("${blocks[@]}") ;;
    fav) F_names=("${names[@]}"); F_urls=("${urls[@]}"); F_blocks=("${blocks[@]}") ;;
  esac
}
unstash() {  # carga en la lista activa la copia de $VIEW
  case $VIEW in
    all) names=("${A_names[@]}"); urls=("${A_urls[@]}"); blocks=("${A_blocks[@]}") ;;
    fav) names=("${F_names[@]}"); urls=("${F_urls[@]}"); blocks=("${F_blocks[@]}") ;;
  esac
  marks=()
}
switch_view() {
  stash
  if [[ $VIEW == all ]]; then VIEW=fav; else VIEW=all; fi
  unstash
  filter=""
}

# ---------- buscador ----------
# Varias palabras = todas deben aparecer (en nombre o URL), sin distinguir mayúsculas.
matches() {
  ((${#fwords[@]})) || return 0
  local hay="${1,,}"$'\n'"${2,,}" w
  for w in "${fwords[@]}"; do
    [[ $hay == *"$w"* ]] || return 1
  done
  return 0
}

compute_visible() {
  vis=(); fwords=()
  [[ -n $filter ]] && read -ra fwords <<< "${filter,,}"
  local i
  for i in "${!urls[@]}"; do
    matches "${names[i]}" "${urls[i]}" && vis+=("$i")
  done
}

set_filter() {
  local res
  res=$(yad --entry --title="Buscar" --center --width=480 \
        --text="Buscar en nombre o URL.\nVarias palabras: deben coincidir todas.\nVacío = mostrar todo." \
        --entry-text="$filter" \
        --button="Cancelar!window-close:1" --button="Buscar!edit-find:0") || return
  trim "$res"; filter=$REPLY
  marks=()
}

# ---------- salida de yad --list --print-all  ->  arrays ----------
# Las filas mostradas se vuelcan sobre sus índices originales (vis[]),
# así lo editado bajo un filtro no pisa las filas ocultas.
merge_list() {
  local chk n rest k=0 idx
  while IFS='|' read -r chk n rest; do
    [[ -z $chk ]] && continue
    idx=${vis[k]}; k=$((k+1))
    [[ -z $idx ]] && continue
    trim "${n//|/-}"; n=$REPLY
    [[ -z $n ]] && n=${urls[idx]}
    if [[ $n != "${names[idx]}" ]]; then
      names[idx]=$n
      rename_block "${blocks[idx]}" "$n"; blocks[idx]=$REPLY
    fi
    marks[idx]=$chk
  done <<< "$1"
}

# ---------- acciones ----------
add_entry() {
  local clip="" res n u
  if command -v xclip >/dev/null; then
    clip=$(xclip -o -selection clipboard 2>/dev/null | head -n1)
  elif command -v wl-paste >/dev/null; then
    clip=$(wl-paste 2>/dev/null | head -n1)
  fi
  [[ $clip =~ ^(https?|rtmp|rtsp|mms):// ]] || clip=""

  res=$(yad --form --title="Añadir stream" --center --width=600 \
        --field="Nombre" "" --field="URL" "$clip" \
        --separator='|' --button="Cancelar!window-close:1" --button="Añadir!list-add:0") || return
  IFS='|' read -r n u _ <<< "$res"
  trim "$n"; n=$REPLY; trim "$u"; u=$REPLY
  [[ -z $u ]] && return
  if ((LIVE)) && [[ $VIEW == all ]]; then   # la lista grande es de solo lectura: va a mi playlist
    F_names+=("${n:-$u}"); F_urls+=("$u"); F_blocks+=("")
    status="Añadido a mi playlist: ${n:-$u}"
    return
  fi
  names+=("${n:-$u}"); urls+=("$u"); blocks+=("")
  trim "${n:-$u}"
  matches "$REPLY" "$u" || filter=""   # que la nueva fila no quede oculta
}

delete_marked() {
  ((LIVE)) && [[ $VIEW == all ]] && return   # lista grande en vivo: solo lectura
  local i nn=() nu=() nb=()
  for i in "${!urls[@]}"; do
    [[ ${marks[i]} == TRUE ]] && continue
    nn+=("${names[i]}"); nu+=("${urls[i]}"); nb+=("${blocks[i]}")
  done
  names=("${nn[@]}"); urls=("${nu[@]}"); blocks=("${nb[@]}"); marks=()
}

# Solo desde la lista "todos": copia las filas marcadas a mi playlist (sin duplicar URLs).
add_to_fav() {
  local i u added=0 dup=0
  local -A have=()
  for u in "${F_urls[@]}"; do have["$u"]=1; done
  for i in "${!urls[@]}"; do
    [[ ${marks[i]} == TRUE ]] || continue
    if [[ -n ${have["${urls[i]}"]} ]]; then dup=$((dup+1)); continue; fi
    F_names+=("${names[i]}"); F_urls+=("${urls[i]}"); F_blocks+=("${blocks[i]}")
    have["${urls[i]}"]=1; added=$((added+1))
  done
  marks=()
  if ((added+dup==0)); then status="No hay filas marcadas."
  else
    status="$added añadidos a tu playlist"
    ((dup)) && status+=" ($dup ya estaban)"
    status+="."
  fi
}

play_marked() {
  local i sel=()
  for i in "${!urls[@]}"; do
    [[ ${marks[i]} == TRUE ]] && sel+=("${urls[i]}")
  done
  if ((${#sel[@]})); then
    nohup "$PLAYER" "${sel[@]}" >/dev/null 2>&1 &
  fi
  marks=()
}

sort_by_name() {
  local i idx order nn=() nu=() nb=()
  order=$(for i in "${!urls[@]}"; do printf '%s\t%s\n' "${names[i]//$'\t'/ }" "$i"; done \
          | sort -f -s -t$'\t' -k1,1)
  while IFS=$'\t' read -r _ idx; do
    [[ -z $idx ]] && continue
    nn+=("${names[idx]}"); nu+=("${urls[idx]}"); nb+=("${blocks[idx]}")
  done <<< "$order"
  names=("${nn[@]}"); urls=("${nu[@]}"); blocks=("${nb[@]}"); marks=()
}

# ---------- bucle principal ----------
main() {
  command -v yad >/dev/null || { echo "Falta yad" >&2; exit 1; }
  local rows i out rc info cur label btns err edit

  if ((LIVE)) && [[ $ALL_REFRESH == 1 ]]; then refresh_all; fi
  load_all
  load_file "$FAV_FILE"; F_names=("${LF_names[@]}"); F_urls=("${LF_urls[@]}"); F_blocks=("${LF_blocks[@]}"); F_head=$LF_head
  VIEW=all; unstash

  while :; do
    compute_visible
    rows=()
    for i in "${vis[@]}"; do
      rows+=("${marks[i]:-FALSE}" "${names[i]}")
    done

    edit=(--editable --editable-cols=2)
    if [[ $VIEW == all ]]; then
      label="Todos los streams"
      if ((LIVE)); then
        cur="$ALL_URL — actualizada $(date -r "$ALL_FILE" '+%F %H:%M' 2>/dev/null)"; edit=()
        info="Lista en vivo, de solo lectura. Marca streams y pulsa «A mi playlist»."
      else
        cur=$ALL_FILE
        info="Marca streams y pulsa «A mi playlist». Doble clic en un nombre para editarlo."
      fi
    else
      cur=$FAV_FILE; label="Mi playlist"
      info="Doble clic en un nombre para editarlo. «Guardar» elimina los streams offline y publica."
    fi
    if [[ -n $filter ]]; then
      info="<b>Filtro: «$(esc "$filter")»</b> — mostrando ${#vis[@]} de ${#urls[@]}\n$info"
    fi
    if [[ -n $status ]]; then
      info="<b>$(esc "$status")</b>\n$info"; status=""
    fi

    btns=(--button="Añadir!list-add:10" --button="Buscar!edit-find:14")
    [[ -n $filter ]] && btns+=(--button="Ver todo!edit-clear:15")
    if [[ $VIEW == all ]]; then
      btns+=(--button="A mi playlist!emblem-favorite:20"
             --button="Mi playlist (${#F_urls[@]})!go-next:21")
      ((LIVE)) && btns+=(--button="Actualizar lista!view-refresh:30")
    else
      btns+=(--button="Todos los streams (${#A_urls[@]})!go-previous:21")
    fi
    ((LIVE)) && [[ $VIEW == all ]] || btns+=(--button="Borrar!edit-delete:11")
    btns+=(--button="Reproducir!media-playback-start:12"
           --button="A-Z!view-sort-ascending:13"
           --button="Cancelar!window-close:1"
           --button="Guardar!document-save:0")

    # Las filas van por stdin (sirve para listas muy grandes).
    out=$({ ((${#rows[@]})) && printf '%s\n' "${rows[@]}"; } | \
      yad --list --title="$TITLE — $label" --center --width=900 --height=600 \
      --text="<b>$label</b> — ${#urls[@]} streams\n<small>$(esc "$cur")</small>\n$info" \
      --column="Marcar":CHK --column="Nombre" \
      "${edit[@]}" --print-all --separator='|' \
      --no-markup --search-column=2 \
      "${btns[@]}")
    rc=$?

    [[ -n $out ]] && merge_list "$out"

    case $rc in
      0)  prune_offline
          if save_all; then
            if err=$(publish 2>&1); then
              [[ -n $report ]] && show_report
              exit 0
            else
              yad --error --center --width=500 \
                  --text="Se guardaron los archivos, pero falló la publicación en git:\n\n$(esc "$err")"
              status=$report
            fi
          else yad --error --center --text="No se pudo guardar en:\n$ALL_FILE\n$FAV_FILE"; fi ;;
      10) add_entry ;;
      11) delete_marked ;;
      12) play_marked ;;
      13) sort_by_name ;;
      14) set_filter ;;
      15) filter=""; marks=() ;;
      20) [[ $VIEW == all ]] && add_to_fav ;;
      21) switch_view ;;
      30) ((LIVE)) && [[ $VIEW == all ]] && reload_all ;;
      *)  yad --question --center --text="¿Salir sin guardar los cambios?" \
            --button="Seguir editando:1" --button="Salir:0" && exit 0 ;;
    esac
  done
}

# Permite hacer `source` del script para pruebas sin abrir la interfaz.
[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
