#!/bin/bash
echo "=== llama-swap ve llama-server durduruluyor... ==="

# Önce llama-swap (varsa) — kendi spawn ettiği llama-server'ları da temizler
pkill -TERM -f "llama-swap" || true

# Sonra llama-server (direkt başlatılmış olanlar için)
pkill -TERM -f "llama-server" || true
sleep 2

# Hala varsa zorla öldür
pkill -KILL -f "llama-swap" || true
pkill -KILL -f "llama-server" || true

echo "✅ Tüm llama-swap ve llama-server süreçleri durduruldu."