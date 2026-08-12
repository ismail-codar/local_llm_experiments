#!/bin/sh
#
# cloudflared (Cloudflare Tunnel) kurulumu.
#
# Platform otomatik algılanır:
#   Debian/Ubuntu  -> resmi apt deposu, olmazsa GitHub release .deb
#   RHEL/Fedora    -> resmi rpm deposu, olmazsa GitHub release .rpm
#   macOS          -> homebrew
#   diğer Linux    -> /usr/local/bin altına statik binary
#
# Docker ile çalıştırmak isterseniz:  ./install.sh docker
# (imajı çeker; cli.sh içinde .env -> RUNTIME=docker ile kullanılır)
#
set -e

if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_IMAGE="cloudflare/cloudflared:latest"

arch_tag() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l|armv6l) echo "arm" ;;
        *) return 1 ;;
    esac
}

copy_env() {
    if [ ! -f "$SCRIPT_DIR/.env" ] && [ -f "$SCRIPT_DIR/.env.example" ]; then
        cp "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env"
        echo "Örnek yapılandırma kopyalandı: $SCRIPT_DIR/.env"
    fi
}

# --- docker modu ------------------------------------------------------------
if [ "${1:-}" = "docker" ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "docker bulunamadı." >&2
        exit 1
    fi
    docker pull "$DOCKER_IMAGE"
    copy_env
    echo "Docker imajı hazır: $DOCKER_IMAGE"
    echo ".env içinde RUNTIME=docker yapıp ./cli.sh start ile başlatın."
    exit 0
fi

if command -v cloudflared >/dev/null 2>&1; then
    echo "cloudflared zaten kurulu: $(cloudflared --version)"
    copy_env
    exit 0
fi

# --- apt (Debian / Ubuntu) --------------------------------------------------
install_apt() {
    $SUDO apt update
    $SUDO apt install -y curl gnupg ca-certificates lsb-release

    codename="$(lsb_release -cs 2>/dev/null || echo '')"
    if [ -n "$codename" ] \
        && curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
            | $SUDO tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null \
        && echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $codename main" \
            | $SUDO tee /etc/apt/sources.list.d/cloudflared.list >/dev/null \
        && $SUDO apt update \
        && $SUDO apt install -y cloudflared; then
        return 0
    fi

    # Depo eklenemediyse geride bırakma; sonraki apt update'i kirletmesin.
    $SUDO rm -f /etc/apt/sources.list.d/cloudflared.list
    arch="$(arch_tag)" || { echo "Desteklenmeyen mimari: $(uname -m)" >&2; return 1; }
    deb="/tmp/cloudflared-linux-$arch.deb"
    echo "apt deposu kullanılamadı, .deb doğrudan indiriliyor."
    curl -fsSL -o "$deb" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch.deb"
    $SUDO dpkg -i "$deb" || $SUDO apt install -f -y
    rm -f "$deb"
}

# --- rpm (RHEL / Fedora / CentOS) -------------------------------------------
install_rpm() {
    pkg="dnf"
    command -v dnf >/dev/null 2>&1 || pkg="yum"

    if curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo \
            | $SUDO tee /etc/yum.repos.d/cloudflared.repo >/dev/null \
        && $SUDO "$pkg" install -y cloudflared; then
        return 0
    fi

    $SUDO rm -f /etc/yum.repos.d/cloudflared.repo
    case "$(uname -m)" in
        x86_64|amd64)  rarch="x86_64" ;;
        aarch64|arm64) rarch="aarch64" ;;
        *) echo "Desteklenmeyen mimari: $(uname -m)" >&2; return 1 ;;
    esac
    echo "rpm deposu kullanılamadı, .rpm doğrudan indiriliyor."
    $SUDO "$pkg" install -y \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$rarch.rpm"
}

# --- macOS ------------------------------------------------------------------
install_brew() {
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew bulunamadı: https://brew.sh" >&2
        return 1
    fi
    brew install cloudflared
}

# --- generic linux binary ---------------------------------------------------
install_binary() {
    arch="$(arch_tag)" || { echo "Desteklenmeyen mimari: $(uname -m)" >&2; return 1; }
    tmp="/tmp/cloudflared-linux-$arch"
    echo "Paket yöneticisi algılanamadı, statik binary indiriliyor."
    curl -fsSL -o "$tmp" \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch"
    chmod +x "$tmp"
    $SUDO mv "$tmp" /usr/local/bin/cloudflared
}

case "$(uname -s)" in
    Darwin)
        install_brew
        ;;
    Linux)
        if command -v apt-get >/dev/null 2>&1; then
            install_apt
        elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
            install_rpm
        else
            install_binary
        fi
        # Sistem genelindeki cloudflared servisini kullanmıyoruz; süreç ve
        # loglar cli.sh üzerinden bu klasörde yönetiliyor.
        $SUDO systemctl disable --now cloudflared 2>/dev/null || true
        ;;
    MINGW*|MSYS*|CYGWIN*)
        echo "Windows: 'winget install --id Cloudflare.cloudflared' ya da" >&2
        echo "https://github.com/cloudflare/cloudflared/releases (cloudflared-windows-amd64.exe)" >&2
        echo "cli.sh POSIX kabuk + sinyal tabanlıdır; Windows'ta WSL veya Docker kullanın." >&2
        exit 1
        ;;
    *)
        echo "Desteklenmeyen işletim sistemi: $(uname -s)" >&2
        exit 1
        ;;
esac

cloudflared --version
copy_env
echo "Kurulum tamam. Başlatmak için: ./cli.sh start"
