#!/usr/bin/env bash
# Bypass CI: rsync current src to silencer, build the ARM64 dedicated server
# binary there, swap it into /opt/zsilencer/current, restart the service.
# For debug iterations only — prod should go through .github/workflows/deploy.yml.
set -euo pipefail

HOST="${HOST:-silencer}"
REMOTE="/home/ubuntu/zsilencer-src"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> rsync source to $HOST:$REMOTE"
rsync -az --delete \
  --exclude=build --exclude=.git --exclude=terraform \
  --exclude=.github --exclude='*.o' --exclude='*.zip' \
  "$REPO/" "ubuntu@$HOST:$REMOTE/"

echo "==> build on $HOST"
ssh "ubuntu@$HOST" "cd $REMOTE && mkdir -p build && cd build && \
  cmake -DCMAKE_BUILD_TYPE=Release -DZSILENCER_LOBBY_HOST=silencer.hventura.com .. > /tmp/cmake.log 2>&1 && \
  make -j\$(nproc) zsilencer 2>&1 | tail -3"

echo "==> swap binary and restart lobby"
ssh "ubuntu@$HOST" "sudo cp $REMOTE/build/zsilencer /opt/zsilencer/current/zsilencer && \
  sudo chmod +x /opt/zsilencer/current/zsilencer && \
  sudo systemctl restart zsilencer-lobby && \
  sleep 2 && systemctl is-active zsilencer-lobby"
