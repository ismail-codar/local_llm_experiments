#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

ACCESS_LOG="/var/log/caddy/access.log"
ERROR_LOG="/var/log/caddy/error.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CADDYFILE_SRC="$SCRIPT_DIR/Caddyfile"
CADDYFILE_DST="/etc/caddy/Caddyfile"

start() {
    $SUDO systemctl start caddy
    $SUDO systemctl status caddy --no-pager
}

stop() {
    $SUDO systemctl stop caddy
    $SUDO systemctl status caddy --no-pager || true
}

refresh() {
    if [ ! -f "$CADDYFILE_SRC" ]; then
        echo "Caddyfile bulunamadı: $CADDYFILE_SRC" >&2
        exit 1
    fi
    $SUDO cp "$CADDYFILE_SRC" "$CADDYFILE_DST"
    $SUDO caddy validate --config "$CADDYFILE_DST"
    $SUDO systemctl reload caddy
    echo "Caddyfile yüklendi ve reload edildi."
}

log() {
    echo "Hangi log türünü görmek istersiniz?"
    echo "  1) systemd (journalctl -u caddy)"
    echo "  2) error log  ($ERROR_LOG)"
    echo "  3) access log ($ACCESS_LOG)"
    echo "  4) tümünü canlı izle (journalctl -f)"
    read -rp "Seçim [1-4]: " choice

    case "$choice" in
        1)
            $SUDO journalctl -u caddy --no-pager -n 200
            ;;
        2)
            if [ -f "$ERROR_LOG" ]; then
                $SUDO tail -n 200 "$ERROR_LOG"
            else
                echo "Error log bulunamadı: $ERROR_LOG"
                echo "Caddyfile içinde 'log' direktifi tanımlı mı kontrol edin."
            fi
            ;;
        3)
            if [ -f "$ACCESS_LOG" ]; then
                $SUDO tail -n 200 "$ACCESS_LOG"
            else
                echo "Access log bulunamadı: $ACCESS_LOG"
                echo "Caddyfile içinde 'log' direktifi tanımlı mı kontrol edin."
            fi
            ;;
        4)
            $SUDO journalctl -u caddy -f
            ;;
        *)
            echo "Geçersiz seçim: $choice" >&2
            exit 1
            ;;
    esac
}

usage() {
    cat <<EOF
Kullanım: $0 <komut>

Komutlar:
  start    Caddy servisini başlatır
  stop     Caddy servisini durdurur
  refresh  Yerel Caddyfile'ı /etc/caddy/Caddyfile'a kopyalar, doğrular ve reload eder
  log      Log türünü sorar ve gösterir
EOF
}

cmd="${1:-}"
case "$cmd" in
    start)   start ;;
    stop)    stop ;;
    refresh) refresh ;;
    log)     log ;;
    ""|-h|--help) usage ;;
    *)
        echo "Bilinmeyen komut: $cmd" >&2
        usage
        exit 1
        ;;
esac
