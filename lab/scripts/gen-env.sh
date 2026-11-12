#!/usr/bin/env bash
# Create or complete a lab's .env file (gitignored, 0600). Shared by every lab.
#   lab/scripts/gen-env.sh ENV_FILE [SECRET_KEY...] [-- KEY=VALUE...]
# Each SECRET_KEY missing from the file (or present with an empty value) gets a
# random value; an existing non-empty value is never changed. Each KEY=VALUE
# after `--` is a derived, non-secret value (box address, uid): all lines of
# that key are replaced by this one unless it is already the only line, so the
# file follows the machine. The file is always set to mode 0600.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: gen-env.sh ENV_FILE [SECRET_KEY...] [-- KEY=VALUE...]" >&2; exit 2; }
env_file=$1; shift
secrets=() derived=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = -- ]; then shift; derived=("$@"); break; fi
  secrets+=("$1"); shift
done
for kv in ${derived[@]+"${derived[@]}"}; do
  case "$kv" in *=*) ;; *) echo "gen-env: derived value without '=': $kv" >&2; exit 2;; esac
done
for key in ${secrets[@]+"${secrets[@]}"} ${derived[@]+"${derived[@]%%=*}"}; do
  case "$key" in *[!A-Za-z0-9_]*|"") echo "gen-env: bad key name: $key" >&2; exit 2;; esac
done

umask 077
touch "$env_file"
chmod 600 "$env_file"
added="" set_keys=""
# make sure appending starts on a new line
if [ -s "$env_file" ] && [ -n "$(tail -c1 "$env_file")" ]; then echo >>"$env_file"; fi
for key in ${secrets[@]+"${secrets[@]}"}; do
  if ! grep -q "^${key}=." "$env_file"; then
    # drop an empty "KEY=" line, then append a fresh value
    tmp="$(mktemp "$env_file.XXXXXX")"
    grep -v "^${key}=" "$env_file" >"$tmp" || true
    echo "${key}=$(openssl rand -hex 16)" >>"$tmp"
    mv "$tmp" "$env_file"
    added="$added $key"
  fi
done
for kv in ${derived[@]+"${derived[@]}"}; do
  key=${kv%%=*}
  # current only when exactly one line for the key exists and it equals KEY=VALUE
  if [ "$(grep -c "^${key}=" "$env_file" || true)" != 1 ] || ! grep -qxF -- "$kv" "$env_file"; then
    tmp="$(mktemp "$env_file.XXXXXX")"
    grep -v "^${key}=" "$env_file" >"$tmp" || true
    echo "$kv" >>"$tmp"
    mv "$tmp" "$env_file"
    set_keys="$set_keys $key"
  fi
done
if [ -n "$added$set_keys" ]; then
  echo "gen-env: $env_file:${added:+ added$added}${set_keys:+ set$set_keys}"
else
  echo "gen-env: $env_file complete, keeping it"
fi
