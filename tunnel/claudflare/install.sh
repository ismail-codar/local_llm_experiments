#!/bin/sh
#
# cloudflared (Cloudflare Tunnel) kurulumu — Debian/Ubuntu.
# Önce resmi apt deposu denenir, olmazsa GitHub release .deb paketine düşülür.
#
set -e

if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if command -v cloudflared >/dev/null 2>&1; then
    echo "cloudflared zaten kurulu: $(cloudflared --version)"
    exit 0
fi

$SUDO apt update
$SUDO apt install -y curl gnupg ca-certificates lsb-release

install_from_apt() {
    codename="$(lsb_release -cs 2>/dev/null || echo '')"
    [ -n "$codename" ] || return 1

    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        | $SUDO tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null || return 1

    echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $codename main" \
        | $SUDO tee /etc/apt/sources.list.d/cloudflared.list >/dev/null || return 1

    $SUDO apt update || return 1
    $SUDO apt install -y cloudflared || return 1
}

install_from_deb() {
    case "$(uname -m)" in
        x86_64)          arch="amd64" ;;
        aarch64|arm64)   arch="arm64" ;;
        armv7l|armv6l)   arch="arm" ;;
        *) echo "Desteklenmeyen mimari: $(uname -m)" >&2; return 1 ;;
    esac

    deb="/tmp/cloudflared-linux-$arch.deb"
    url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch.deb"
    echo "apt deposu kullanılamadı, doğrudan indiriliyor: $url"
    curl -fsSL -o "$deb" "$url" || return 1
    $SUDO dpkg -i "$deb" || $SUDO apt install -f -y || return 1
    rm -f "$deb"
}

if ! install_from_apt; then
    # Depo eklenemediyse artık geride bırakma; apt update'i kirletmesin.
    $SUDO rm -f /etc/apt/sources.list.d/cloudflared.list
    install_from_deb
fi

# Sistem genelindeki cloudflared servisini kullanmıyoruz; süreç ve loglar
# cli.sh üzerinden bu klasörde yönetiliyor.
$SUDO systemctl disable --now cloudflared 2>/dev/null || true

cloudflared --version

if [ ! -f "$SCRIPT_DIR/.env" ] && [ -f "$SCRIPT_DIR/.env.example" ]; then
    cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
    echo "Örnek yapılandırma kopyalandı: $SCRIPT_DIR/.env"
fi

echo "Kurulum tamam. Başlatmak için: ./cli.sh start"
