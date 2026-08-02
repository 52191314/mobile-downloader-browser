#!/bin/sh
set -e

# Ensure persistent keys directory exists inside /app/data
mkdir -p /app/data/keys

# Generate active key into persistent volume if missing
if [ ! "$(ls -A /app/data/keys/*.key.pem 2>/dev/null)" ]; then
  KID="${LICENSE_ACTIVE_KID:-aurora-20260725}"
  echo "Generating initial RS256 key pair: $KID into /app/data/keys..."
  node scripts/generate-keys.mjs --dir /app/data/keys --kid "$KID"
fi

exec node dist/index.js
