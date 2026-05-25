#!/bin/sh
set -e

echo "=== llama-swap kurulumu (mostlygeek/llama-swap) ==="

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
SWAP_VERSION="${SWAP_VERSION:-v217}"
SWAP_VERSION_NUM="$(echo "$SWAP_VERSION" | sed 's/^v//')"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64) ARCH_TAG="amd64" ;;
    aarch64|arm64) ARCH_TAG="arm64" ;;
    *)
        echo "Desteklenmeyen mimari: $ARCH"
        exit 1
        ;;
esac

ASSET="llama-swap_${SWAP_VERSION_NUM}_linux_${ARCH_TAG}.tar.gz"
URL="https://github.com/mostlygeek/llama-swap/releases/download/${SWAP_VERSION}/${ASSET}"

mkdir -p "$BIN_DIR"
cd "$BIN_DIR"

if [ -x "$BIN_DIR/llama-swap" ]; then
    echo "llama-swap zaten kurulu: $BIN_DIR/llama-swap"
    "$BIN_DIR/llama-swap" --version 2>&1 || true
    exit 0
fi

echo "İndiriliyor: $URL"
if command -v curl >/dev/null 2>&1; then
    curl -L -o "$ASSET" "$URL"
elif command -v wget >/dev/null 2>&1; then
    wget -O "$ASSET" "$URL"
else
    echo "curl veya wget gerekli"
    exit 1
fi

tar -xzf "$ASSET"
rm -f "$ASSET"
chmod +x llama-swap

echo "Kuruldu: $BIN_DIR/llama-swap"
"$BIN_DIR/llama-swap" --version 2>&1 || true
