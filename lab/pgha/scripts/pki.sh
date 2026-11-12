#!/usr/bin/env bash
# Lab CA and per-node certificates for the pgha VMs, openssl only.
# Output: lab/pgha/pki/ (gitignored). ca.key is created here and never copied
# to a VM; provision.sh ships ca.crt, node certs and node keys only.
# Idempotent: an existing file is kept, so rerunning changes nothing. To
# re-issue, delete the file (or the whole directory) and run again.
#
# Layout, per node <n>:
#   <n>/etcd.{crt,key}      etcd server and peer (EKU serverAuth+clientAuth: etcd
#                           uses the same cert to dial its peers, see etcd
#                           security docs, "Example 3: Multiple member cluster"
#                           which uses one cert for both roles)
#   <n>/postgres.{crt,key}  PostgreSQL server
#   <n>/patroni.{crt,key}   Patroni REST API (server; clientAuth too, members
#                           call each other's API)
#   patroni-etcd.{crt,key}  client cert Patroni presents to etcd (shared)
#   etcdctl.{crt,key}       client cert for etcdctl on the VMs (shared)
#   <n>/otelcol.{crt,key}   client cert the node Collector presents to the
#                           telemetry gateway (mutual TLS)
#   gateway/gateway.{crt,key}  server cert of the gateway, SAN IP GATEWAY_IP
#                           (nodes.sh); stays on this box, mounted into the
#                           gateway container
# The CA signs every certificate, so any of them passes the gateway's client
# check (client_ca_file is the whole CA). That is a lab simplification.
# Assumption: lifetimes (CA 10 years, leaf 2 years) are lab choices, not
# taken from a source.
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
. "$dir/nodes.sh"
pki="$dir/pki"
umask 077
mkdir -p "$pki"

# temp files of issue(), and the key/certificate being written when openssl
# fails; openssl errors go to the terminal
TMP_FILES=() PARTIAL=()
cleanup() { rm -f "${TMP_FILES[@]}" "${PARTIAL[@]}"; }
trap cleanup EXIT

# a new CA is made only when neither file exists: half a CA means a damaged
# directory, and a new CA would not match the certificates already issued
if { [ -s "$pki/ca.key" ] && [ ! -s "$pki/ca.crt" ]; } || { [ ! -s "$pki/ca.key" ] && [ -s "$pki/ca.crt" ]; }; then
  echo "pki: only one of ca.key and ca.crt exists in $pki; restore both or remove the whole directory" >&2
  exit 1
fi
if [ ! -s "$pki/ca.key" ]; then
  PARTIAL+=("$pki/ca.key" "$pki/ca.crt")
  openssl ecparam -name prime256v1 -genkey -noout -out "$pki/ca.key"
  openssl req -x509 -new -key "$pki/ca.key" -sha256 -days 3650 \
    -subj "/CN=obenhub pgha lab CA" \
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

for entry in $NODES; do
  n="${entry%%=*}"
  ip="${entry#*=}"
  mkdir -p "$pki/$n"
  san="DNS:$n,DNS:localhost,IP:$ip,IP:127.0.0.1"
  issue "$pki/$n/etcd" "$n" "serverAuth,clientAuth" "$san"
  issue "$pki/$n/postgres" "$n" "serverAuth" "$san"
  issue "$pki/$n/patroni" "$n" "serverAuth,clientAuth" "$san"
  issue "$pki/$n/otelcol" "otelcol-$n" "clientAuth" ""
done
mkdir -p "$pki/gateway"
issue "$pki/gateway/gateway" "obenhub-pgha-gateway" "serverAuth" "DNS:obenhub-pgha-gateway,IP:$GATEWAY_IP"
issue "$pki/patroni-etcd" "patroni" "clientAuth" ""
issue "$pki/etcdctl" "etcdctl" "clientAuth" ""
rm -f "$pki/ca.srl"
echo "pki: $pki complete"
