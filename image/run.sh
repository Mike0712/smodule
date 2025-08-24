#!/usr/bin/env bash
set -euo pipefail

# =================== НАСТРОЙКИ ПО УМОЛЧАНИЮ ===================
SELLER_CODE=${SELLER_CODE}

# Куда ходим за эндпойнтами/регистрацией (gateway под nginx)
CENTRAL_URL=${CENTRAL_URL:-http://gateway:8080}

# База для профилей Chrome (на каждого селлера свой каталог)
PROFILE_BASE=${PROFILE_BASE:-/opt/wb/profiles}

# HEADLESS=1 — без X11 (рекомендуется для сервера). HEADLESS=0 — через Xvfb.
HEADLESS=${HEADLESS:-1}

# Chrome
CHROME_BIN=${CHROME_BIN:-google-chrome}
VIDEO_SIZE=${VIDEO_SIZE:-1366,768}          # для окна/кадра
REMOTE_DEBUG_PORT=${REMOTE_DEBUG_PORT:-9222}
URL=${URL}

# Источник видео/аудио для ffmpeg
# VIDEO_SRC: testsrc | x11grab | v4l2 | file
VIDEO_SRC=${VIDEO_SRC:-testsrc}
AUDIO_SRC=${AUDIO_SRC:-sine}                # sine | pulse | alsa | none
INPUT_FILE=${INPUT_FILE:-/opt/wb/input.mp4} # для VIDEO_SRC=file

# Параметры кодеков/PT (должны совпасть с сервером)
PT_VIDEO=${PT_VIDEO:-102}
PT_AUDIO=${PT_AUDIO:-111}

# Интервалы/ретраи
RETRY_DELAY_SEC=${RETRY_DELAY_SEC:-3}
PRODUCER_PING_SEC=${PRODUCER_PING_SEC:-30}

# =================== УТИЛИТЫ/ВСПОМОГАТЕЛЬНЫЕ ===================
log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }
die() { log "FATAL: $*"; exit 1; }

need() {
  command -v "$1" >/dev/null 2>&1 || die "binary not found: $1"
}

# =================== ПРОФИЛЬ CHROME ===================
PROFILE="${PROFILE_BASE}/${SELLER_CODE}"
mkdir -p "$PROFILE"

start_chrome() {
  local FLAGS_COMMON=(
    --user-data-dir="$PROFILE"
    --disable-dev-shm-usage
    --lang=ru
    --window-size="${VIDEO_SIZE}"
    --enable-logging=stderr --v=1
  )
  # root в контейнере — часто нужен no-sandbox
  if [ "$(id -u)" -eq 0 ]; then FLAGS_COMMON+=( --no-sandbox ); fi

  if [ "${HEADLESS}" = "1" ]; then
    local FLAGS_MODE=( --headless=new --disable-gpu --remote-debugging-port="${REMOTE_DEBUG_PORT}" )
    log "Start Chrome (headless) ${VIDEO_SIZE} (profile: ${PROFILE})"
    "${CHROME_BIN}" "${FLAGS_COMMON[@]}" "${FLAGS_MODE[@]}" "${URL}" >/tmp/chrome.log 2>&1 &
  else
    # GUI через Xvfb
    export DISPLAY=${DISPLAY:-:99}
    if ! ss -lx | grep -q "tmp/.X11-unix/X${DISPLAY#:}"; then
      log "Start Xvfb on ${DISPLAY}"
      Xvfb "${DISPLAY}" -screen 0 "${VIDEO_SIZE/x/,}x24" -nolisten tcp >/tmp/xvfb.log 2>&1 &
      sleep 0.5
    fi
    dbus-daemon --session --address=unix:path=/tmp/dbus_session --fork >/dev/null 2>&1 || true
    log "Start Chrome (Xvfb ${DISPLAY}) ${VIDEO_SIZE} (profile: ${PROFILE})"
    "${CHROME_BIN}" "${FLAGS_COMMON[@]}" "${URL}" >/tmp/chrome.log 2>&1 &
  fi
  sleep 2
}

# =================== RTP ЭНДПОЙНТЫ ОТ CENTRAL ===================
get_rtp_endpoints() {
  local url="${CENTRAL_URL}/api/rtp-endpoint/${SELLER_CODE}"
  while true; do
    log "GET ${url}"
    if EP_JSON="$(curl -fsS -X POST "${url}")"; then
      echo "${EP_JSON}"
      return 0
    fi
    log "endpoint not ready, retry in ${RETRY_DELAY_SEC}s…"
    sleep "${RETRY_DELAY_SEC}"
  done
}

# =================== FFMPEG СТАРТ ===================
build_ffmpeg_inputs() {
  local v_in="" a_in=""
  case "${VIDEO_SRC}" in
    testsrc) v_in='-f lavfi -i testsrc=size=1280x720:rate=25' ;;
    x11grab) v_in='-f x11grab -i :99' ;;               # если GUI через Xvfb
    v4l2)    v_in='-f v4l2 -i /dev/video0' ;;
    file)    v_in="-re -stream_loop -1 -i ${INPUT_FILE}" ;;
    *) die "unknown VIDEO_SRC=${VIDEO_SRC}" ;;
  esac
  case "${AUDIO_SRC}" in
    sine)  a_in='-f lavfi -i sine=frequency=1000:sample_rate=48000' ;;
    pulse) a_in='-f pulse -i default' ;;
    alsa)  a_in='-f alsa -i default' ;;
    none)  a_in='' ;;
    *) die "unknown AUDIO_SRC=${AUDIO_SRC}" ;;
  esac
  printf '%s|%s' "$v_in" "$a_in"
}

start_ffmpeg() {
  local json="$1"
  local v_ip v_port a_ip a_port
  v_ip="$(echo "$json" | jq -r '.video.ip')"   || die "jq missing .video.ip"
  v_port="$(echo "$json" | jq -r '.video.port')" || die "jq missing .video.port"
  a_ip="$(echo "$json" | jq -r '.audio.ip')"   || die "jq missing .audio.ip"
  a_port="$(echo "$json" | jq -r '.audio.port')" || die "jq missing .audio.port"

  local vi ai in v_in a_in
  in="$(build_ffmpeg_inputs)"; v_in="${in%%|*}"; a_in="${in##*|}"

  local FFLOG="/tmp/ffmpeg_${SELLER_CODE}.log"
  log "Start ffmpeg → RTP v(${v_ip}:${v_port}, pt=${PT_VIDEO}) a(${a_ip}:${a_port}, pt=${PT_AUDIO})"
  set +e
  ffmpeg -hide_banner -loglevel warning \
    ${v_in} ${a_in} \
    -map 0:v:0 -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
      -g 50 -keyint_min 50 -r 25 -b:v 2500k -profile:v baseline \
    -map 1:a:0? -c:a libopus -b:a 128k -ac 2 -ar 48000 \
    -f rtp_mpegts "rtp://${v_ip}:${v_port}?pkt_size=1200&payload_type=${PT_VIDEO}" \
    -f rtp_mpegts "rtp://${a_ip}:${a_port}?pkt_size=1200&payload_type=${PT_AUDIO}" \
    >"$FFLOG" 2>&1 &
  local pid=$!
  set -e
  echo "$pid"
}

register_producers() {
  local url="${CENTRAL_URL}/api/rtp-producers/${SELLER_CODE}"
  log "POST ${url}"
  curl -fsS -X POST "${url}" >/dev/null
}

keepalive_producers_loop() {
  # периодически пингуем, чтобы central мог переподнять state
  local url="${CENTRAL_URL}/api/rtp-producers/${SELLER_CODE}"
  while true; do
    sleep "${PRODUCER_PING_SEC}" || true
    curl -fsS -X POST "${url}" >/dev/null 2>&1 || true
  done
}

# =================== MAIN LOOP ===================
trap 'log "stop requested"; exit 0' INT TERM

need curl
need jq
need ffmpeg
need "${CHROME_BIN}"

start_chrome

log "Entering run loop for ${SELLER_CODE}"
while true; do
  # 1) получаем эндпойнты
  EP_JSON="$(get_rtp_endpoints)"
  echo "${EP_JSON}" | jq .

  # 2) стартуем ffmpeg
  FFPID="$(start_ffmpeg "${EP_JSON}")"
  log "ffmpeg pid=${FFPID}"

  # 3) регистрируем продюсеров
  if register_producers; then
    log "producers registered"
  else
    log "producers register failed — kill ffmpeg and retry"
    kill "${FFPID}" 2>/dev/null || true
    sleep "${RETRY_DELAY_SEC}"
    continue
  fi

  # 4) фоновый keepalive
  # keepalive_producers_loop &
  # KAPID=$!

  # 5) ждём завершения ffmpeg (если упал — перезапустим цикл)
  wait "${FFPID}" || true
  log "ffmpeg exited, restarting in ${RETRY_DELAY_SEC}s"
  kill "${KAPID}" 2>/dev/null || true
  sleep "${RETRY_DELAY_SEC}"
done
