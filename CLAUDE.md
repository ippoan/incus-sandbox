# CLAUDE.md (incus-sandbox)

worktree 単位で動く Incus dev サンドボックス。Docker を使わずに「Claude Code Web のような仮想環境」をローカルに用意するための shell + YAML だけで完結したオーケストレータ。

## 設計原則

- **1 worktree = 1 Incus project**。`.claude/worktrees/<name>/` ごとに独立した namespace を作る。並列 Claude / 並列 feature と同じ粒度で隔離
- **gateway 経由で host に 1 ポートだけ公開**。per-service の port forward はしない。`127.0.0.1:18080+N` の 1 個から gateway に流し込む
- **GHCR / Docker Hub 依存なし**。Incus 公式の `images:ubuntu/24.04` と `images:debian/12` を warm image にして再利用する
- **ビルドは Incus 内 builder instance + cache volume**。`target/` と `~/.cargo/registry` を Incus volume で永続化、cargo の incremental cache に乗せる
- **host の worktree を bind-mount**。host 側で git 操作 / vim / Claude Code CLI 全部できる。`/src/target` は volume が overlay するので host worktree の `target/` は触らない (= 副作用ゼロ)
- **frontend は触らない**。`/wt-quick` (Cloudflare Quick Tunnel + auth-worker KV) を継続。Incus の gateway proxy で `127.0.0.1:18080+N` に公開し、frontend の `NUXT_PUBLIC_API_BASE` をそこに向ける
- **postgres data は揮発**。staging Cloud Run の emptyDir と同じセマンティクス。`down.sh` で消えて毎回まっさら。`cargo target` は volume で残す (cold build を避けるため)

## ファイル構成と役割

| ディレクトリ / ファイル | 役割 |
|---|---|
| `bin/_lib.sh` | 全 script 共通の helper (logging / sanitize / port allocator / incus 確認) |
| `bin/init.sh` | 1 度だけのセットアップ。incus / yq / jq install + admin init + bridge + profile + warm image |
| `bin/build.sh` | builder instance で `cargo build --release --bins`、cache volume 利用 |
| `bin/up.sh` | mode (`solo <svc>` / `full`) に従って instance 起動、systemd unit inject、gateway proxy device で host に公開 |
| `bin/down.sh` | instance 停止削除 (`--purge` で volume + project 削除 + port 解放) |
| `bin/exec.sh` | `incus exec` のショートカット (`-- <cmd>` で one-shot) |
| `bin/port.sh` | worktree → host port の割当を表示 |
| `cloud-init/ubuntu-app.yaml` | warm image `incus-dev-warm` 用。devtools + rustup |
| `cloud-init/debian-postgres.yaml` | warm image `incus-dev-warm-pg` 用。postgresql-16 + dev 用 trust HBA |
| `profiles/*.yaml` | Incus profile 定義。base / app / postgres / gateway |
| `units/alc-service@.service.tmpl` | systemd template。`%i` に binary 名を入れて起動 |
| `units/alc-migrate@.service.tmpl` | service の前に DB migrate を 1 回だけ走らせる oneshot |
| `projects/<name>/manifest.yaml` | プロジェクト固有の service / port / env / depends_on |
| `allocations/ports.json` | worktree → host port 割当 (gitignored、`port_alloc()` が flock 排他更新) |

CI ワークフローはあえて入れていない (個人/小規模ツールで CI のメンテコストの方が重い)。

## 用語

| 用語 | 意味 |
|---|---|
| **project** | 対応する上流リポジトリ名 (`rust-alc-api` 等)。`projects/<project>/manifest.yaml` の所在 |
| **worktree (wt)** | git worktree 名。`.claude/worktrees/<wt>/` に対応 |
| **service** | manifest 上のキー (`backend` / `tenko` / `gateway` ...) |
| **binary** | `cargo build --bins` で生える ELF (`rust-alc-api` / `tenko-api` / ...) 。1 service が 1 binary を持つ |
| **incus project** | `alc-<sanitized-project>-<sanitized-wt>` の Incus 側 namespace |

## 命名規約

- Incus instance 名 ≒ manifest 上の service 名 (`backend`, `tenko`, `gateway`, `postgres`)
- DNS は Incus 内蔵が `<instance>.incus` で解決するので、env var の URL は `http://backend.incus:8081` の形で書く
- Volume 名: `cargo-target-<sanitized-project>-<sanitized-wt>` / `alc-pg-data-<sanitized-project>-<sanitized-wt>`
- Host port: `18080..18999` の範囲で sequential に採番 (`bin/port.sh` で確認可)

## manifest スキーマ (`projects/<name>/manifest.yaml`)

```yaml
project: <name>
worktree_root: <path-with-tilde>     # .claude/worktrees の親ディレクトリ
init_sql_path: <relative-path>       # postgres init 用 (現状未使用、将来用)
binaries: [<bin>, <bin>, ...]        # cargo build --release --bins で出るもの全部

postgres:
  warm_alias: incus-dev-warm-pg
  password: dev
  database: postgres
  schema: alc_api
  data_volume_prefix: alc-pg-data

services:
  <name>:
    binary: <binary-from-list-above>
    pre_start: migrate               # オプション、systemd oneshot として実行
    port: <int>                      # 内部 port (8081 等)
    depends_on: [<service>, ...]
    expose_to_host: true             # gateway だけに付ける
    env: { KEY: value, ... }

modes:
  solo: { instances: [postgres, "<arg>", gateway] }
  full: { instances: [postgres, backend, tenko, ...] }
```

`<arg>` は `solo` モード時に CLI で指定された service 名で置換される。

## 開発時の作法

### コード書くとき

- 気が向いたら `shellcheck bin/*.sh` をローカルで叩く程度。CI はあえて入れていない (個人ツール)
- **bash しか使わない**。`/bin/sh` 互換は気にしない。bash 4+ の前提
- **副作用のある操作は idempotent に**。同じコマンド 2 回打って同じ結果になること (volume 既存 / project 既存 / port 既存はスキップ)
- **`die` で abort、`info` / `ok` / `warn` で stderr に出す**。stdout は data 出力 (例: `port.sh`) のみ
- **port allocator は `flock` 必須**。並列実行時の race を避ける

### incus を直接叩く前に

- `_lib.sh` の helper を使う (`incus_project_exists`, `incus_volume_exists`, `incus_image_alias_exists`, `incus_instance_exists`, `wait_for_cloud_init`)
- 同じ判定を何度も書かない。helper が無ければ `_lib.sh` に追加

### 新しい project を追加するとき

1. `projects/<new>/manifest.yaml` を書く (rust-alc-api を雛形に)
2. `bin/up.sh <new> <worktree> full` で動作確認
3. README に対応プロジェクト表で 1 行追加

## やってはいけない

- **`incus exec` の中で `apt install` する script を勝手に書く**。warm image に焼くべき。`cloud-init/ubuntu-app.yaml` を編集して `bin/init.sh` の警告に従って image を rebuild する
- **systemd unit を bin/* の中で書きおこす**。テンプレを `units/` に置いて `incus file push` する
- **rust-alc-api repo にコードを書く**。orchestration はこの repo に閉じる。symlink 経由で参照されているだけ
- **secret を manifest に書く**。Cloud Run の secretKeyRef 相当はサポートしない (dev 用なので)。必要なら `up.sh` が `<worktree>/.env.local` を読んで env file に追記する形 (TODO)
- **port を hardcode**。常に `port_alloc()` で取得する

## トラブルシュート

| 症状 | 原因 / 対処 |
|---|---|
| `incus: command not found` | `sudo bash bin/init.sh` から始める。apt 自動 install する |
| `permission denied` on incus | `incus-admin` グループ未所属。`sudo usermod -aG incus-admin $USER && newgrp incus-admin` |
| `cloud-init not done` で timeout | warm image build 時。`incus exec <name>-tmp -- cloud-init status --long` で確認 |
| `EADDRINUSE` on host | `bin/port.sh` で他 worktree が同じ port 持ってないか / `ss -ltnp | grep 1808` |
| build がやたら遅い | builder instance を `--stop` で落としてないか。`--keep` (default) で常駐させた方が速い |
| postgres に繋がらない | `incus exec <project>/postgres -- pg_isready` 確認、cloud-init 完了マーカー (`/var/lib/incus-sandbox-pg-warm-ready`) 確認 |
| service が立ち上がらない | `bin/exec.sh <project> <wt> <svc> -- journalctl -u alc-service@<bin> -e` |

## 参考

- 元の設計プラン: `~/.claude/plans/github-app-staged-hejlsberg.md`
- 上流リポジトリ: https://github.com/ippoan/rust-alc-api
- staging 構成の正本: rust-alc-api/staging/cloudrun-staging.yaml (manifest はここから手動転記)
- Incus docs: https://linuxcontainers.org/incus/docs/main/
