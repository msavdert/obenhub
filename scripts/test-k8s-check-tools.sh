#!/usr/bin/env bash
# shellcheck disable=SC2016
# Test of lab/k8s/scripts/check-tools.sh and of the manifest check in up.sh with
# fake kind, helm, kubectl, kubectl-cnpg, docker and curl on a temporary PATH,
# in a copy of the lab/k8s tree. No docker, no cluster, no network: the fakes
# only log their arguments. Run it with `mise run lab:k8s:tools-test` (part of
# `mise run check`).
set -u

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
FAILED=0
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; FAILED=1; }

# the pins under test come from the real files
# shellcheck source=/dev/null
. "$repo/lab/k8s/versions.sh"
pin() { sed -n "s/^$1 = \"\\([^\"]*\\)\"\$/\\1/p" "$repo/mise.k8s.toml"; }
kind_v=$(pin kind) kubectl_v=$(pin kubectl) helm_v=$(pin helm)

# a tree the scripts can run from: lab/k8s, mise.k8s.toml, lab/packs unused
tree=$work/tree
mkdir -p "$tree/lab"
cp -r "$repo/lab/k8s" "$tree/lab/k8s"
cp "$repo/mise.k8s.toml" "$tree/"
check=$tree/lab/k8s/scripts/check-tools.sh
up=$tree/lab/k8s/scripts/up.sh

# the system tools the scripts use, linked into one directory so that no real
# docker, kind, kubectl or helm can be reached
sysbin=$work/sysbin
mkdir -p "$sysbin"
for c in bash env sed grep head cut tr cat sha256sum mktemp dirname date rm seq sort; do
  ln -s "$(command -v "$c")" "$sysbin/$c"
done
bin=$work/bin
log=$work/calls.log
mkfakes() { # writes the fakes; behaviour from KIND_V etc. at call time
  rm -rf "$bin"; mkdir -p "$bin"
  cat >"$bin/kind" <<'F'
#!/bin/sh
echo "kind $*" >>"$FAKE_LOG"
[ "$1" = version ] || exit 0
[ "${FAKE_KIND_FAIL:-}" = 1 ] && exit 3
echo "kind v${FAKE_KIND_V} go1.25 linux/amd64"
F
  cat >"$bin/helm" <<'F'
#!/bin/sh
echo "helm $*" >>"$FAKE_LOG"
echo "v${FAKE_HELM_V}+gabcdef"
F
  cat >"$bin/kubectl" <<'F'
#!/bin/sh
echo "kubectl $*" >>"$FAKE_LOG"
case "$1" in
  version) echo "Client Version: v${FAKE_KUBECTL_V}" ;;
  cnpg) echo "Build: {Version:${FAKE_CNPG_V} Commit:abc Date:x}" ;;
esac
F
  cat >"$bin/kubectl-cnpg" <<'F'
#!/bin/sh
exit 0
F
  cat >"$bin/docker" <<'F'
#!/bin/sh
echo "docker $*" >>"$FAKE_LOG"
F
  cat >"$bin/curl" <<'F'
#!/bin/sh
echo "curl $*" >>"$FAKE_LOG"
out=
while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
printf 'not the pinned manifest\n' >"$out"
F
  chmod +x "$bin"/*
}

# run: the fakes in front of a minimal system PATH; OBENHUB_MISE_REEXEC=1
# forbids up.sh from re-running itself under mise
run() { # script
  : >"$log"
  env -i HOME="$work" PATH="$bin:$sysbin" FAKE_LOG="$log" OBENHUB_MISE_REEXEC=1 \
    FAKE_KIND_V="${KIND_V:-$kind_v}" FAKE_HELM_V="${HELM_V:-$helm_v}" \
    FAKE_KUBECTL_V="${KUBECTL_V:-$kubectl_v}" FAKE_CNPG_V="${CNPG_V:-$CNPG_VERSION}" \
    FAKE_KIND_FAIL="${KIND_FAIL:-}" \
    "$1" >"$work/out" 2>&1
}
expect_fail() { # description grep-pattern
  if run "$check"; then bad "$1 (exit 0)"; elif grep -q "tool check: .*$2" "$work/out"; then ok "$1"; else bad "$1 (no 'tool check: $2' in: $(tr '\n' '|' <"$work/out"))"; fi
}

mkfakes
if run "$check" && grep -q "^tools ok: kind $kind_v, kubectl $kubectl_v, helm $helm_v, kubectl-cnpg $CNPG_VERSION" "$work/out"; then ok "happy path"; else bad "happy path: $(cat "$work/out")"; fi

KIND_V=0.0.1 expect_fail "wrong kind version" "kind is '0.0.1'"
HELM_V=0.0.1 expect_fail "wrong helm version" "helm is '0.0.1'"
KUBECTL_V=1.36.0 expect_fail "wrong kubectl patch" "kubectl is '1.36.0'"
KUBECTL_V=1.34.2 expect_fail "kubectl two minors away" "more than one minor"
CNPG_V=0.0.1 expect_fail "wrong kubectl-cnpg version" "kubectl-cnpg is '0.0.1'"
KIND_FAIL=1 expect_fail "version command exits non-zero" "kind: 'kind version' failed"
if grep -q "mise" "$work/out"; then ok "non-zero exit hints at mise for a mise tool"; else bad "no mise hint for a failing mise tool"; fi

for t in kind helm kubectl docker; do
  mkfakes; rm "$bin/$t"
  expect_fail "missing $t" "$t not on PATH"
done
mkfakes; rm "$bin/kubectl-cnpg"
expect_fail "missing kubectl-cnpg" "kubectl-cnpg not on PATH"

mkfakes; rm "$bin/docker"
run "$check"
if grep -q "mise" "$work/out"; then bad "missing docker only: mise hint printed"; else ok "missing docker alone gives no mise hint"; fi

mkfakes
sed -i 's/version = "[^"]*"/version = "9.9.9"/' "$tree/mise.k8s.toml"
expect_fail "plugin pin differs from CNPG_VERSION" "pins kubectl-cnpg '9.9.9', versions.sh CNPG_VERSION"
cp "$repo/mise.k8s.toml" "$tree/"

# up.sh: a manifest with the wrong sha256 is refused before kind or kubectl run
mkfakes
if run "$up"; then bad "up.sh accepted a wrong manifest sha256"; else
  if ! grep -q "CNPG_MANIFEST_SHA256" "$work/out"; then bad "up.sh: no sha256 message: $(cat "$work/out")"
  elif ! grep -q '^curl ' "$log"; then bad "up.sh: manifest was not downloaded"
  elif grep -Eq '^kubectl (--context|apply)|^helm (template|upgrade|get)|^kind (create|get)|^docker ' "$log"; then bad "up.sh touched the cluster before refusing: $(cat "$log")"
  else ok "wrong manifest sha refused before any kind or kubectl call"; fi
fi
if grep -q '^kind version' "$log"; then ok "up.sh ran the tool check first"; else bad "up.sh did not run the tool check"; fi

[ "$FAILED" = 0 ] || exit 1
echo "all ok"
