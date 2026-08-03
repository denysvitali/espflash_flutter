#!/usr/bin/env bash
# setup-release-keystore.sh — one-time release-signing setup for espflash_flutter.
#
# Does all of it:
#   1. Generates a stable release key (JKS, RSA 4096, 30-year validity)
#   2. Verifies it and prints its SHA-256 certificate fingerprint
#   3. Base64-encodes it for CI
#   4. Optionally uploads the 4 GitHub Actions secrets via gh (--upload)
#
# CI consumes: KEYSTORE_BASE64, KEYSTORE_STORE_PASSWORD,
#              KEYSTORE_KEY_PASSWORD, KEYSTORE_KEY_ALIAS
# (wired in .github/workflows/ci.yml + android/app/build.gradle.kts).
#
# Usage:
#   scripts/setup-release-keystore.sh              # generate + print manual steps
#   scripts/setup-release-keystore.sh --upload     # generate + push secrets via gh
#
# Options:
#   --keystore PATH   keystore location (default: ~/.espflash_flutter/release-keystore.jks)
#   --alias NAME      key alias (default: espflash)
#   --repo OWNER/REPO  GitHub repo for --upload (default: gh's detection)
#   --force           overwrite an existing keystore (DANGEROUS: old key is lost)
#
# Passwords: set KEYSTORE_STORE_PASSWORD / KEYSTORE_KEY_PASSWORD in the
# environment to choose them; otherwise strong random ones are generated
# and printed exactly once.
set -euo pipefail

KEYSTORE="${KEYSTORE_PATH:-$HOME/.espflash_flutter/release-keystore.jks}"
ALIAS="${KEYSTORE_ALIAS:-espflash}"
REPO=""
UPLOAD=0
FORCE=0
VALIDITY_DAYS=10950 # 30 years

while [ $# -gt 0 ]; do
  case "$1" in
    --keystore) KEYSTORE="$2"; shift 2 ;;
    --alias)    ALIAS="$2"; shift 2 ;;
    --repo)     REPO="$2"; shift 2 ;;
    --upload)   UPLOAD=1; shift ;;
    --force)    FORCE=1; shift ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

# --- tool resolution (mise first, then PATH) --------------------------------
run_mise() { if command -v mise >/dev/null 2>&1; then mise exec -- "$@"; else "$@"; fi; }

need() {
  local tool="$1" hint="$2"
  if ! run_mise "$tool" --help >/dev/null 2>&1 && ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing tool: $tool — $hint" >&2
    exit 69
  fi
}
need keytool "provided by the JDK; run 'mise install' (java is pinned in .mise.toml)"
need base64  "install coreutils"

if [ "$UPLOAD" -eq 1 ]; then
  need gh "run 'mise install' (github-cli is pinned in .mise.toml)"
fi

# --- helpers ------------------------------------------------------------------
B64_FILE="${KEYSTORE}.b64"

upload_secrets() {
  local gh_args=()
  [ -n "$REPO" ] && gh_args+=(--repo "$REPO")
  echo ">> uploading secrets to GitHub (${REPO:-auto-detected repo})"
  run_mise gh secret set KEYSTORE_BASE64 "${gh_args[@]}" < "$B64_FILE"
  printf '%s' "$KEYSTORE_STORE_PASSWORD" | run_mise gh secret set KEYSTORE_STORE_PASSWORD "${gh_args[@]}"
  printf '%s' "$KEYSTORE_KEY_PASSWORD"  | run_mise gh secret set KEYSTORE_KEY_PASSWORD "${gh_args[@]}"
  printf '%s' "$ALIAS"                  | run_mise gh secret set KEYSTORE_KEY_ALIAS "${gh_args[@]}"
  echo ">> secret state on GitHub:"
  run_mise gh secret list "${gh_args[@]}" | grep -E '^KEYSTORE' | sed 's/^/   /'
}

prompt_passwords_if_needed() {
  if [ -z "${KEYSTORE_STORE_PASSWORD:-}" ]; then
    [ -t 0 ] || { echo "KEYSTORE_STORE_PASSWORD not set and no TTY to prompt" >&2; exit 69; }
    read -r -s -p "store password: " KEYSTORE_STORE_PASSWORD; echo
  fi
  if [ -z "${KEYSTORE_KEY_PASSWORD:-}" ]; then
    [ -t 0 ] || { echo "KEYSTORE_KEY_PASSWORD not set and no TTY to prompt" >&2; exit 69; }
    read -r -s -p "key password: " KEYSTORE_KEY_PASSWORD; echo
  fi
}

# --- guard: never silently replace the stable key ----------------------------
if [ -f "$KEYSTORE" ] && [ "$FORCE" -eq 0 ]; then
  if [ "$UPLOAD" -eq 1 ]; then
    # Recovery mode: the key exists (and may already be distributed),
    # only the CI secrets need (re-)uploading.
    echo ">> keystore exists — upload-only mode, no new key generated"
    base64 < "$KEYSTORE" | tr -d '\n' > "$B64_FILE"
    chmod 600 "$B64_FILE"
    prompt_passwords_if_needed
    upload_secrets
    exit 0
  fi
  cat >&2 <<EOF
keystore already exists: $KEYSTORE

Refusing to overwrite it — this file IS your app's signing identity.
Replacing it means every future APK has a different signature and
existing installs can never update.

If you are sure the old key is backed up (or was never used to sign a
distributed build), re-run with --force.
If you only need to re-upload the CI secrets, re-run with --upload.
EOF
  exit 65
fi

# --- passwords ----------------------------------------------------------------
random_password() {
  # 24 random bytes, URL-safe base64, no padding — 32 chars of A-Za-z0-9-_
  head -c 24 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'
}
check_password_length() {
  # keytool rejects passwords shorter than 6 characters.
  if [ "${#1}" -lt 6 ]; then
    echo "password too short (${#1} chars) — keytool requires at least 6" >&2
    exit 65
  fi
}
GENERATED_PASSWORDS=0
if [ -z "${KEYSTORE_STORE_PASSWORD:-}" ]; then
  KEYSTORE_STORE_PASSWORD="$(random_password)"
  GENERATED_PASSWORDS=1
fi
if [ -z "${KEYSTORE_KEY_PASSWORD:-}" ]; then
  KEYSTORE_KEY_PASSWORD="$(random_password)"
  GENERATED_PASSWORDS=1
fi
check_password_length "$KEYSTORE_STORE_PASSWORD"
check_password_length "$KEYSTORE_KEY_PASSWORD"

# --- generate ------------------------------------------------------------------
mkdir -p "$(dirname "$KEYSTORE")"
echo ">> generating RSA-4096 key (validity ${VALIDITY_DAYS}d) at $KEYSTORE"
run_mise keytool -genkeypair -v \
  -keystore "$KEYSTORE" \
  -storetype JKS \
  -alias "$ALIAS" \
  -keyalg RSA -keysize 4096 \
  -validity "$VALIDITY_DAYS" \
  -storepass "$KEYSTORE_STORE_PASSWORD" \
  -keypass "$KEYSTORE_KEY_PASSWORD" \
  -dname "CN=espflash_flutter, OU=mobile, O=espflash_flutter, L=Zurich, ST=ZH, C=CH" \
  >/dev/null
chmod 600 "$KEYSTORE"

echo ">> verifying"
run_mise keytool -list -v \
  -keystore "$KEYSTORE" -alias "$ALIAS" \
  -storepass "$KEYSTORE_STORE_PASSWORD" \
  | grep -E 'Alias name|Valid from|SHA256:' \
  | sed 's/^/   /'

# Regenerate the base64 sidecar (B64_FILE was set above).
base64 < "$KEYSTORE" | tr -d '\n' > "$B64_FILE"
chmod 600 "$B64_FILE"

# --- upload or print -----------------------------------------------------------
if [ "$UPLOAD" -eq 1 ]; then
  upload_secrets
else
  cat <<EOF

== manual step: add these 4 secrets ==
Repo → Settings → Secrets and variables → Actions → New repository secret

  KEYSTORE_BASE64         → contents of: $B64_FILE
  KEYSTORE_STORE_PASSWORD → (see below)
  KEYSTORE_KEY_PASSWORD   → (see below)
  KEYSTORE_KEY_ALIAS      → $ALIAS

Or re-run with --upload to push them via gh.
EOF
fi

if [ "$GENERATED_PASSWORDS" -eq 1 ]; then
  cat <<EOF

== generated passwords (shown once — store them in your password manager NOW) ==
  KEYSTORE_STORE_PASSWORD = $KEYSTORE_STORE_PASSWORD
  KEYSTORE_KEY_PASSWORD   = $KEYSTORE_KEY_PASSWORD
EOF
fi

cat <<EOF

== done ==
  keystore : $KEYSTORE  (mode 600 — back this file up offline!)
  base64   : $B64_FILE
  alias    : $ALIAS

Losing the keystore or passwords means you can never ship an update
under the same signature. Back both up before anything else.

Next main push after the secrets exist ships APKs signed with this key.
EOF
