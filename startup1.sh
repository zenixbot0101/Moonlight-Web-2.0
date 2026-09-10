#!/bin/bash
# Windows DD Reinstall Script
# Hosted on GitHub, called by GCP startup-script metadata
# Credentials: dung / Pzkxvu123@

exec > /var/log/reinstall.log 2>&1
echo "[startup] Starting DD reinstall at $(date)"

wget -q https://github.com/bin456789/reinstall/raw/refs/heads/main/reinstall.sh
bash reinstall.sh dd \
  --username dung \
  --password 'Pzkxvu123@' \
  --web-port 9000 \
  --img "https://huggingface.co/fdasgew/Win12gz/resolve/main/windows-data.img.gz?download=true"

curl -s ifconfig.me
sudo reboot -f
