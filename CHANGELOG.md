# Changelog

## [0.19.0](https://github.com/msavdert/obenhub/compare/v0.18.0...v0.19.0) (2026-11-24)


### ⚠ BREAKING CHANGES

* **slice1:** run the slice1 lab on postgresql 19 ([#166](https://github.com/msavdert/obenhub/issues/166))

### Features

* **oracle:** check the oracledb receiver against CDB26 ([#165](https://github.com/msavdert/obenhub/issues/165)) ([0ab2dee](https://github.com/msavdert/obenhub/commit/0ab2dee92ae536640ae74b111d68d6e494fa8561))
* **packs:** read the subscription counters on postgresql 15 to 19 ([#164](https://github.com/msavdert/obenhub/issues/164)) ([3be64fe](https://github.com/msavdert/obenhub/commit/3be64fe0b6969449945fa043168aa35191ca8ff2))
* **packs:** run the oracle pack SQL on 19c release updates and 26ai ([#163](https://github.com/msavdert/obenhub/issues/163)) ([98ad710](https://github.com/msavdert/obenhub/commit/98ad71076c8d7def38af918721c22fc801c70911))
* **packs:** run the postgresql pack SQL on every supported major ([#160](https://github.com/msavdert/obenhub/issues/160)) ([2d1ed72](https://github.com/msavdert/obenhub/commit/2d1ed723c598a17bec09fbaeab604ce176b14a6d))
* **slice1:** run the slice1 lab on postgresql 19 ([#166](https://github.com/msavdert/obenhub/issues/166)) ([562a6a1](https://github.com/msavdert/obenhub/commit/562a6a1bbd02f447d9d6db187ec1b018117995a3))


### Documentation

* **lab:** evidence for slice1, stage3, k8s and pgha after [#160](https://github.com/msavdert/obenhub/issues/160) ([#161](https://github.com/msavdert/obenhub/issues/161)) ([8751110](https://github.com/msavdert/obenhub/commit/8751110bc7bd9607454b70c25eef80a61415d563))
* **roadmap:** C2 done after the pgha rebuild ([#158](https://github.com/msavdert/obenhub/issues/158)) ([8907785](https://github.com/msavdert/obenhub/commit/890778509a1792d86ed7de9210fcfd4a92e048fd))
* **roadmap:** tick E2, E3 and E4 with the suites of 2026-11-24 ([#167](https://github.com/msavdert/obenhub/issues/167)) ([dce28ca](https://github.com/msavdert/obenhub/commit/dce28caed3cdada631810aa31393cc18247d9f1f))

## [0.18.0](https://github.com/msavdert/obenhub/compare/v0.17.0...v0.18.0) (2026-11-23)


### Features

* **deploy:** compose backend and gateway, host Collector and Helm values outside the lab (D1) ([#140](https://github.com/msavdert/obenhub/issues/140)) ([bd8e686](https://github.com/msavdert/obenhub/commit/bd8e686cdaa43a333c49261824cbf029a417f6b1))
* **lab:** inventories generated from a per-lab target list (C7) ([#137](https://github.com/msavdert/obenhub/issues/137)) ([6625ec0](https://github.com/msavdert/obenhub/commit/6625ec0b80fa115cb20b5e4ced5fb96f603df28f))
* **lab:** map changes to the scenarios they can affect (A2) ([#119](https://github.com/msavdert/obenhub/issues/119)) ([77cc952](https://github.com/msavdert/obenhub/commit/77cc952473d88674a48fafa745282aed1db5add2))
* **lab:** pgha and oracle read their addresses from untracked files (D4) ([#143](https://github.com/msavdert/obenhub/issues/143)) ([2eabe0c](https://github.com/msavdert/obenhub/commit/2eabe0c73ecbc3ea4a35c1a5f6066d1c49fc8d49))
* **packs:** collection interval stated per pack, CollectionIntervalTooLong rules (C5) ([#134](https://github.com/msavdert/obenhub/issues/134)) ([51a1742](https://github.com/msavdert/obenhub/commit/51a1742a0faca43648dbd4cc432b349c5437bef2))
* **packs:** description and runbook_url on every alert, runbooks for scenario-fired alerts (C6) ([#135](https://github.com/msavdert/obenhub/issues/135)) ([872e511](https://github.com/msavdert/obenhub/commit/872e51136df5e8fca21d46cc6d997883d0ec01e3))
* **packs:** one Collector fragment per pack, checked against the labs by lint:otelcol (C7) ([#138](https://github.com/msavdert/obenhub/issues/138)) ([f9fc8b6](https://github.com/msavdert/obenhub/commit/f9fc8b6274325d921f00f63e0f317d9caa8e9c93))
* **packs:** production threshold defaults with per-lab override series (C4) ([#139](https://github.com/msavdert/obenhub/issues/139)) ([3584feb](https://github.com/msavdert/obenhub/commit/3584feb6bf2d836e4041b67285372a0192767930))


### Bug fixes

* **k8s:** up.sh waits for the CNPG webhook and a healthy Cluster ([#153](https://github.com/msavdert/obenhub/issues/153)) ([8037e39](https://github.com/msavdert/obenhub/commit/8037e39edb8d63a0a4188afd4f1fd79df5562645))
* **k8s:** worker-stopped waits for its allowed PostgresSeriesVanished ([#156](https://github.com/msavdert/obenhub/issues/156)) ([4510722](https://github.com/msavdert/obenhub/commit/4510722d81f1b00c1a25c1eacbdc4a7246b46d49))
* **lab:** evidence check counts later failures and requires control last ([#118](https://github.com/msavdert/obenhub/issues/118)) ([181471c](https://github.com/msavdert/obenhub/commit/181471c598c0bb2d0987e12e6d240b9ac9441543))
* **lab:** harness checks running images, covers gaps between scenarios, proves the sinks (B3) ([#128](https://github.com/msavdert/obenhub/issues/128)) ([3bbd2be](https://github.com/msavdert/obenhub/commit/3bbd2bed36398498c9bd9a29afad289f746e8ac5))
* **lab:** name the node in KubernetesNodeNotReady; collect database app (B2) ([#126](https://github.com/msavdert/obenhub/issues/126)) ([e57f30f](https://github.com/msavdert/obenhub/commit/e57f30fda724cc9847907c586d3cc3cfeb8200fa))
* **lab:** slice1 uses the shared Alertmanager config without inhibit rules (B4) ([#127](https://github.com/msavdert/obenhub/issues/127)) ([b225a60](https://github.com/msavdert/obenhub/commit/b225a609cd78e62974ced20d1ee1ce2538a5cbce))
* **mon:** victoriametrics-metrics-datasource back to 1.0.1 ([#146](https://github.com/msavdert/obenhub/issues/146)) ([4f6f8a9](https://github.com/msavdert/obenhub/commit/4f6f8a914b5d5c1c9f2f04f03518b9a8e4b13c0a))
* **oracle:** fsfo-failover allows OracleBackupFailed of the promoted standby ([#147](https://github.com/msavdert/obenhub/issues/147)) ([e7a36bd](https://github.com/msavdert/obenhub/commit/e7a36bdfd1216bbc509e9fc7547c3d60410de301))
* **oracle:** primary-changed ignores demotions; backup kinds, gateway, pools (B1) ([#123](https://github.com/msavdert/obenhub/issues/123)) ([4ac9423](https://github.com/msavdert/obenhub/commit/4ac942364c8441eb1264b6d141fe2a53d6b1cb61))
* **oracle:** processes-exhausted keeps the instance exhausted while the fault is held ([#148](https://github.com/msavdert/obenhub/issues/148)) ([c0e174e](https://github.com/msavdert/obenhub/commit/c0e174e37fa6ba8cbd12ec6af4c1a7c3a7e04eab))
* **renovate:** hold back kind and kubectl minors by package name (A4) ([#121](https://github.com/msavdert/obenhub/issues/121)) ([bfa6ee9](https://github.com/msavdert/obenhub/commit/bfa6ee9a2d7ac52784a6a6dd5f7dbe6b6a9bfe0b))
* **scripts:** harness self-tests do not ask for lab suites ([#155](https://github.com/msavdert/obenhub/issues/155)) ([531d74c](https://github.com/msavdert/obenhub/commit/531d74c3280dc94a8fed9dc6cef8f5e385dc0486))


### Documentation

* **adr:** ADR 0005 amendment, a pack holds a Collector fragment (C7) ([#136](https://github.com/msavdert/obenhub/issues/136)) ([887e63d](https://github.com/msavdert/obenhub/commit/887e63d3347f4521978361398a9071259485c2e1))
* **adr:** ADR 0006 amendment, target identity is cluster plus instance (C3) ([#132](https://github.com/msavdert/obenhub/issues/132)) ([86654c6](https://github.com/msavdert/obenhub/commit/86654c6db971ef5ff18e99e51b6620e98db60f55))
* fix documents that drifted and check the site navigation (A3) ([#120](https://github.com/msavdert/obenhub/issues/120)) ([6b20ea1](https://github.com/msavdert/obenhub/commit/6b20ea1a77b52fb30625091ee939c2fd34fb5c9f))
* **guides:** quick start on slice1 and install guide, timed on a clean VM (D3) ([#144](https://github.com/msavdert/obenhub/issues/144)) ([f2cda71](https://github.com/msavdert/obenhub/commit/f2cda7177b393e7f7f95748e809262d23b79a587))
* **lab:** evidence of the B and C chain of 2026-11-22 ([#149](https://github.com/msavdert/obenhub/issues/149)) ([b32cdb7](https://github.com/msavdert/obenhub/commit/b32cdb7e7877db3a63bf466820f5591991b22757))
* **lab:** k8s evidence after [#153](https://github.com/msavdert/obenhub/issues/153) and [#156](https://github.com/msavdert/obenhub/issues/156) ([#157](https://github.com/msavdert/obenhub/issues/157)) ([ceb1370](https://github.com/msavdert/obenhub/commit/ceb1370b44ef2ec79c5bfbb9b1efa85e33063e33))
* **lab:** pgha evidence after the C2 wipe and rebuild ([#154](https://github.com/msavdert/obenhub/issues/154)) ([4a37df6](https://github.com/msavdert/obenhub/commit/4a37df6a3b568f364e63a312cd8b4ae7d14ae20f))
* **lab:** record the oracle suite after B1 ([#124](https://github.com/msavdert/obenhub/issues/124)) ([cd8c2fc](https://github.com/msavdert/obenhub/commit/cd8c2fc9524b28602bdb7587f8959a224362adb4))
* **oracle:** lab evidence for the oracledbreceiver role refresh fix ([#142](https://github.com/msavdert/obenhub/issues/142)) ([af2d886](https://github.com/msavdert/obenhub/commit/af2d886a05ed7e23b046f8ca606106760363204a))
* **roadmap:** order after the 0.17.0 review, packs out of the lab first ([#116](https://github.com/msavdert/obenhub/issues/116)) ([93257fc](https://github.com/msavdert/obenhub/commit/93257fcbdde9169e3280c50edb2c5dc7efa1fbab))
* **roadmap:** place the ideas from the dasha review in C5, F1 and F5 ([#125](https://github.com/msavdert/obenhub/issues/125)) ([c4edb40](https://github.com/msavdert/obenhub/commit/c4edb4086e10fb4508ba158e4c78ac00e9fd8d4d))

## [0.17.0](https://github.com/msavdert/obenhub/compare/v0.16.1...v0.17.0) (2026-11-19)


### Features

* **lab:** pgBackRest page checksum alert and backup-checksum-error scenario in slice1 ([#108](https://github.com/msavdert/obenhub/issues/108)) ([c4aea14](https://github.com/msavdert/obenhub/commit/c4aea14fffffe8378bed401761095edc64ae89c3))
* **scripts:** tiered lab evidence, affected scenarios per change and a full suite before a release ([#110](https://github.com/msavdert/obenhub/issues/110)) ([8ed2eaa](https://github.com/msavdert/obenhub/commit/8ed2eaaad08257e630367ea21f821ea026cfde18))


### Bug fixes

* **lab:** per-lab etcd disk latency thresholds over the upstream defaults ([#113](https://github.com/msavdert/obenhub/issues/113)) ([e47dc14](https://github.com/msavdert/obenhub/commit/e47dc1442cb2f501c8f29e1a1acfdb483cdd84ee))
* **lab:** slot-invalidated waits for checkpoint headroom after pausing the backups ([#111](https://github.com/msavdert/obenhub/issues/111)) ([095fdc1](https://github.com/msavdert/obenhub/commit/095fdc1e32ab3e2e879e720b8eeb6709fd50558a))


### Documentation

* **lab:** record the full five-lab suite chain before release 0.17.0 ([#115](https://github.com/msavdert/obenhub/issues/115)) ([1443560](https://github.com/msavdert/obenhub/commit/14435604352143a5eb816395912a4607d61dfa6d))
* **lab:** record the slice1 backup-stage suite and close the backup roadmap items ([#112](https://github.com/msavdert/obenhub/issues/112)) ([37e22f2](https://github.com/msavdert/obenhub/commit/37e22f2a47410d9d823f5dadb2d1035da9efd9d7))
* **roadmap:** usable outside the lab, after PostgreSQL 19 ([#114](https://github.com/msavdert/obenhub/issues/114)) ([020cffc](https://github.com/msavdert/obenhub/commit/020cffc47848422aa6c7168065354daf37f231ef))

## [0.16.1](https://github.com/msavdert/obenhub/compare/v0.16.0...v0.16.1) (2026-11-17)


### Bug fixes

* **lab:** pgha provision restarts etcd and PostgreSQL on a version-only change ([#102](https://github.com/msavdert/obenhub/issues/102)) ([d12e45d](https://github.com/msavdert/obenhub/commit/d12e45d5e627bce1ef31a7d26e69b16872954b2f))
* **lab:** slot-invalidated issues a second CHECKPOINT when the first leaves the slot unreserved ([#104](https://github.com/msavdert/obenhub/issues/104)) ([0215a43](https://github.com/msavdert/obenhub/commit/0215a43c65e9d72a1d5e4cb9bc63fcb59d51ab7e))
* **lab:** stage3 client load at 20 tps so its fsyncs do not trip EtcdHighCommitDurations ([#105](https://github.com/msavdert/obenhub/issues/105)) ([0748a86](https://github.com/msavdert/obenhub/commit/0748a86793cc17f520fa013fa8809468de442396))


### Documentation

* **lab:** record the update-wave suite chain and close the roadmap item ([#107](https://github.com/msavdert/obenhub/issues/107)) ([1b3339e](https://github.com/msavdert/obenhub/commit/1b3339efdb6bd60e15eaed0133a4fa6833e0e9c9))
* **roadmap:** homelab as a long-running target, after the stages close ([#106](https://github.com/msavdert/obenhub/issues/106)) ([d32156d](https://github.com/msavdert/obenhub/commit/d32156d13319a9723af9dc6988e6fc6dc7267eae))

## [0.16.0](https://github.com/msavdert/obenhub/compare/v0.15.0...v0.16.0) (2026-11-16)


### Features

* **lab:** Oracle backup-failed and backup-stale scenarios (ADR 0008 decision 8) ([#81](https://github.com/msavdert/obenhub/issues/81)) ([b3bc7f1](https://github.com/msavdert/obenhub/commit/b3bc7f112c3ff95cf17bce858095c1dc80633145))
* **lab:** Oracle dashboard panels for the password-expired and archiver-stuck signals ([#87](https://github.com/msavdert/obenhub/issues/87)) ([396a67f](https://github.com/msavdert/obenhub/commit/396a67fca4f1e04951bffb0068bfb97a73c8fd9d))
* **lab:** Oracle fsfo-failover scenario, open-mode gate on primary-count rules (ADR 0008 decision 8) ([#84](https://github.com/msavdert/obenhub/issues/84)) ([36d7054](https://github.com/msavdert/obenhub/commit/36d7054ccd73c87a22cd76ffe2f4fe4532846afd))
* **lab:** slice1 dashboard panels for xid age, idle transactions, locks, deadlocks, checkpoints and a slot-retaining-wal scenario ([#88](https://github.com/msavdert/obenhub/issues/88)) ([ecbc813](https://github.com/msavdert/obenhub/commit/ecbc813a6a8ce0ad95a0ee5c5f41c181b76910df))


### Bug fixes

* **lab:** Oracle fsfo-failover allows OracleBackupStale for the promoted standby ([#90](https://github.com/msavdert/obenhub/issues/90)) ([971f256](https://github.com/msavdert/obenhub/commit/971f2565d96ac9833f97ae47a2881d22693cd7c8))
* **lab:** Oracle restore-roles restores missing archived logs when reinstatement fails (ORA-38761) ([#89](https://github.com/msavdert/obenhub/issues/89)) ([8b89246](https://github.com/msavdert/obenhub/commit/8b892462bd54ad4bff9c34d155ae830a9b93ef02))


### Documentation

* close the Oracle first slice (ADR 0008) ([#92](https://github.com/msavdert/obenhub/issues/92)) ([c308d7c](https://github.com/msavdert/obenhub/commit/c308d7c2196020fc2df753f95f5223227e677387))

## [0.15.0](https://github.com/msavdert/obenhub/compare/v0.14.0...v0.15.0) (2026-11-15)


### Features

* **lab:** alert rules for the Oracle Data Guard pack ([#63](https://github.com/msavdert/obenhub/issues/63)) ([b44cb75](https://github.com/msavdert/obenhub/commit/b44cb75844d679234844c3f6b4a09850082cf78a))
* **lab:** Collector on every Oracle VM with host metrics, journald and alert logs ([#67](https://github.com/msavdert/obenhub/issues/67)) ([1a20159](https://github.com/msavdert/obenhub/commit/1a20159a542e8b1bd7e916741cf54b2a55d68c17))
* **lab:** Collector on ora-dg-obs and the oracledb role-staleness record ([#61](https://github.com/msavdert/obenhub/issues/61)) ([ea721e2](https://github.com/msavdert/obenhub/commit/ea721e26c80517c6ce3be57512645ec891e74ba5))
* **lab:** first Oracle fault scenarios on the CDB19 Data Guard pair ([#64](https://github.com/msavdert/obenhub/issues/64)) ([421c06b](https://github.com/msavdert/obenhub/commit/421c06b161ebe39c5276f96696bd4a34a6a7c55f))
* **lab:** Oracle archiver-stuck scenario, local archive destinations in the DG pack (ADR 0008 decision 8) ([#79](https://github.com/msavdert/obenhub/issues/79)) ([5a2f653](https://github.com/msavdert/obenhub/commit/5a2f6535ef7fd85c77164d0c7d38d43a347823b2))
* **lab:** Oracle blocking-session scenario and lock wait alert (ADR 0008 decision 8) ([#77](https://github.com/msavdert/obenhub/issues/77)) ([660e5c8](https://github.com/msavdert/obenhub/commit/660e5c8f18a2d785496b86571cc9bd76d655bb24))
* **lab:** Oracle Data Guard dashboard ([#65](https://github.com/msavdert/obenhub/issues/65)) ([285b034](https://github.com/msavdert/obenhub/commit/285b0343d0776d9ed12352daed62fa99d2def020))
* **lab:** Oracle first slice - monitoring users, Collector config and Data Guard pack ([#58](https://github.com/msavdert/obenhub/issues/58)) ([4527b28](https://github.com/msavdert/obenhub/commit/4527b28a876cd123be8f34ae61f23c6f0aac2688))
* **lab:** Oracle listener probe with tcp_check (ADR 0008 decision 7) ([#69](https://github.com/msavdert/obenhub/issues/69)) ([147f481](https://github.com/msavdert/obenhub/commit/147f481abc7dee7bc691be671bb18f14c53198a7))
* **lab:** Oracle listener-stopped scenario (ADR 0008 decision 8) ([#70](https://github.com/msavdert/obenhub/issues/70)) ([a66dbe3](https://github.com/msavdert/obenhub/commit/a66dbe37dd383bd5192192fe81e4b494cd2a9f17))
* **lab:** Oracle monitoring backend with a shared mutual-TLS gateway ([#60](https://github.com/msavdert/obenhub/issues/60)) ([c250baa](https://github.com/msavdert/obenhub/commit/c250baae83bce302b0154bd8d077a2ff2f3c4e19))
* **lab:** Oracle password-expired scenario and monitoring account alert (ADR 0008 decision 8) ([#71](https://github.com/msavdert/obenhub/issues/71)) ([09ab75d](https://github.com/msavdert/obenhub/commit/09ab75da2dfc7df158b3c174d883211c516b9861))
* **lab:** Oracle processes-exhausted scenario and saturation alert (ADR 0008 decision 8) ([#73](https://github.com/msavdert/obenhub/issues/73)) ([78c9b41](https://github.com/msavdert/obenhub/commit/78c9b41c4ba5ed5eca59d9acbba58c4bfcd3421e))
* **lab:** Oracle tablespace-full scenario and tablespace usage alert (ADR 0008 decision 8) ([#75](https://github.com/msavdert/obenhub/issues/75)) ([fd79f33](https://github.com/msavdert/obenhub/commit/fd79f33eb8562d35be19f9213e1105d43ba992e0))
* **lab:** pg_basebackup comparison scenario in slice1 ([#54](https://github.com/msavdert/obenhub/issues/54)) ([1172594](https://github.com/msavdert/obenhub/commit/1172594d242168a75d4bbade550d8c8062f8f125))
* **lab:** pgBackRest in slice1 with backup alerts, stale and PITR scenarios ([#51](https://github.com/msavdert/obenhub/issues/51)) ([b9bea94](https://github.com/msavdert/obenhub/commit/b9bea942a0edababead5ac5d3379fe7084c37ce6))
* **lab:** RMAN backups and backup monitoring for the CDB19 Data Guard pair ([#68](https://github.com/msavdert/obenhub/issues/68)) ([e8e8518](https://github.com/msavdert/obenhub/commit/e8e8518b9abd4876da57a3f1411d34d4359cc2ad))


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
