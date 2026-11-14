# Collector pack

`rules.yml` holds the engine-neutral alerts every lab loads: `Watchdog`
(always firing, proves the alert pipeline), `CollectorAbsent` (an expected
Collector with no self-metrics) and `CollectorUnknown` (an inventory entry that
names no expected Collector). `tests/` are their unit tests.

A lab mounts this file into vmalert next to its engine pack and defines
`obenhub.expected_collector`, `obenhub.expected_target` and
`obenhub.expected_scrape` in its own inventory group. Names follow
[ADR 0006](../../../docs/adr/0006-naming-contract.md).
