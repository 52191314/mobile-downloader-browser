#!/usr/bin/env bash
# Build a universal (fat) APK from the release AAB via bundletool.
# Reads signing creds from android/key.properties without echoing them.
set -euo pipefail
cd /d/02_Projects/aurora_downloader

# Parse key.properties (CRLF-safe, backslash-tolerant for Windows paths)
storeFile=$(grep '^storeFile' android/key.properties | head -1 | cut -d= -f2- | tr -d '\r')
storePassword=$(grep '^storePassword' android/key.properties | head -1 | cut -d= -f2- | tr -d '\r')
keyAlias=$(grep '^keyAlias' android/key.properties | head -1 | cut -d= -f2- | tr -d '\r')
keyPassword=$(grep '^keyPassword' android/key.properties | head -1 | cut -d= -f2- | tr -d '\r')

# storeFile may be relative to android/ (per Flutter template) or absolute
case "$storeFile" in
  /*|?:*|[A-Za-z]:*) ks="$storeFile" ;;   # absolute (unix or windows drive)
  *) ks="android/$storeFile" ;;            # relative -> android/ dir
esac

# Normalize to Windows path for java
KS_WIN=$(cygpath -w "$ks")
JAR_WIN=$(cygpath -w /d/DevTools/bundletool/bundletool-all.jar)
AAB_WIN=$(cygpath -w "$(pwd)/build/app/outputs/bundle/release/app-release.aab")
OUT_WIN=$(cygpath -w "$(pwd)/build/app/outputs/apk/release/app-release-universal.apks")

echo "Keystore: $KS_WIN"
# bundletool refuses to overwrite an existing output file
rm -f build/app/outputs/apk/release/app-release-universal.apks
java -jar "$JAR_WIN" build-apks \
  --bundle="$AAB_WIN" \
  --output="$OUT_WIN" \
  --mode=universal \
  --ks="$KS_WIN" \
  --ks-pass="pass:$storePassword" \
  --ks-key-alias="$keyAlias" \
  --key-pass="pass:$keyPassword"

echo "=== result ==="
ls -la build/app/outputs/apk/release/app-release-universal.apks
