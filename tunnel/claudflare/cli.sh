#!/bin/sh
#
# Cloudflare Tunnel (cloudflared) yönetim aracı — PID ve loglar bu klasörde.
#
# Kullanım örnekleri:
#   ./cli.sh quick 8001      # ngrok gibi anında *.trycloudflare.com adresi verir
#   ./cli.sh start           # .env'deki moda göre tüneli arka planda başlatır
#   ./cli.sh status          # çalışıyor mu, hangi PID/konteyner ve hangi mod ile
#   ./cli.sh url             # yayınlanan public URL'i gösterir
#   ./cli.sh log             # son logları gösterir (-f ile canlı izler)
#   ./cli.sh stop            # tüneli durdurur
#   ./cli.sh --help          # komut listesini gösterir
#
# Çalışma ortamı (.env -> RUNTIME):
#   native (varsayılan)  yerel cloudflared süreci, PID dosyası ile yönetilir
#   docker               cloudflare/cloudflared konteyneri (--network host)
#
# Tünel modu (.env -> MODE; varsayılan quick):
#   quick   -> cloudflared tunnel --url $LOCAL_URL   (VARSAYILAN; hesap/domain
#              gerekmez, her başlatmada yeni rastgele *.trycloudflare.com adresi;
#              geliştirme/test içindir, ~200 eşzamanlı istek sınırı, SSE yok)
#   token   -> cloudflared tunnel run --token ...    (named tunnel, sabit adres)
#   config  -> cloudflared tunnel --config config.yml run [TUNNEL_NAME]
#   auto    -> TUNNEL_TOKEN doluysa token, config.yml varsa config, yoksa quick
#
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

ENV_FILE="$SCRIPT_DIR/.env"
CONFIG_FILE="$SCRIPT_DIR/config.yml"
LOG_FILE="$SCRIPT_DIR/cloudflared.log"
PID_FILE="$SCRIPT_DIR/cloudflared.pid"
MODE_FILE="$SCRIPT_DIR/cloudflared.mode"

RUNTIME="native"
MODE="quick"
LOCAL_URL="http://localhost:8080"
TUNNEL_TOKEN=""
TUNNEL_NAME=""
DOCKER_IMAGE="cloudflare/cloudflared:latest"
CONTAINER_NAME="cloudflared-tunnel"

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

mode() {
    # Çalışan tünel varsa gerçekten hangi modda başlatıldıysa o gösterilir
    # (ör. .env'de token dururken './cli.sh quick' ile başlatılmış olabilir).
    if [ -f "$MODE_FILE" ] && is_running; then
        cat "$MODE_FILE"
        return
    fi
    case "$MODE" in
        quick|token|config) echo "$MODE"; return ;;
    esac
    if [ -n "$TUNNEL_TOKEN" ]; then
        echo "token"
    elif [ -f "$CONFIG_FILE" ]; then
        echo "config"
    else
        echo "quick"
    fi
}

# cloudflared argümanlarını seçilen moda göre kurar; config yolu runtime'a göre
# değişir (docker'da klasör /etc/cloudflared olarak bağlanır).
build_args() {
    conf_path="$1"
    case "$(mode)" in
        token)
            set -- tunnel --no-autoupdate run --token "$TUNNEL_TOKEN"
            ;;
        config)
            set -- tunnel --no-autoupdate --config "$conf_path" run
            [ -n "$TUNNEL_NAME" ] && set -- "$@" "$TUNNEL_NAME"
            ;;
        quick)
            set -- tunnel --no-autoupdate --url "$LOCAL_URL"
            ;;
    esac
    printf '%s\n' "$@"
}

require_native() {
    if ! command -v cloudflared >/dev/null 2>&1; then
        echo "cloudflared bulunamadı. Önce ./install.sh çalıştırın." >&2
        exit 1
    fi
}

require_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "docker bulunamadı. Önce ./install.sh docker çalıştırın." >&2
        exit 1
    fi
}

container_exists() {
    docker inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

is_running() {
    if [ "$RUNTIME" = "docker" ]; then
        [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" = "true" ]
    else
        [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
    fi
}

# "8001" ya da "http://localhost:8001" biçimindeki argümanı LOCAL_URL yapar.
set_quick() {
    MODE="quick"
    case "${1:-}" in
        "")            ;;
        *://*)         LOCAL_URL="$1" ;;
        *[!0-9]*)      LOCAL_URL="http://$1" ;;
        *)             LOCAL_URL="http://localhost:$1" ;;
    esac
}

start() {
    if is_running; then
        echo "Tünel zaten çalışıyor ($(where_running))."
        return
    fi
    m="$(mode)"

    if [ "$m" = "token" ] && [ -z "$TUNNEL_TOKEN" ]; then
        echo "MODE=token seçili ama .env içinde TUNNEL_TOKEN boş." >&2
        exit 1
    fi
    if [ "$m" = "config" ] && [ ! -f "$CONFIG_FILE" ]; then
        echo "MODE=config seçili ama config.yml yok: $CONFIG_FILE" >&2
        exit 1
    fi

    if [ "$RUNTIME" = "docker" ]; then
        require_docker
        container_exists && docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
        echo "Ortam: docker ($DOCKER_IMAGE) — Mod: $m"
        # IFS/newline ile argümanları diziye çevir (POSIX sh'de dizi yok).
        old_ifs="$IFS"; IFS='
'
        # shellcheck disable=SC2046
        set -- $(build_args /etc/cloudflared/config.yml)
        IFS="$old_ifs"
        docker run -d --name "$CONTAINER_NAME" \
            --network host --restart unless-stopped \
            -v "$SCRIPT_DIR:/etc/cloudflared" \
            "$DOCKER_IMAGE" "$@" >/dev/null || exit 1
    else
        require_native
        rm -f "$PID_FILE"
        cd "$SCRIPT_DIR" || exit 1
        echo "Ortam: native — Mod: $m"
        old_ifs="$IFS"; IFS='
'
        # shellcheck disable=SC2046
        set -- $(build_args "$CONFIG_FILE")
        IFS="$old_ifs"
        printf '%s\n' "--- $(date '+%Y-%m-%d %H:%M:%S') başlatılıyor ($m) ---" >> "$LOG_FILE"
        # Alt kabuk kendi PID'ini yazar, sonra cloudflared'i exec ile yerine koyar
        # => PID_FILE gerçek cloudflared sürecini gösterir.
        sh -c 'echo $$ > "$1"; logf="$2"; shift 2; exec cloudflared "$@" >> "$logf" 2>&1' \
            cloudflared-runner "$PID_FILE" "$LOG_FILE" "$@" &
    fi

    sleep 2
    if is_running; then
        printf '%s\n' "$m" > "$MODE_FILE"
        echo "Tünel başlatıldı ($(where_running))."
        url_wait
    else
        echo "Tünel başlatılamadı." >&2
        read_log 30
        exit 1
    fi
}

stop() {
    if ! is_running; then
        echo "Tünel çalışmıyor."
        [ "$RUNTIME" = "docker" ] && container_exists && docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
        rm -f "$PID_FILE" "$MODE_FILE"
        return
    fi

    if [ "$RUNTIME" = "docker" ]; then
        docker stop "$CONTAINER_NAME" >/dev/null && docker rm "$CONTAINER_NAME" >/dev/null
    else
        pid="$(cat "$PID_FILE")"
        kill "$pid" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            is_running || break
            sleep 1
        done
        is_running && kill -9 "$pid" 2>/dev/null
        rm -f "$PID_FILE"
    fi
    rm -f "$MODE_FILE"
    echo "Tünel durduruldu."
}

where_running() {
    if [ "$RUNTIME" = "docker" ]; then
        echo "konteyner $CONTAINER_NAME"
    else
        echo "PID $(cat "$PID_FILE" 2>/dev/null)"
    fi
}

status() {
    if is_running; then
        echo "Tünel çalışıyor ($(where_running), mod: $(mode), ortam: $RUNTIME)."
        u="$(find_url)"
        if [ -n "$u" ]; then
            printf '  URL: %s\n' $u
        elif [ "$(mode)" != "quick" ]; then
            echo "  URL: Cloudflare tarafında tanımlı (Tunnels > ${TUNNEL_NAME:-tünel} > Public Hostname)"
        fi
        [ "$RUNTIME" = "docker" ] || echo "  Log: $LOG_FILE"
    else
        echo "Tünel çalışmıyor (ortam: $RUNTIME)."
        [ "$RUNTIME" = "native" ] && [ -f "$PID_FILE" ] \
            && echo "  Eski PID dosyası duruyor: $PID_FILE"
        exit 1
    fi
}

read_log() {
    lines="${1:-200}"
    if [ "$RUNTIME" = "docker" ]; then
        docker logs --tail "$lines" "$CONTAINER_NAME" 2>&1
    elif [ -f "$LOG_FILE" ]; then
        tail -n "$lines" "$LOG_FILE"
    else
        echo "Log bulunamadı: $LOG_FILE" >&2
        return 1
    fi
}

find_url() {
    logs="$(read_log 1000 2>/dev/null)" || return 0

    # Quick tunnel: URL doğrudan loga yazılır.
    u="$(printf '%s\n' "$logs" | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -n 1)"
    [ -n "$u" ] && { echo "$u"; return 0; }

    # Named tunnel: hostname'ler Cloudflare tarafında tanımlı; cloudflared
    # uzak config'i çekerken ingress kurallarını loga basar.
    # cloudflared config'i kaçışlı JSON olarak basar (\"hostname\":\"...\"),
    # önce ters bölü işaretleri atılıyor.
    printf '%s\n' "$logs" | tr -d '\\' \
        | grep -o '"hostname":"[^"]*"' \
        | sed 's/.*:"//; s/"$//' \
        | grep -v '^$' \
        | awk '!seen[$0]++ { print "https://" $0 }'
}

url_wait() {
    # URL/ingress bilgisi loga birkaç saniye gecikmeyle düşebiliyor.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        u="$(find_url)"
        [ -n "$u" ] && { printf '  URL: %s\n' $u; return 0; }
        sleep 1
    done
    echo "  URL henüz loga düşmedi, birazdan: ./cli.sh url"
}

url() {
    u="$(find_url)"
    if [ -n "$u" ]; then
        echo "$u"
    else
        cat >&2 <<EOF
Public URL loglardan okunamadı.
Named tunnel (token/config) modunda hostname Cloudflare tarafında tanımlıdır:
  Zero Trust > Networks > Tunnels > ${TUNNEL_NAME:-<tünel>} > Public Hostname
Orada bir Public Hostname tanımlı değilse tünel bağlı olsa da erişilebilir URL yoktur.
EOF
        exit 1
    fi
}

log() {
    if [ "$1" = "-f" ] || [ "$1" = "follow" ]; then
        if [ "$RUNTIME" = "docker" ]; then
            docker logs -f "$CONTAINER_NAME"
        else
            [ -f "$LOG_FILE" ] || { echo "Log bulunamadı: $LOG_FILE" >&2; exit 1; }
            tail -f "$LOG_FILE"
        fi
    else
        read_log 200
    fi
}

clearlog() {
    if [ "$RUNTIME" = "docker" ]; then
        echo "Docker modunda loglar konteynerde tutulur; 'docker rm' ile temizlenir."
        return
    fi
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

Yapılandırma ve loglar bu klasörde: $SCRIPT_DIR
Ortam: $RUNTIME (.env -> RUNTIME=native|docker)
Mod  : $(mode) (.env -> MODE=quick|token|config|auto, varsayılan quick)

Komutlar:
  start [PORT|URL]   Tüneli başlatır. Varsayılan quick tunnel: hesap/domain
                     gerekmeden anında *.trycloudflare.com adresi alır
                     (varsayılan $LOCAL_URL). Örn: $0 start 8001
  quick [PORT|URL]   Mod ne olursa olsun quick tunnel'a zorlar
  stop               Tüneli durdurur
  restart            Durdurup yeniden başlatır
  status             Çalışma durumunu, modu ve varsa URL'i gösterir
  url                Public URL'i yazar (quick: log'dan, named: ingress'ten)
  log [-f]           Son 200 satır logu gösterir, -f ile canlı izler
  clearlog           Log dosyasını temizler (native)

Quick tunnel geliştirme/test içindir: her başlatmada adres değişir,
~200 eşzamanlı istek sınırı vardır ve SSE desteklenmez. Sabit adres için
named tunnel (TUNNEL_TOKEN ya da config.yml) kullanın.
EOF
}

cmd="${1:-}"
case "$cmd" in
    quick)    set_quick "$2"; start ;;
    start)    [ -n "$2" ] && set_quick "$2"; start ;;
    stop)     stop ;;
    restart)  stop; [ -n "$2" ] && set_quick "$2"; start ;;
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
