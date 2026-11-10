# Changelog

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
