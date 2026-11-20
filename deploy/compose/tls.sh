#!/usr/bin/env bash
# CA, gateway server certificate and one client certificate for the host
# Collectors, openssl only. Output: deploy/compose/tls/ (gitignored).
#   tls.sh <gateway DNS name or IP> [<more names or IPs>...]
#   ca.crt, ca.key       the CA; ca.key stays here, never copy it to a host
#   gateway.{crt,key}    server certificate, SAN = the names and IPs given
#   client.{crt,key}     client certificate every host Collector presents (CN
#                        obenhub-collector); copy it with ca.crt to each host
# Needs bash 4+ and OpenSSL 1.1.1+ (not LibreSSL): -addext, -ext.
# Idempotent: an existing file is kept; to re-issue, delete the file (or the
# directory) and run again. Modelled on lab/oracle/scripts/pki.sh (lifetimes
# are the lab's choice there, not taken from a source: assumption here too,
# CA 10 years, leaf 2 years).
# The keys are 0600 and owned by the user who runs this; the gateway container
# runs as OBENHUB_UID:OBENHUB_GID (.env, default 1000:1000) so it can read them.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: tls.sh <gateway DNS name or IP> [more...]" >&2; exit 2; }
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tls="$dir/tls"
umask 077
mkdir -p "$tls"

san=""
for n in "$@"; do
  if [[ "$n" =~ ^[0-9.]+$ ]] || [[ "$n" == *:* ]]; then kind=IP; else kind=DNS; fi
  san="${san:+$san,}$kind:$n"
done

# Docker creates a directory for a missing bind-mount source; a leftover one
# (or any non-file) here would be kept as "existing" below, so refuse it.
for f in ca.crt ca.key gateway.crt gateway.key client.crt client.key; do
  if [ -e "$tls/$f" ] && [ ! -f "$tls/$f" ]; then
    echo "tls: $tls/$f exists but is not a regular file (a directory made by docker compose?); remove it and run again" >&2
    exit 1
  fi
done

TMP_FILES=() PARTIAL=()
cleanup() { rm -f "${TMP_FILES[@]}" "${PARTIAL[@]}" "$tls/ca.srl"; }
trap cleanup EXIT

if { [ -s "$tls/ca.key" ] && [ ! -s "$tls/ca.crt" ]; } || { [ ! -s "$tls/ca.key" ] && [ -s "$tls/ca.crt" ]; }; then
  echo "tls: only one of ca.key and ca.crt exists in $tls; restore both or remove the directory" >&2
  exit 1
fi
if [ ! -s "$tls/ca.key" ]; then
  PARTIAL+=("$tls/ca.key" "$tls/ca.crt")
  openssl ecparam -name prime256v1 -genkey -noout -out "$tls/ca.key"
  openssl req -x509 -new -key "$tls/ca.key" -sha256 -days 3650 \
    -subj "/CN=obenhub CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$tls/ca.crt"
  PARTIAL=()
  echo "tls: created CA"
fi

# issue <path-prefix> <CN> <extendedKeyUsage> <SAN list or empty>
issue() {
  local prefix="$1" cn="$2" eku="$3" sans="$4" ext csr
  if [ -s "$prefix.crt" ] && [ -s "$prefix.key" ]; then return 0; fi
  ext="$(mktemp)"
  csr="$(mktemp)"
  TMP_FILES+=("$ext" "$csr")
  rm -f "$prefix.key" "$prefix.crt"
  PARTIAL+=("$prefix.key" "$prefix.crt")
  {
    echo "basicConstraints=CA:FALSE"
    echo "keyUsage=critical,digitalSignature,keyEncipherment"
    echo "extendedKeyUsage=$eku"
    [ -z "$sans" ] || echo "subjectAltName=$sans"
  } >"$ext"
  openssl ecparam -name prime256v1 -genkey -noout -out "$prefix.key"
  openssl req -new -key "$prefix.key" -subj "/CN=$cn" -out "$csr"
  openssl x509 -req -in "$csr" -CA "$tls/ca.crt" -CAkey "$tls/ca.key" -CAcreateserial \
    -days 730 -sha256 -extfile "$ext" -out "$prefix.crt"
  rm -f "$ext" "$csr"
  PARTIAL=()
  echo "tls: issued $prefix.crt"
}

# an existing gateway certificate is kept even when the names differ: say so
# (an IPv6 address given in short form warns although it matches: openssl
# prints it expanded)
if [ -s "$tls/gateway.crt" ] && have="$(openssl x509 -in "$tls/gateway.crt" -noout -ext subjectAltName 2>/dev/null)"; then
  have_sorted="$(printf '%s\n' "$have" | sed -n '2p' | tr ',' '\n' | sed -e 's/^ *//' -e 's/IP Address:/IP:/' | sort | paste -sd,)"
  want_sorted="$(printf '%s\n' "$san" | tr ',' '\n' | sort | paste -sd,)"
  if [ "$have_sorted" != "$want_sorted" ]; then
    echo "tls: warning: the existing gateway.crt has SAN '$have_sorted', not '$want_sorted'; it is kept." >&2
    echo "tls: to reissue it, remove $tls/gateway.crt and $tls/gateway.key and run again (hosts keep working: the CA is unchanged)" >&2
  fi
fi
issue "$tls/gateway" "obenhub-gateway" "serverAuth" "$san"
issue "$tls/client" "obenhub-collector" "clientAuth" ""
rm -f "$tls/ca.srl"
echo "tls: $tls complete"
