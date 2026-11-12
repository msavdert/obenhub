#!/usr/bin/env bash
# Render lab/stage3/otelcol/config.yaml from config.yaml.tmpl: the template
# repeats a block per node or etcd member with
#   #@for VAR in a b c
#   ...@VAR@...
#   #@end
# (no nesting; @VAR@ is replaced inside the block). The rendered file is
# committed because Compose mounts it and lint:otelcol validates it.
#   gen-otelcol.sh          write config.yaml
#   gen-otelcol.sh --check  fail when config.yaml is not what the template renders
set -euo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../otelcol" && pwd)"

render() {
  awk '
    /^#@for [A-Z_]+ in / { var = $2; n = split($0, w, " "); nv = 0
      for (i = 4; i <= n; i++) vals[++nv] = w[i]
      inloop = 1; body = ""; next }
    /^#@end$/ && inloop { for (k = 1; k <= nv; k++) { b = body; gsub("@" var "@", vals[k], b); printf "%s", b }
      inloop = 0; next }
    inloop { body = body $0 "\n"; next }
    { print }
    END { if (inloop) { print "gen-otelcol: unterminated #@for" > "/dev/stderr"; exit 1 } }
  ' "$dir/config.yaml.tmpl"
}

out="$(render)"
if grep -q '@[A-Z_]*@' <<<"$out"; then echo "gen-otelcol: unrendered placeholder" >&2; exit 1; fi
if [ "${1:-}" = "--check" ]; then
  if [ "$out" = "$(cat "$dir/config.yaml")" ]; then echo "gen-otelcol: config.yaml is current"; else
    echo "gen-otelcol: config.yaml differs from its template; run lab/stage3/scripts/gen-otelcol.sh" >&2; exit 1
  fi
else
  printf '%s\n' "$out" >"$dir/config.yaml"
  echo "gen-otelcol: wrote $dir/config.yaml"
fi
