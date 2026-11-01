#!/usr/bin/env bash
# the android app's release key, made once. every update has to carry the same key, so keep the
# keystore file and its password safe: a lost key means people reinstall instead of updating
#   tools/android/keystore.sh <keystore file> [owner/repo]
# the password goes to the keyring (secret-tool: application noonix-tv-build, key
# ANDROID_KEYSTORE_PASS); with a repo, the keystore (base64) and the password also become its
# actions secrets ANDROID_KEYSTORE and ANDROID_KEYSTORE_PASS, which the release workflow signs with
set -euo pipefail
ks="${1:?usage: keystore.sh <keystore file> [owner/repo]}"
repo="${2:-}"
if [[ -e "$ks" ]]; then
    echo "$ks is there already: not making another key" >&2
else
    mkdir -p "$(dirname "$ks")"
    export KS_PASS="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
    (umask 077 && keytool -genkeypair -keystore "$ks" -storetype PKCS12 -storepass:env KS_PASS -keypass:env KS_PASS \
        -alias noonix -keyalg RSA -keysize 4096 -validity 36500 -dname "CN=Noonix TV" > /dev/null)
    printf '%s' "$KS_PASS" | secret-tool store --label "Noonix TV android keystore password" application noonix-tv-build key ANDROID_KEYSTORE_PASS
    unset KS_PASS
    echo "made $ks (alias noonix), its password is in the keyring"
fi
if [[ -n "$repo" ]]; then
    secret-tool lookup application noonix-tv-build key ANDROID_KEYSTORE_PASS | gh secret set ANDROID_KEYSTORE_PASS -R "$repo"
    base64 < "$ks" | tr -d '\n' | gh secret set ANDROID_KEYSTORE -R "$repo"
    echo "$repo has ANDROID_KEYSTORE and ANDROID_KEYSTORE_PASS now"
fi
