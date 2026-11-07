### A. pgbench in the window (latency includes schedule lag)

| cell | route | protocol | OBI | window s | txns | tps | avg ms | p50 ms | p95 ms | p99 ms | lag us | steal % | iowait % | OBI CPU s (whole run) | PostgreSQL CPU s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| bouncer-extended | bouncer | extended | on | 63 | 15636 | 249.0 | 25.05 | 10.26 | 110.02 | 361.07 | 13190 | 0.37 | 17.73 | 14.5 | 21.2 |
| bouncer-prepared | bouncer | prepared | on | 63 | 15323 | 244.2 | 31.09 | 9.67 | 156.91 | 528.13 | 19597 | 0.28 | 17.63 | 13.7 | 15.6 |
| bouncer-simple | bouncer | simple | on | 63 | 15789 | 251.0 | 16.26 | 9.56 | 36.22 | 194.68 | 5570 | 0.24 | 17.51 | 11.3 | 19.6 |
| direct-extended-obioff | direct | extended | off | 63 | 15519 | 248.0 | 14.24 | 7.96 | 25.94 | 227.04 | 5023 | 0.22 | 18.70 | 0.0 | 16.8 |
| direct-extended-tls | direct | extended tls | on | 63 | 15800 | 251.5 | 15.46 | 9.57 | 25.86 | 203.34 | 5119 | 0.39 | 16.93 | 5.9 | 32.8 |
| direct-extended | direct | extended | on | 63 | 15705 | 249.9 | 16.33 | 8.83 | 23.71 | 310.96 | 6583 | 0.17 | 18.20 | 7.1 | 20.6 |
| direct-prepared-late | direct | prepared | on | 63 | 14032 | 222.7 | 16443.22 | 16330.12 | 19576.37 | 20344.27 | 16407302 | 0.08 | 18.45 | 5.6 | 15.6 |
| direct-prepared | direct | prepared | on | 63 | 15624 | 249.7 | 10.61 | 8.02 | 19.61 | 51.53 | 1765 | 0.13 | 18.71 | 1.9 | 14.6 |
| direct-simple | direct | simple | on | 63 | 15830 | 252.2 | 55.19 | 9.98 | 326.19 | 941.12 | 42641 | 0.40 | 18.86 | 5.8 | 19.6 |

### B. Coverage: OBI statement counts vs what pgbench issued

Expected = pgbench transactions that completed after the service's window start x statements per transaction (UPDATE 3, SELECT 1, INSERT 1, BEGIN 1, END 1). Each cell shows OBI count / expected.

| cell | service | metric | window start s | UPDATE | SELECT | INSERT | BEGIN | END | other operations (count, mean ms) |
|---|---|---|---|---|---|---|---|---|---|
| bouncer-extended | pgbench | client | 17.3 | 46945 / 46908 (1.001) | 15648 / 15636 (1.001) | 15649 / 15636 (1.001) | 0 / 15636 (0.000) | 0 / 15636 (0.000) | - |
| bouncer-extended | pgbouncer | client | 15.2 | 48564 / 48543 (1.000) | 16188 / 16181 (1.000) | 16190 / 16181 (1.001) | 0 / 16181 (0.000) | 0 / 16181 (0.000) | - |
| bouncer-extended | pgbouncer | server | 15.2 | 48564 / 48543 (1.000) | 16188 / 16181 (1.000) | 16190 / 16181 (1.001) | 0 / 16181 (0.000) | 0 / 16181 (0.000) | - |
| bouncer-extended | postgres | server | 15.2 | 48564 / 48543 (1.000) | 16188 / 16181 (1.000) | 16188 / 16181 (1.000) | 0 / 16181 (0.000) | 0 / 16181 (0.000) | - |
| bouncer-prepared | pgbench | client | 17.3 | 46026 / 45969 (1.001) | 15342 / 15323 (1.001) | 15342 / 15323 (1.001) | 0 / 15323 (0.000) | 0 / 15323 (0.000) | PREPARED STATEMENT 30685, 5.05 |
| bouncer-prepared | pgbouncer | client | 15.2 | 47697 / 47604 (1.002) | 15899 / 15868 (1.002) | 15900 / 15868 (1.002) | 0 / 15868 (0.000) | 0 / 15868 (0.000) | PREPARED STATEMENT 31799, 4.36 |
| bouncer-prepared | pgbouncer | server | 15.2 | 47697 / 47604 (1.002) | 15899 / 15868 (1.002) | 15900 / 15868 (1.002) | 0 / 15868 (0.000) | 0 / 15868 (0.000) | PREPARED STATEMENT 31799, 4.94 |
| bouncer-prepared | postgres | server | 15.2 | 47696 / 47604 (1.002) | 15898 / 15868 (1.002) | 15900 / 15868 (1.002) | 0 / 15868 (0.000) | 0 / 15868 (0.000) | PREPARED STATEMENT 31799, 4.23 |
| bouncer-simple | pgbench | client | 17.2 | 47371 / 47367 (1.000) | 15790 / 15789 (1.000) | 15792 / 15789 (1.000) | 0 / 15789 (0.000) | 0 / 15789 (0.000) | - |
| bouncer-simple | pgbouncer | client | 15.2 | 48796 / 48777 (1.000) | 16265 / 16259 (1.000) | 16266 / 16259 (1.000) | 0 / 16259 (0.000) | 0 / 16259 (0.000) | - |
| bouncer-simple | pgbouncer | server | 15.2 | 48796 / 48777 (1.000) | 16265 / 16259 (1.000) | 16266 / 16259 (1.000) | 0 / 16259 (0.000) | 0 / 16259 (0.000) | - |
| bouncer-simple | postgres | server | 17.2 | 47371 / 47367 (1.000) | 15790 / 15789 (1.000) | 15791 / 15789 (1.000) | 0 / 15789 (0.000) | 0 / 15789 (0.000) | - |
| direct-extended-tls | pgbench | client | 17.3 | 47418 / 47400 (1.000) | 15806 / 15800 (1.000) | 15806 / 15800 (1.000) | 0 / 15800 (0.000) | 0 / 15800 (0.000) | - |
| direct-extended-tls | postgres | server | 17.5 | 16850 / 47262 (0.357) | 5363 / 15754 (0.340) | 5494 / 15754 (0.349) | 0 / 15754 (0.000) | 0 / 15754 (0.000) | - |
| direct-extended | pgbench | client | 17.2 | 47112 / 47115 (1.000) | 15704 / 15705 (1.000) | 15704 / 15705 (1.000) | 0 / 15705 (0.000) | 0 / 15705 (0.000) | - |
| direct-extended | postgres | server | 17.2 | 47111 / 47115 (1.000) | 15704 / 15705 (1.000) | 15704 / 15705 (1.000) | 0 / 15705 (0.000) | 0 / 15705 (0.000) | - |
| direct-prepared-late | pgbench | client | 17.1 | 42102 / 42096 (1.000) | 14031 / 14032 (1.000) | 14038 / 14032 (1.000) | 0 / 14032 (0.000) | 0 / 14032 (0.000) | PREPARED STATEMENT 28068, 2.19 |
| direct-prepared-late | postgres | server | 17.3 | 42074 / 41967 (1.003) | 14022 / 13989 (1.002) | 14028 / 13989 (1.003) | 0 / 13989 (0.000) | 0 / 13989 (0.000) | PREPARED STATEMENT 28049, 2.09 |
| direct-simple | pgbench | client | 17.3 | 47456 / 47490 (0.999) | 15818 / 15830 (0.999) | 15819 / 15830 (0.999) | 0 / 15830 (0.000) | 0 / 15830 (0.000) | - |
| direct-simple | postgres | server | 17.2 | 47576 / 47553 (1.000) | 15858 / 15851 (1.000) | 15859 / 15851 (1.001) | 0 / 15851 (0.000) | 0 / 15851 (0.000) | - |

### C. Per statement: pgbench -r (whole run) vs OBI mean (window), ms

OBI columns: client = db.client.operation.duration of service pgbench; server = db.server.operation.duration of service postgres; bouncer-in = db.server.operation.duration of service pgbouncer (client-facing side); bouncer-out = db.client.operation.duration of service pgbouncer.

| cell | statement | pgbench -r | OBI client | bouncer-in | bouncer-out | postgres server |
|---|---|---|---|---|---|---|
| bouncer-extended | BEGIN  | 1.258 | - | - | - | - |
| bouncer-extended | UPDATE pgbench_accounts | 0.401 | 0.393 (15648) | 0.301 (16188) | 0.285 (16188) | 0.188 (16188) |
| bouncer-extended | SELECT pgbench_accounts | 0.292 | 0.284 (15648) | 0.199 (16188) | 0.183 (16188) | 0.094 (16188) |
| bouncer-extended | UPDATE pgbench_tellers | 0.308 | 0.300 (15648) | 0.217 (16188) | 0.203 (16188) | 0.119 (16188) |
| bouncer-extended | UPDATE pgbench_branches | 0.388 | 0.391 (15649) | 0.309 (16188) | 0.294 (16188) | 0.209 (16188) |
| bouncer-extended | INSERT pgbench_history | 0.270 | 0.264 (15649) | 0.182 (16190) | 0.168 (16190) | 0.084 (16188) |
| bouncer-extended | END  | 8.555 | - | - | - | - |
| bouncer-prepared | BEGIN  | 1.282 | - | - | - | - |
| bouncer-prepared | UPDATE pgbench_accounts | 0.321 | 0.312 (15342) | 0.223 (15898) | 0.208 (15898) | 0.118 (15898) |
| bouncer-prepared | SELECT pgbench_accounts | 0.233 | 0.223 (15342) | 0.142 (15899) | 0.127 (15899) | 0.047 (15898) |
| bouncer-prepared | UPDATE pgbench_tellers | 0.250 | 0.241 (15342) | 0.164 (15899) | 0.150 (15899) | 0.072 (15899) |
| bouncer-prepared | UPDATE pgbench_branches | 0.327 | 0.325 (15342) | 0.251 (15900) | 0.237 (15900) | 0.160 (15899) |
| bouncer-prepared | INSERT pgbench_history | 0.216 | 0.208 (15342) | 0.135 (15900) | 0.121 (15900) | 0.047 (15900) |
| bouncer-prepared | END  | 8.473 | - | - | - | - |
| bouncer-simple | BEGIN  | 0.938 | - | - | - | - |
| bouncer-simple | UPDATE pgbench_accounts | 0.380 | 0.371 (15790) | 0.283 (16265) | 0.269 (16265) | 0.176 (15790) |
| bouncer-simple | SELECT pgbench_accounts | 0.274 | 0.264 (15790) | 0.182 (16265) | 0.167 (16265) | 0.082 (15790) |
| bouncer-simple | UPDATE pgbench_tellers | 0.280 | 0.270 (15790) | 0.192 (16265) | 0.179 (16265) | 0.098 (15790) |
| bouncer-simple | UPDATE pgbench_branches | 0.376 | 0.375 (15791) | 0.296 (16266) | 0.283 (16266) | 0.205 (15791) |
| bouncer-simple | INSERT pgbench_history | 0.246 | 0.238 (15792) | 0.161 (16266) | 0.148 (16266) | 0.068 (15791) |
| bouncer-simple | END  | 8.015 | - | - | - | - |
| direct-extended-tls | BEGIN  | 0.301 | - | - | - | - |
| direct-extended-tls | UPDATE pgbench_accounts | 0.403 | 0.351 (15806) | - | - | 1.041 (5886) |
| direct-extended-tls | SELECT pgbench_accounts | 0.294 | 0.239 (15806) | - | - | 0.453 (5363) |
| direct-extended-tls | UPDATE pgbench_tellers | 0.307 | 0.257 (15806) | - | - | 0.445 (5453) |
| direct-extended-tls | UPDATE pgbench_branches | 0.413 | 0.364 (15806) | - | - | 0.814 (5511) |
| direct-extended-tls | INSERT pgbench_history | 0.266 | 0.217 (15806) | - | - | 1.418 (5494) |
| direct-extended-tls | END  | 8.423 | - | - | - | - |
| direct-extended | BEGIN  | 0.186 | - | - | - | - |
| direct-extended | UPDATE pgbench_accounts | 0.287 | 0.277 (15704) | - | - | 0.187 (15703) |
| direct-extended | SELECT pgbench_accounts | 0.184 | 0.174 (15704) | - | - | 0.087 (15704) |
| direct-extended | UPDATE pgbench_tellers | 0.199 | 0.190 (15704) | - | - | 0.107 (15704) |
| direct-extended | UPDATE pgbench_branches | 0.311 | 0.313 (15704) | - | - | 0.233 (15704) |
| direct-extended | INSERT pgbench_history | 0.160 | 0.153 (15704) | - | - | 0.077 (15704) |
| direct-extended | END  | 8.313 | - | - | - | - |
| direct-prepared-late | BEGIN  | 0.117 | - | - | - | - |
| direct-prepared-late | UPDATE pgbench_accounts | 0.182 | 0.161 (14031) | - | - | 0.078 (14022) |
| direct-prepared-late | SELECT pgbench_accounts | 0.133 | 0.117 (14031) | - | - | 0.036 (14022) |
| direct-prepared-late | UPDATE pgbench_tellers | 11.952 | 11.903 (14034) | - | - | 11.803 (14024) |
| direct-prepared-late | UPDATE pgbench_branches | 19.207 | 19.120 (14037) | - | - | 19.012 (14028) |
| direct-prepared-late | INSERT pgbench_history | 0.148 | 0.143 (14038) | - | - | 0.050 (14028) |
| direct-prepared-late | END  | 4.304 | - | - | - | - |
| direct-prepared | BEGIN  | 0.169 | - | - | - | - |
| direct-prepared | UPDATE pgbench_accounts | 0.207 | - | - | - | - |
| direct-prepared | SELECT pgbench_accounts | 0.124 | - | - | - | - |
| direct-prepared | UPDATE pgbench_tellers | 0.144 | - | - | - | - |
| direct-prepared | UPDATE pgbench_branches | 0.217 | - | - | - | - |
| direct-prepared | INSERT pgbench_history | 0.110 | - | - | - | - |
| direct-prepared | END  | 7.954 | - | - | - | - |
| direct-simple | BEGIN  | 0.186 | - | - | - | - |
| direct-simple | UPDATE pgbench_accounts | 0.285 | 0.278 (15818) | - | - | 0.178 (15858) |
| direct-simple | SELECT pgbench_accounts | 0.186 | 0.175 (15818) | - | - | 0.079 (15858) |
| direct-simple | UPDATE pgbench_tellers | 0.212 | 0.211 (15819) | - | - | 0.122 (15859) |
| direct-simple | UPDATE pgbench_branches | 0.360 | 0.377 (15819) | - | - | 0.291 (15859) |
| direct-simple | INSERT pgbench_history | 0.152 | 0.145 (15819) | - | - | 0.065 (15859) |
| direct-simple | END  | 10.416 | - | - | - | - |

### D. Everything OBI reported in the window, by service, metric and operation (counts in window)

| cell | service | metric | operation | count | mean ms | p50 ms | p95 ms | instances | peers (server.address:server.port, db.namespace) |
|---|---|---|---|---|---|---|---|---|---|
| bouncer-extended | pgbench | client | UPDATE | 46945 | 0.361 | 0.289 | 0.499 | 1 | outgoing:6432,postgres x46945 |
| bouncer-extended | pgbench | client | INSERT | 15649 | 0.264 | 0.247 | 0.453 | 1 | outgoing:6432,postgres x15649 |
| bouncer-extended | pgbench | client | SELECT | 15648 | 0.284 | 0.261 | 0.475 | 1 | outgoing:6432,postgres x15648 |
| bouncer-extended | pgbouncer | client | UPDATE | 48564 | 0.261 | 0.194 | 0.445 | 1 | outgoing:, x48564 |
| bouncer-extended | pgbouncer | client | INSERT | 16190 | 0.168 | 0.155 | 0.269 | 1 | outgoing:, x16190 |
| bouncer-extended | pgbouncer | client | SELECT | 16188 | 0.183 | 0.161 | 0.287 | 1 | outgoing:, x16188 |
| bouncer-extended | pgbouncer | server | UPDATE | 48564 | 0.276 | 0.216 | 0.461 | 1 | pgbouncer:6432,postgres x48564 |
| bouncer-extended | pgbouncer | server | INSERT | 16190 | 0.182 | 0.160 | 0.286 | 1 | pgbouncer:6432,postgres x16190 |
| bouncer-extended | pgbouncer | server | SELECT | 16188 | 0.199 | 0.170 | 0.294 | 1 | pgbouncer:6432,postgres x16188 |
| bouncer-extended | postgres | server | UPDATE | 48564 | 0.172 | 0.132 | 0.270 | 5 | postgres:5432, x48564 |
| bouncer-extended | postgres | server | SELECT | 16188 | 0.094 | 0.068 | 0.184 | 5 | postgres:5432, x16188 |
| bouncer-extended | postgres | server | INSERT | 16188 | 0.084 | 0.057 | 0.162 | 5 | postgres:5432, x16188 |
| bouncer-prepared | pgbench | client | UPDATE | 46026 | 0.293 | 0.241 | 0.468 | 1 | outgoing:6432,postgres x46026 |
| bouncer-prepared | pgbench | client | PREPARED STATEMENT | 30685 | 5.051 | 3.931 | 14.144 | 1 | outgoing:6432,postgres x30685 |
| bouncer-prepared | pgbench | client | SELECT | 15342 | 0.223 | 0.212 | 0.329 | 1 | outgoing:6432,postgres x15342 |
| bouncer-prepared | pgbench | client | INSERT | 15342 | 0.208 | 0.182 | 0.298 | 1 | outgoing:6432,postgres x15342 |
| bouncer-prepared | pgbouncer | client | UPDATE | 47697 | 0.199 | 0.155 | 0.284 | 1 | outgoing:, x47697 |
| bouncer-prepared | pgbouncer | client | PREPARED STATEMENT | 31799 | 4.356 | 3.006 | 13.709 | 1 | outgoing:, x31799 |
| bouncer-prepared | pgbouncer | client | INSERT | 15900 | 0.121 | 0.121 | 0.196 | 1 | outgoing:, x15900 |
| bouncer-prepared | pgbouncer | client | SELECT | 15899 | 0.127 | 0.134 | 0.197 | 1 | outgoing:, x15899 |
| bouncer-prepared | pgbouncer | server | UPDATE | 47697 | 0.213 | 0.165 | 0.291 | 1 | pgbouncer:6432,postgres x47697 |
| bouncer-prepared | pgbouncer | server | PREPARED STATEMENT | 31799 | 4.936 | 3.807 | 14.066 | 1 | pgbouncer:6432,postgres x31799 |
| bouncer-prepared | pgbouncer | server | INSERT | 15900 | 0.135 | 0.140 | 0.198 | 1 | pgbouncer:6432,postgres x15900 |
| bouncer-prepared | pgbouncer | server | SELECT | 15899 | 0.142 | 0.147 | 0.199 | 1 | pgbouncer:6432,postgres x15899 |
| bouncer-prepared | postgres | server | UPDATE | 47696 | 0.117 | 0.067 | 0.184 | 5 | postgres:5432, x47696 |
| bouncer-prepared | postgres | server | PREPARED STATEMENT | 31799 | 4.230 | 2.129 | 13.612 | 5 | postgres:5432, x31799 |
| bouncer-prepared | postgres | server | INSERT | 15900 | 0.047 | 0.050 | 0.096 | 5 | postgres:5432, x15900 |
| bouncer-prepared | postgres | server | SELECT | 15898 | 0.047 | 0.050 | 0.096 | 5 | postgres:5432, x15898 |
| bouncer-simple | pgbench | client | UPDATE | 47371 | 0.339 | 0.275 | 0.488 | 1 | outgoing:6432,postgres x47371 |
| bouncer-simple | pgbench | client | INSERT | 15792 | 0.238 | 0.230 | 0.389 | 1 | outgoing:6432,postgres x15792 |
| bouncer-simple | pgbench | client | SELECT | 15790 | 0.264 | 0.252 | 0.452 | 1 | outgoing:6432,postgres x15790 |
| bouncer-simple | pgbouncer | client | UPDATE | 48796 | 0.243 | 0.181 | 0.409 | 1 | outgoing:,postgres x48796 |
| bouncer-simple | pgbouncer | client | INSERT | 16266 | 0.148 | 0.150 | 0.208 | 1 | outgoing:,postgres x16266 |
| bouncer-simple | pgbouncer | client | SELECT | 16265 | 0.167 | 0.156 | 0.265 | 1 | outgoing:,postgres x16265 |
| bouncer-simple | pgbouncer | server | UPDATE | 48796 | 0.257 | 0.191 | 0.436 | 1 | pgbouncer:6432,postgres x48796 |
| bouncer-simple | pgbouncer | server | INSERT | 16266 | 0.161 | 0.155 | 0.251 | 1 | pgbouncer:6432,postgres x16266 |
| bouncer-simple | pgbouncer | server | SELECT | 16265 | 0.182 | 0.162 | 0.284 | 1 | pgbouncer:6432,postgres x16265 |
| bouncer-simple | postgres | server | UPDATE | 47371 | 0.160 | 0.095 | 0.256 | 5 | postgres:5432,postgres x47371 |
| bouncer-simple | postgres | server | INSERT | 15791 | 0.068 | 0.052 | 0.099 | 5 | postgres:5432,postgres x15791 |
| bouncer-simple | postgres | server | SELECT | 15790 | 0.082 | 0.057 | 0.159 | 5 | postgres:5432,postgres x15790 |
| direct-extended-tls | pgbench | client | UPDATE | 47418 | 0.324 | 0.265 | 0.488 | 1 | outgoing:, x47418 |
| direct-extended-tls | pgbench | client | SELECT | 15806 | 0.239 | 0.238 | 0.416 | 1 | outgoing:, x15806 |
| direct-extended-tls | pgbench | client | INSERT | 15806 | 0.217 | 0.211 | 0.347 | 1 | outgoing:, x15806 |
| direct-extended-tls | postgres | server | UPDATE | 16850 | 0.774 | 0.183 | 0.741 | 8 | postgres:5432, x16850 |
| direct-extended-tls | postgres | server | INSERT | 5494 | 1.418 | 0.148 | 7.461 | 8 | postgres:5432, x5494 |
| direct-extended-tls | postgres | server | SELECT | 5363 | 0.453 | 0.158 | 0.541 | 8 | postgres:5432, x5363 |
| direct-extended | pgbench | client | UPDATE | 47112 | 0.260 | 0.191 | 0.423 | 1 | outgoing:, x47112 |
| direct-extended | pgbench | client | INSERT | 15704 | 0.153 | 0.153 | 0.230 | 1 | outgoing:, x15704 |
| direct-extended | pgbench | client | SELECT | 15704 | 0.174 | 0.159 | 0.275 | 1 | outgoing:, x15704 |
| direct-extended | postgres | server | UPDATE | 47111 | 0.176 | 0.116 | 0.266 | 8 | postgres:5432, x47111 |
| direct-extended | postgres | server | INSERT | 15704 | 0.077 | 0.054 | 0.125 | 8 | postgres:5432, x15704 |
| direct-extended | postgres | server | SELECT | 15704 | 0.087 | 0.060 | 0.171 | 8 | postgres:5432, x15704 |
| direct-prepared-late | pgbench | client | UPDATE | 42102 | 10.396 | 0.283 | 43.699 | 1 | outgoing:, x42102 |
| direct-prepared-late | pgbench | client | PREPARED STATEMENT | 28068 | 2.192 | 2.049 | 6.478 | 1 | outgoing:, x28068 |
| direct-prepared-late | pgbench | client | INSERT | 14038 | 0.143 | 0.149 | 0.198 | 1 | outgoing:, x14038 |
| direct-prepared-late | pgbench | client | SELECT | 14031 | 0.117 | 0.128 | 0.193 | 1 | outgoing:, x14031 |
| direct-prepared-late | postgres | server | UPDATE | 42074 | 10.299 | 0.178 | 43.582 | 8 | postgres:5432, x42074 |
| direct-prepared-late | postgres | server | PREPARED STATEMENT | 28049 | 2.087 | 2.003 | 6.409 | 8 | postgres:5432, x28049 |
| direct-prepared-late | postgres | server | INSERT | 14028 | 0.050 | 0.050 | 0.096 | 8 | postgres:5432, x14028 |
| direct-prepared-late | postgres | server | SELECT | 14022 | 0.036 | 0.050 | 0.095 | 8 | postgres:5432, x14022 |
| direct-simple | pgbench | client | UPDATE | 47456 | 0.289 | 0.184 | 0.438 | 1 | outgoing:, x47456 |
| direct-simple | pgbench | client | INSERT | 15819 | 0.145 | 0.149 | 0.231 | 1 | outgoing:, x15819 |
| direct-simple | pgbench | client | SELECT | 15818 | 0.175 | 0.159 | 0.293 | 1 | outgoing:, x15818 |
| direct-simple | postgres | server | UPDATE | 47576 | 0.197 | 0.089 | 0.260 | 8 | postgres:5432, x47576 |
| direct-simple | postgres | server | INSERT | 15859 | 0.065 | 0.052 | 0.098 | 8 | postgres:5432, x15859 |
| direct-simple | postgres | server | SELECT | 15858 | 0.079 | 0.055 | 0.145 | 8 | postgres:5432, x15858 |

### E. Indicative overhead pair: same cell with OBI off and on (pgbench -r, whole run, ms)

direct-extended-obioff (OBI off) vs direct-extended (OBI on); OBI CPU 7.1 s over 80 s = 8.9% of one core

| statement | off | on | on - off |
|---|---|---|---|
| BEGIN  | 0.134 | 0.186 | +0.052 |
| UPDATE pgbench_accounts | 0.254 | 0.287 | +0.033 |
| SELECT pgbench_accounts | 0.150 | 0.184 | +0.034 |
| UPDATE pgbench_tellers | 0.166 | 0.199 | +0.033 |
| UPDATE pgbench_branches | 0.268 | 0.311 | +0.043 |
| INSERT pgbench_history | 0.128 | 0.160 | +0.032 |
| END  | 8.088 | 8.313 | +0.225 |

### F. PgBouncer's own counters over the whole run (SHOW STATS deltas)

| cell | xacts | queries | mean query time us |
|---|---|---|---|
| bouncer-extended | 19962 | 139722 | 1524 |
| bouncer-prepared | 19616 | 137300 | 1475 |
| bouncer-simple | 20054 | 140366 | 1390 |
