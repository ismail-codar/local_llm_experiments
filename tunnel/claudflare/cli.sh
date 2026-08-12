#!/bin/sh
#
# Cloudflare Tunnel (cloudflared) yönetim aracı — PID ve loglar bu klasörde.
#
# Kullanım örnekleri:
#   ./cli.sh start      # tüneli arka planda başlatır
#   ./cli.sh status     # çalışıyor mu, hangi PID ve hangi mod ile kontrol eder
#   ./cli.sh url        # quick tunnel modunda yayınlanan public URL'i gösterir
#   ./cli.sh log        # son logları gösterir (-f ile canlı izler)
#   ./cli.sh stop       # tüneli durdurur
#   ./cli.sh --help     # komut listesini gösterir
#
# Mod seçimi (.env dosyasına göre, öncelik sırasıyla):
#   1) TUNNEL_TOKEN dolu       -> cloudflared tunnel run --token ...
#   2) config.yml var          -> cloudflared tunnel --config config.yml run [TUNNEL_NAME]
#   3) hiçbiri yok             -> cloudflared tunnel --url $LOCAL_URL (quick tunnel)
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ENV_FILE="$SCRIPT_DIR/.env"
CONFIG_FILE="$SCRIPT_DIR/config.yml"
LOG_FILE="$SCRIPT_DIR/cloudflared.log"
PID_FILE="$SCRIPT_DIR/cloudflared.pid"

LOCAL_URL="http://localhost:8080"
TUNNEL_TOKEN=""
TUNNEL_NAME=""

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

require_cloudflared() {
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo "cloudflared bulunamadı. Önce ./install.sh çalıştırın." >&2
        exit 1
    fi
}

mode() {
    if [ -n "$TUNNEL_TOKEN" ]; then
        echo "token"
    elif [ -f "$CONFIG_FILE" ]; then
        echo "config"
    else
        echo "quick"
    fi
}

is_running() {
    [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

start() {
    require_cloudflared
    if is_running; then
        echo "Tünel zaten çalışıyor (PID $(cat "$PID_FILE"))."
        return
    fi
    rm -f "$PID_FILE"
    cd "$SCRIPT_DIR" || exit 1

    m="$(mode)"
    case "$m" in
        token)
            set -- tunnel --no-autoupdate run --token "$TUNNEL_TOKEN"
            echo "Mod: named tunnel (token)"
            ;;
        config)
            set -- tunnel --no-autoupdate --config "$CONFIG_FILE" run
            [ -n "$TUNNEL_NAME" ] && set -- "$@" "$TUNNEL_NAME"
            echo "Mod: named tunnel (config.yml${TUNNEL_NAME:+, $TUNNEL_NAME})"
            ;;
        quick)
            set -- tunnel --no-autoupdate --url "$LOCAL_URL"
            echo "Mod: quick tunnel -> $LOCAL_URL"
            ;;
    esac

    # Alt kabuk kendi PID'ini yazar, sonra cloudflared'i exec ile yerine koyar
    # => PID_FILE gerçek cloudflared sürecini gösterir.
    printf '%s\n' "--- $(date '+%Y-%m-%d %H:%M:%S') başlatılıyor ($m) ---" >> "$LOG_FILE"
    sh -c 'echo $$ > "$1"; logf="$2"; shift 2; exec cloudflared "$@" >> "$logf" 2>&1' \
        cloudflared-runner "$PID_FILE" "$LOG_FILE" "$@" &

    sleep 2
    if is_running; then
        echo "Tünel başlatıldı (PID $(cat "$PID_FILE"))."
        echo "  Log: $LOG_FILE"
        [ "$m" = "quick" ] && url_wait
    else
        echo "Tünel başlatılamadı. Log: $LOG_FILE" >&2
        tail -n 30 "$LOG_FILE" 2>/dev/null
        exit 1
    fi
}

stop() {
    if ! is_running; then
        echo "Tünel çalışmıyor."
        rm -f "$PID_FILE"
        return
    fi
    pid="$(cat "$PID_FILE")"
    kill "$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        is_running || break
        sleep 1
    done
    if is_running; then
        kill -9 "$pid" 2>/dev/null
    fi
    rm -f "$PID_FILE"
    echo "Tünel durduruldu."
}

status() {
    if is_running; then
        echo "Tünel çalışıyor (PID $(cat "$PID_FILE"), mod: $(mode))."
        [ "$(mode)" = "quick" ] && { u="$(find_url)"; [ -n "$u" ] && echo "  URL: $u"; }
        echo "  Log: $LOG_FILE"
    else
        echo "Tünel çalışmıyor."
        [ -f "$PID_FILE" ] && echo "  Eski PID dosyası duruyor: $PID_FILE"
        exit 1
    fi
}

find_url() {
    [ -f "$LOG_FILE" ] || return 0
    grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG_FILE" 2>/dev/null | tail -n 1
}

url_wait() {
    # Quick tunnel URL'i loga birkaç saniye gecikmeyle düşebiliyor.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        u="$(find_url)"
        [ -n "$u" ] && { echo "  URL: $u"; return 0; }
        sleep 1
    done
    echo "  URL henüz loga düşmedi, birazdan: ./cli.sh url"
}

url() {
    u="$(find_url)"
    if [ -n "$u" ]; then
        echo "$u"
    else
        echo "Public URL bulunamadı (named tunnel modunda URL Cloudflare tarafında tanımlıdır)." >&2
        exit 1
    fi
}

log() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "Log bulunamadı: $LOG_FILE"
        exit 1
    fi
    if [ "$1" = "-f" ] || [ "$1" = "follow" ]; then
        tail -f "$LOG_FILE"
    else
        tail -n 200 "$LOG_FILE"
    fi
}

clearlog() {
    if [ -f "$LOG_FILE" ]; then
        : > "$LOG_FILE"
        echo "Temizlendi: $LOG_FILE"
    else
        echo "Temizlenecek log bulunamadı."
    fi
}

usage() {
    cat <<EOF
Kullanım: $0 <komut>

PID ve loglar bu klasörde tutulur: $SCRIPT_DIR
Yapılandırma: .env (yoksa .env.example'dan kopyalayın) ve opsiyonel config.yml

Komutlar:
  start        Tüneli arka planda başlatır
  stop         Tüneli durdurur
  status       Çalışma durumunu, modu ve varsa URL'i gösterir
  url          Quick tunnel public URL'ini yazar
  log [-f]     Son 200 satır logu gösterir, -f ile canlı izler
  clearlog     Log dosyasını temizler
EOF
}

cmd="${1:-}"
case "$cmd" in
    start)    start ;;
    stop)     stop ;;
    restart)  stop; start ;;
    status)   status ;;
    url)      url ;;
    log)      log "$2" ;;
    clearlog) clearlog ;;
    ""|-h|--help) usage ;;
    *)
        echo "Bilinmeyen komut: $cmd" >&2
        usage
        exit 1
        ;;
esac
