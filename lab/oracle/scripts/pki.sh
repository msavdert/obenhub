#!/usr/bin/env bash
# Lab CA, gateway server certificate and the client certificate of ora-dg-obs,
# openssl only. Output: lab/oracle/pki/ (gitignored). ca.key is created here and
# never copied to a VM. Idempotent: an existing file is kept; to re-issue,
# delete the file (or the whole directory) and run again.
#   otelcol.{crt,key}          client cert the ora-dg-obs Collector presents to
#                              the gateway (mutual TLS); install it with ca.crt
#                              under /etc/otelcol-contrib/tls
#   gateway/gateway.{crt,key}  server cert of the gateway, SAN IP GATEWAY_IP
#                              (gateway.sh); stays on this box, mounted into the
#                              gateway container
# Same shape as lab/pgha/scripts/pki.sh (copied down to the CA and the two
# leaf kinds this lab needs, not shared: pgha's is built around its node list).
# Assumption: lifetimes (CA 10 years, leaf 2 years) are lab choices, not taken
# from a source.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$dir/gateway.sh"
pki="$dir/pki"
umask 077
mkdir -p "$pki/gateway"

# temp files of issue(), and the key/certificate being written when openssl fails
TMP_FILES=() PARTIAL=()
cleanup() { rm -f "${TMP_FILES[@]}" "${PARTIAL[@]}" "$pki/ca.srl"; }
trap cleanup EXIT

# half a CA means a damaged directory, and a new CA would not match the
# certificates already issued
if { [ -s "$pki/ca.key" ] && [ ! -s "$pki/ca.crt" ]; } || { [ ! -s "$pki/ca.key" ] && [ -s "$pki/ca.crt" ]; }; then
  echo "pki: only one of ca.key and ca.crt exists in $pki; restore both or remove the whole directory" >&2
  exit 1
fi
if [ ! -s "$pki/ca.key" ]; then
  PARTIAL+=("$pki/ca.key" "$pki/ca.crt")
  openssl ecparam -name prime256v1 -genkey -noout -out "$pki/ca.key"
  openssl req -x509 -new -key "$pki/ca.key" -sha256 -days 3650 \
    -subj "/CN=obenhub oracle lab CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -out "$pki/ca.crt"
  PARTIAL=()
  echo "pki: created CA"
fi

# issue <path-prefix> <CN> <extendedKeyUsage> <SAN list or empty>
issue() {
  local prefix="$1" cn="$2" eku="$3" san="$4" ext csr
  if [ -s "$prefix.crt" ] && [ -s "$prefix.key" ]; then return 0; fi
  ext="$(mktemp)"
  csr="$(mktemp)"
  TMP_FILES+=("$ext" "$csr")
  # a failed run leaves no half pair: the next run issues both again
  rm -f "$prefix.key" "$prefix.crt"
  PARTIAL+=("$prefix.key" "$prefix.crt")
  {
    echo "basicConstraints=CA:FALSE"
    echo "keyUsage=critical,digitalSignature,keyEncipherment"
    echo "extendedKeyUsage=$eku"
    [ -z "$san" ] || echo "subjectAltName=$san"
  } >"$ext"
  openssl ecparam -name prime256v1 -genkey -noout -out "$prefix.key"
  openssl req -new -key "$prefix.key" -subj "/CN=$cn" -out "$csr"
  openssl x509 -req -in "$csr" -CA "$pki/ca.crt" -CAkey "$pki/ca.key" -CAcreateserial \
    -days 730 -sha256 -extfile "$ext" -out "$prefix.crt"
  rm -f "$ext" "$csr"
  PARTIAL=()
  echo "pki: issued $prefix.crt"
}

issue "$pki/gateway/gateway" "obenhub-oracle-gateway" "serverAuth" "DNS:obenhub-oracle-gateway,IP:$GATEWAY_IP"
issue "$pki/otelcol" "otelcol-ora-dg-obs" "clientAuth" ""
rm -f "$pki/ca.srl"
echo "pki: $pki complete"
