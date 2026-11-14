# Changelog

## [0.15.0](https://github.com/msavdert/obenhub/compare/v0.14.0...v0.15.0) (2026-11-14)


### Features

* **lab:** alert rules for the Oracle Data Guard pack ([#63](https://github.com/msavdert/obenhub/issues/63)) ([b44cb75](https://github.com/msavdert/obenhub/commit/b44cb75844d679234844c3f6b4a09850082cf78a))
* **lab:** Collector on ora-dg-obs and the oracledb role-staleness record ([#61](https://github.com/msavdert/obenhub/issues/61)) ([ea721e2](https://github.com/msavdert/obenhub/commit/ea721e26c80517c6ce3be57512645ec891e74ba5))
* **lab:** first Oracle fault scenarios on the CDB19 Data Guard pair ([#64](https://github.com/msavdert/obenhub/issues/64)) ([421c06b](https://github.com/msavdert/obenhub/commit/421c06b161ebe39c5276f96696bd4a34a6a7c55f))
* **lab:** Oracle Data Guard dashboard ([#65](https://github.com/msavdert/obenhub/issues/65)) ([285b034](https://github.com/msavdert/obenhub/commit/285b0343d0776d9ed12352daed62fa99d2def020))
* **lab:** Oracle first slice - monitoring users, Collector config and Data Guard pack ([#58](https://github.com/msavdert/obenhub/issues/58)) ([4527b28](https://github.com/msavdert/obenhub/commit/4527b28a876cd123be8f34ae61f23c6f0aac2688))
* **lab:** Oracle monitoring backend with a shared mutual-TLS gateway ([#60](https://github.com/msavdert/obenhub/issues/60)) ([c250baa](https://github.com/msavdert/obenhub/commit/c250baae83bce302b0154bd8d077a2ff2f3c4e19))
* **lab:** pg_basebackup comparison scenario in slice1 ([#54](https://github.com/msavdert/obenhub/issues/54)) ([1172594](https://github.com/msavdert/obenhub/commit/1172594d242168a75d4bbade550d8c8062f8f125))
* **lab:** pgBackRest in slice1 with backup alerts, stale and PITR scenarios ([#51](https://github.com/msavdert/obenhub/issues/51)) ([b9bea94](https://github.com/msavdert/obenhub/commit/b9bea942a0edababead5ac5d3379fe7084c37ce6))


### Documentation

* **adr:** 0008 Oracle lab scope, topology and first slice ([#55](https://github.com/msavdert/obenhub/issues/55)) ([192789d](https://github.com/msavdert/obenhub/commit/192789d57a0e7c7ed0d430698d7dc6d422c76699))
* recheck Oracle receiver facts, add managed Oracle and operator items ([#59](https://github.com/msavdert/obenhub/issues/59)) ([08aaa8e](https://github.com/msavdert/obenhub/commit/08aaa8e234e4b575069fcd097f8db41b93412b19))
* **roadmap:** run Oracle in parallel with the PostgreSQL items ([#53](https://github.com/msavdert/obenhub/issues/53)) ([846bf5c](https://github.com/msavdert/obenhub/commit/846bf5c23bff163076738ddd7ab7d93439c4bebe))
* **roadmap:** track upstream issue contrib[#53105](https://github.com/msavdert/obenhub/issues/53105) and the oracledb role candidate ([#57](https://github.com/msavdert/obenhub/issues/57)) ([fd41361](https://github.com/msavdert/obenhub/commit/fd41361c9651e833a3c876c51e29d1ec4bae05c9))
* **roadmap:** version drift item for every engine ([#56](https://github.com/msavdert/obenhub/issues/56)) ([d0202f5](https://github.com/msavdert/obenhub/commit/d0202f57e071c302863507c3717060a51bf6d5f6))

## [0.14.0](https://github.com/msavdert/obenhub/compare/v0.13.0...v0.14.0) (2026-11-13)


### ⚠ BREAKING CHANGES

* **lab:** metric, attribute and alert names change per ADR 0006; restart running lab Collectors and recreate vmalert/Alertmanager before the next suite.

### refactor

* **lab:** apply the naming contract (ADR 0006) ([#26](https://github.com/msavdert/obenhub/issues/26)) ([bcbb5e2](https://github.com/msavdert/obenhub/commit/bcbb5e264da02c120de81e407a35dc450b8c8d25))


### Features

* **lab:** add CloudNativePG/Kubernetes and host dashboards ([#29](https://github.com/msavdert/obenhub/issues/29)) ([f1a233f](https://github.com/msavdert/obenhub/commit/f1a233f84a412c8098863f5020d550e5c77aa8f8))
* **lab:** add the pgha synchronous-standby-cut scenario and a missing-sync-standby alert ([#34](https://github.com/msavdert/obenhub/issues/34)) ([239409f](https://github.com/msavdert/obenhub/commit/239409f6d172904d2476f9e071504e0e95a40be9))
* **lab:** add the stage 4 kind lab with CloudNativePG and a PostgreSQL 18 cluster ([b1fabeb](https://github.com/msavdert/obenhub/commit/b1fabeb37bb3c42eef20a504d1ce8e2b1d332a4d))
* **lab:** alert on CloudNativePG primary changes and run switchover and failover scenarios on kind ([9cf57f5](https://github.com/msavdert/obenhub/commit/9cf57f5f707150424b73d5266c077ae454c31966))
* **lab:** alert on fenced CloudNativePG instances and slots retaining WAL, with fenced, replica-cut and slot scenarios on kind ([427ccbf](https://github.com/msavdert/obenhub/commit/427ccbfc46c055d1109d1709e47bfcd0410a20fa))
* **lab:** alert on NotReady Kubernetes nodes and run a worker power-cut scenario on kind ([362c2bd](https://github.com/msavdert/obenhub/commit/362c2bd983a4fff2481c794bd7e979064c8f2c52))
* **lab:** alert on two writable primaries from Patroni and from PostgreSQL ([#22](https://github.com/msavdert/obenhub/issues/22)) ([87e8dfc](https://github.com/msavdert/obenhub/commit/87e8dfcb51e9dc233756985075c44b07b5a851ed))
* **lab:** archive WAL in slice1, monitor pg_stat_archiver, add archiver-failing ([#31](https://github.com/msavdert/obenhub/issues/31)) ([84e2472](https://github.com/msavdert/obenhub/commit/84e247249f7d1b33ca261db3ff2428328b71aec8))
* **lab:** collect PostgreSQL, Kubernetes and logs from the kind lab into obenhub-k8s ([5237de8](https://github.com/msavdert/obenhub/commit/5237de84bcf2ff51e3a544593af90c15d7cb1dda))
* **lab:** report labs whose suite evidence predates their code ([#24](https://github.com/msavdert/obenhub/issues/24)) ([e92dba5](https://github.com/msavdert/obenhub/commit/e92dba5b93213eb657d4a6bfc9afdd7229d575dd))
* **lab:** run scenario suites on a clean tree under one host lock ([#23](https://github.com/msavdert/obenhub/issues/23)) ([dbe9b53](https://github.com/msavdert/obenhub/commit/dbe9b530ab820f32c98c2a07f1cf19f480051748))
* **lab:** scrape CloudNativePG's exporter for cnpg_collector_* only ([f7cf626](https://github.com/msavdert/obenhub/commit/f7cf626649bafa3149699cc87afd6440a3380f29))


### Bug fixes

* **ci:** open the end-of-life issue only on a finding ([#47](https://github.com/msavdert/obenhub/issues/47)) ([3f6ba85](https://github.com/msavdert/obenhub/commit/3f6ba85538f6232165456944cedcc633257723fa))
* **lab:** count only complete, clean suites of the full scenario list on main ([#28](https://github.com/msavdert/obenhub/issues/28)) ([025ed9f](https://github.com/msavdert/obenhub/commit/025ed9f957aa44b2d970665cfd309f90d7fd1c5c))
* **lab:** guard temp-dir removal, fail on silent timeouts, move the suite lock to the user runtime dir ([#42](https://github.com/msavdert/obenhub/issues/42)) ([09e96f3](https://github.com/msavdert/obenhub/commit/09e96f31c0635a76b3b151656dc8ea3b76f84790))
* **lab:** keep prose out of the evidence staleness check and reject suites with mixed or missing config hashes ([#41](https://github.com/msavdert/obenhub/issues/41)) ([2a87758](https://github.com/msavdert/obenhub/commit/2a87758ff6c24b0c5aa53477f8cc024c95472a1d))
* **lab:** pgha provision waits for a healthy cluster, load runs as app, images by digest ([#35](https://github.com/msavdert/obenhub/issues/35)) ([4e1c22d](https://github.com/msavdert/obenhub/commit/4e1c22dfcd2df34c54dfd867365a719820f389a4))
* **lab:** pin images by digest, keep passwords off command lines, wait for conditions instead of sleeps ([#33](https://github.com/msavdert/obenhub/issues/33)) ([f9f76c2](https://github.com/msavdert/obenhub/commit/f9f76c22ea52089e45f3e24d49bc6e1c372a0301))
* **lab:** run every pack rule test file, fix the archiver backlog pending case ([#32](https://github.com/msavdert/obenhub/issues/32)) ([64b90d1](https://github.com/msavdert/obenhub/commit/64b90d12f7bea5f0b34a1f8d0e7a0f91c1152947))
* **lab:** start slot-invalidated only well before the next timed checkpoint ([#45](https://github.com/msavdert/obenhub/issues/45)) ([aba0f39](https://github.com/msavdert/obenhub/commit/aba0f395cd27cbb500ba650bc3ec5831fb37b918))
* **lab:** tie PostgresSeriesVanished to the pack queries, alert on a held xmin horizon, give the split-brain alerts a scrape of margin ([#43](https://github.com/msavdert/obenhub/issues/43)) ([276ffee](https://github.com/msavdert/obenhub/commit/276ffee1d878b3468d9677e8fb86670c9bb55959))
* **lab:** wait for Patroni to name a Sync Standby before cutting it ([#38](https://github.com/msavdert/obenhub/issues/38)) ([2d9245b](https://github.com/msavdert/obenhub/commit/2d9245b0c7808117775652e9e7d79658a8a3c49e))
* **lab:** widen the snapshot scope, fix slot retention on standbys, monitor app in slice1 ([#30](https://github.com/msavdert/obenhub/issues/30)) ([03183d1](https://github.com/msavdert/obenhub/commit/03183d19fedcdcc6dc7b6c7245278e5747173caf))


### Performance

* **lab:** measure Collector overhead with the current pack and a CPU-saturated arm ([#37](https://github.com/msavdert/obenhub/issues/37)) ([1be1361](https://github.com/msavdert/obenhub/commit/1be13616bcf4f20e1cc996a881b97b25ecbe5b19))


### Documentation

* **adr:** choose pgBackRest with a pg_basebackup comparison, plan PostgreSQL 19 next to 18 ([#48](https://github.com/msavdert/obenhub/issues/48)) ([5818981](https://github.com/msavdert/obenhub/commit/58189812aa98948015dffe3ab5f6344def3344cb))
* **adr:** record Collector topology, scraped endpoints, packs and MetricsQL ([#20](https://github.com/msavdert/obenhub/issues/20)) ([1a14d7f](https://github.com/msavdert/obenhub/commit/1a14d7ff4ddfaf7c880b15f0c6201e72c79c7902))
* correct stale lab and roadmap text, record the next steps and the accepted gaps ([#40](https://github.com/msavdert/obenhub/issues/40)) ([c12e353](https://github.com/msavdert/obenhub/commit/c12e3536c77f59b912b86d6187f2e33da8d908b2))
* every change through a PR, releases only at milestones ([#19](https://github.com/msavdert/obenhub/issues/19)) ([820e4a1](https://github.com/msavdert/obenhub/commit/820e4a14d537031f129cce513edec602bd31f02e))
* reduce the roadmap to open items and record the hardening pass ([#25](https://github.com/msavdert/obenhub/issues/25)) ([7952167](https://github.com/msavdert/obenhub/commit/7952167f42dd09fbc3eac9e14374d98ae941dd9d))
* replace "nothing runs yet" with a lab status list ([#18](https://github.com/msavdert/obenhub/issues/18)) ([e2adf20](https://github.com/msavdert/obenhub/commit/e2adf2002a597bb13318336c5dc3d1cb437eee4d))
* **roadmap:** plan stage 4, CloudNativePG on kind ([716c1fb](https://github.com/msavdert/obenhub/commit/716c1fb08f7851208148c9b4318d436b5992538d))
* **roadmap:** tick the stage 4 Collector item ([0d2d0e4](https://github.com/msavdert/obenhub/commit/0d2d0e4f5d1428d68238a155bbd078b17f6e3d33))
* **roadmap:** tick the stage 4 kind lab item ([604d8d5](https://github.com/msavdert/obenhub/commit/604d8d5d926c7627421b072646ae8a207f5a6f63))

## [0.13.0](https://github.com/msavdert/obenhub/compare/v0.12.0...v0.13.0) (2026-11-11)


### Features

* **lab:** add a host pack with filesystem and memory alerts and their pgha fault scenarios ([7e01fae](https://github.com/msavdert/obenhub/commit/7e01faec554701b557a6a18961e24d728f2129bd))
* **lab:** add network partition scenarios and a HostRebooted alert on pgha ([43ce10d](https://github.com/msavdert/obenhub/commit/43ce10d4a04fcbda8fda67b92768cdbaa666aafc))
* **lab:** add the pgha leader-killed scenario (Patroni frozen, watchdog reset) ([76a86ba](https://github.com/msavdert/obenhub/commit/76a86bad57823ed30171a59021cdafe9736a7f32))

## [0.12.0](https://github.com/msavdert/obenhub/compare/v0.11.0...v0.12.0) (2026-11-10)


### Features

* **lab:** carry the stage 3 fault scenarios over to the pgha VMs ([13a02f5](https://github.com/msavdert/obenhub/commit/13a02f520660aa5857498bafc6e23348d30f9f89))

## [0.11.0](https://github.com/msavdert/obenhub/compare/v0.10.0...v0.11.0) (2026-11-10)


### Features

* **lab:** add the slot-invalidated scenario and move ReplicationSlotInvalidated to the PostgreSQL pack ([c251158](https://github.com/msavdert/obenhub/commit/c251158889cd571ffc92115bd83dc6cd4125fdc2))

## [0.10.0](https://github.com/msavdert/obenhub/compare/v0.9.0...v0.10.0) (2026-11-10)


### Features

* **lab:** make CollectorAbsent per Collector ([9cf6e60](https://github.com/msavdert/obenhub/commit/9cf6e60cc4cfbb4f4ed2f9e4524f571f9edbf160))

## [0.9.0](https://github.com/msavdert/obenhub/compare/v0.8.0...v0.9.0) (2026-11-09)


### Features

* **lab:** per-node Collectors and an mTLS gateway backend for the pgha VMs ([8c8bd3f](https://github.com/msavdert/obenhub/commit/8c8bd3f625981b9538f2e5f48d9c04ccd37c7db2))

## [0.8.0](https://github.com/msavdert/obenhub/compare/v0.7.0...v0.8.0) (2026-11-09)


### Features

* **lab:** etcd, PostgreSQL 18 and Patroni with TLS on three Debian VMs ([8730c38](https://github.com/msavdert/obenhub/commit/8730c381f2ee9a1a83949d2ed0a857dca40a7524))


### Bug fixes

* **lab:** reload alerting config before each stage 3 scenario ([e1575a3](https://github.com/msavdert/obenhub/commit/e1575a37a178eb1b3ade014484a8579f7ddbb92c))

## [0.7.0](https://github.com/msavdert/obenhub/compare/v0.6.0...v0.7.0) (2026-11-09)


### Features

* **lab:** PgBouncer pool, client-limit and wait-time alerts ([a4361d9](https://github.com/msavdert/obenhub/commit/a4361d91eb721277827c6980378301bbb0b1f07c))

## [0.6.0](https://github.com/msavdert/obenhub/compare/v0.5.0...v0.6.0) (2026-11-08)


### Features

* **lab:** PostgreSQL health signals and two-tier capacity alerts ([52aa86e](https://github.com/msavdert/obenhub/commit/52aa86ee6a4cddc81e600fcceec7314b9807d3d1))


### Documentation

* **roadmap:** plan stage 5 as one short session per cloud provider ([ed9cc18](https://github.com/msavdert/obenhub/commit/ed9cc189b6089f64fbb5ea6e19765821a3ec257f))

## [0.5.0](https://github.com/msavdert/obenhub/compare/v0.4.0...v0.5.0) (2026-11-08)


### Features

* **lab:** monitor etcd and Patroni failsafe in the stage 3 lab ([3c91995](https://github.com/msavdert/obenhub/commit/3c919952f055dc15931996ad819f3d5131ccb5d4))

## [0.4.0](https://github.com/msavdert/obenhub/compare/v0.3.0...v0.4.0) (2026-11-07)


### Features

* **lab:** add the stage 3 Patroni lab ([8a666d5](https://github.com/msavdert/obenhub/commit/8a666d52f0c53ef93139d66569f66f01887c73d6))
* **lab:** measure OBI v1.0.0 against PostgreSQL and PgBouncer ([8d7de00](https://github.com/msavdert/obenhub/commit/8d7de00537af9a8255caf27ba7c06b426780c060))

## [0.3.0](https://github.com/msavdert/obenhub/compare/v0.2.0...v0.3.0) (2026-11-07)


### Features

* **lab:** monitor logical replication in the stage 2 lab ([856ac8d](https://github.com/msavdert/obenhub/commit/856ac8ded45cb2d925f110ee3c0349811a7c928a))
* **lab:** monitor PgBouncer in the stage 2 lab ([fcdf4cc](https://github.com/msavdert/obenhub/commit/fcdf4ccd77051a19db677eeaf11155fbba9d7ea2))


### Documentation

* **roadmap:** plan one OBI experiment after the PgBouncer step ([e65960e](https://github.com/msavdert/obenhub/commit/e65960e3fdb105216a50b7237d2fadc50aa02373))

## [0.2.0](https://github.com/msavdert/obenhub/compare/v0.1.0...v0.2.0) (2026-11-07)


### Features

* **lab:** fault scenarios, no-fault control and Grafana dashboard for slice 1 ([8531b09](https://github.com/msavdert/obenhub/commit/8531b094982fef7a7eaebcf32c9a867ba1b6c219))
* **lab:** first slice lab with PostgreSQL 18, Collector, Victoria stack and alerting ([00656c1](https://github.com/msavdert/obenhub/commit/00656c1153deeeff4944e8761598e86d87b0200a))
* **lab:** measure Collector overhead on pg-lab; keep passwords out of pg_stat_statements ([39f9fee](https://github.com/msavdert/obenhub/commit/39f9fee7a0515fbd8dc845feb1e219d406858caa))


### Documentation

* **adr:** narrow the first slice after an external review ([525cad9](https://github.com/msavdert/obenhub/commit/525cad9fb8644da9bf93ff0987c6b38e53eed6dc))

## 0.1.0 (2026-11-06)


### Bug fixes

* **release:** start the first release at 0.1.0 ([ee1d493](https://github.com/msavdert/obenhub/commit/ee1d493231051b9dcf8762208a83a6a438798933))


### Documentation

* record goal, architecture, receiver strategy and licence decisions ([faeef70](https://github.com/msavdert/obenhub/commit/faeef7056c4e47df756733d53aaff9420de68260))
