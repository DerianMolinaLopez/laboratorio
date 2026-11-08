#!/usr/bin/env bash
# Valida que la version del pom.xml de la rama origen del PR sea MAYOR que la de la rama destino.
# Aplica a PRs hacia las ramas de ambiente: dev, QA, release, production.
# Uso: check-version.sh <rama_destino> <sha_origen>
set -euo pipefail

BASE_REF="$1"
HEAD_SHA="$2"

case "$BASE_REF" in
  dev|QA|release|production) ;;
  *)
    echo "Destino '$BASE_REF' no requiere validacion de versionamiento."
    exit 0
    ;;
esac

extract_version() {
  awk '/<artifactId>productos-api<\/artifactId>/{f=1} f && /<version>/{gsub(/.*<version>|<\/version>.*/,""); print; exit}'
}

HEAD_VERSION=$(git show "$HEAD_SHA:pom.xml" | extract_version)
BASE_VERSION=$(git show "origin/$BASE_REF:pom.xml" | extract_version)
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

echo "Version rama origen           : $HEAD_VERSION"
echo "Version rama destino ($BASE_REF): $BASE_VERSION"

HIGHEST=$(printf '%s\n%s\n' "$HEAD_VERSION" "$BASE_VERSION" | sort -V | tail -n1)

if [ "$HEAD_VERSION" = "$BASE_VERSION" ] || [ "$HIGHEST" != "$HEAD_VERSION" ]; then
  MSG="Error de versionamiento: la version del PR ($HEAD_VERSION) debe ser MAYOR que la de $BASE_REF ($BASE_VERSION). Sube la <version> del pom.xml."
  echo "::error file=pom.xml::$MSG"
  echo "### :x: $MSG" >> "$SUMMARY"
  exit 1
fi

echo "Versionamiento correcto: $BASE_VERSION -> $HEAD_VERSION"
echo "### :white_check_mark: Versionamiento correcto: $BASE_VERSION -> $HEAD_VERSION" >> "$SUMMARY"
