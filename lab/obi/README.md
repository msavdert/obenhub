# obi

One-off measurement on the `pg-lab` VM: does OpenTelemetry eBPF
Instrumentation (OBI) v1.0.0 add client-side database latency to what the
receivers report? Results and the decision not to adopt it are in
[results/results.md](results/results.md).

Licence (ADR 0004 decision 3): as a separate, unmodified process OBI passes.
`LICENSE` is Apache-2.0 at v1.0.0 and the BPF sources carry Apache-2.0 SPDX
headers, but the programs declare `"Dual MIT/GPL"`
(`bpf/generictracer/generictracer.c`) or `"GPL"` (`bpf/netolly/flows.c`) to
the kernel, and `bpf/bpfcore/` vendors libbpf headers (LGPL-2.1 OR
BSD-2-Clause). Building OBI into the project's own Collector distribution
would fall under decision 2 and needs its own decision first.
