# incus-sandbox

worktree 単位で動く Incus dev サンドボックス。Claude Code Web 的な「目的に応じて起動する隔離環境」を Docker なしでローカルに用意する。

## 何ができるか

- `.claude/worktrees/<name>/` ごとに 1 Incus project を生やし、その中で multi-service backend (gateway + 各 API + postgres) を起動
- worktree のソースは `/src` に bind-mount。host で `cargo build` するか、`bin/build.sh` でコンテナ内ビルド
- gateway の 8080 を host の `127.0.0.1:18080+N` に proxy device で公開、frontend (`/wt-quick`) からは普通の HTTP で繋がる
- `target/` と `~/.cargo/registry` を Incus volume にキャッシュ、再ビルドは差分のみ

## 対応プロジェクト

| project | manifest | 備考 |
|---|---|---|
| `rust-alc-api` | `projects/rust-alc-api/manifest.yaml` | gateway / app / tenko / carins / dtako + postgres。staging cloudrun-staging.yaml と等価 |

他プロジェクトは `projects/<name>/manifest.yaml` を追加すれば対応可能。

## 前提

- Linux ホスト (Ubuntu 24.04 で動作確認)
- `incus` 6.x 以上
- `git` / `gh`
- `yq` (manifest パース用、apt の `yq` ではなく Mike Farah 版 v4)
- 対応 worktree を `.claude/worktrees/<name>/` に作成済み (CLAUDE.md の `branch-switch-guard` ルールに従って `origin/main` から)

## 1 度だけのセットアップ

```bash
git clone https://github.com/ippoan/incus-sandbox ~/git/incus-sandbox
cd ~/git/incus-sandbox
sudo bash bin/init.sh
```

`bin/init.sh` がやること:

1. `incus` / `yq` の存在確認 (無ければ apt install)
2. `incus admin init --minimal`
3. ユーザーを `incus-admin` グループに追加
4. bridge `alcbr0` 作成、DNS `dns.mode=managed`
5. profile 4 種 (`alc-base` / `alc-app` / `alc-postgres` / `alc-gateway`) 作成
6. shared volume `cargo-registry` 作成
7. warm image `incus-dev-warm` (ubuntu/24.04 + cloud-init devtools + rustup) を build & publish
8. warm image `incus-dev-warm-pg` (debian/12 + postgresql-16) を build & publish

## 使い方

```bash
# 1. worktree 作成 (rust-alc-api 側)
cd ~/rust/rust-alc-api
git fetch origin main
git worktree add -b feat/foo .claude/worktrees/feat-foo origin/main

# 2. ビルドキャッシュを温める (初回のみ重い)
bash ~/git/incus-sandbox/bin/build.sh rust-alc-api feat-foo

# 3. サンドボックス起動 (full = gateway + app + tenko + carins + dtako + postgres)
bash ~/git/incus-sandbox/bin/up.sh rust-alc-api feat-foo full
# → "Backend ready at http://127.0.0.1:18080"

# 4. frontend は別 worktree + /wt-quick (既存)
cd ~/js/alc-app
git worktree add -b feat/foo .claude/worktrees/feat-foo origin/main
NUXT_PUBLIC_API_BASE=http://127.0.0.1:18080 \
  ~/js/.dev-proxy/up-wt.sh --quick alc-app feat-foo

# 5. backend を中で操作
bash ~/git/incus-sandbox/bin/exec.sh rust-alc-api feat-foo backend
# 中で: journalctl -u alc-service@rust-alc-api -f
#       psql -h postgres.incus -U postgres -c "\dt alc_api.*"

# 6. コード変更後、再ビルド + service 再起動
bash ~/git/incus-sandbox/bin/build.sh rust-alc-api feat-foo
bash ~/git/incus-sandbox/bin/exec.sh rust-alc-api feat-foo backend -- \
  systemctl restart alc-service@rust-alc-api

# 7. 終了
bash ~/git/incus-sandbox/bin/down.sh rust-alc-api feat-foo            # DB 残す
bash ~/git/incus-sandbox/bin/down.sh rust-alc-api feat-foo --purge    # DB volume も消す
```

### solo モード

特定 service だけ起動:
```bash
bash bin/up.sh rust-alc-api feat-foo solo backend
# postgres + backend + gateway が立つ。gateway は backend にだけ routing できる
```

### 並列 worktree

```bash
bash bin/up.sh rust-alc-api feat-foo full       # → 18080
bash bin/up.sh rust-alc-api fix-bar full        # → 18081 (自動採番)
bash bin/up.sh rust-alc-api spike-zzz full      # → 18082
```

各 worktree は別 Incus project / 別 postgres / 別 target volume なので干渉しない。

### ポート確認

```bash
bash bin/port.sh rust-alc-api feat-foo
# 18080
```

## トラブルシュート

### incus exec で permission denied

`incus-admin` グループに入っているか確認:
```bash
groups | grep incus-admin
# 入っていなければ:
sudo usermod -aG incus-admin $USER
newgrp incus-admin
```

### cloud-init が完了しない

warm image build 時に詰まる場合:
```bash
incus exec incus-dev-warm-tmp -- cloud-init status --long
```

### gateway proxy device が EADDRINUSE

`allocations/ports.json` で重複していないか、`ss -ltnp | grep 1808` で host 側プロセスを確認。

## ファイル構成

```
incus-sandbox/
├── bin/                      # CLI スクリプト群
├── cloud-init/               # warm image 用 cloud-init YAML
├── profiles/                 # Incus profile YAML
├── units/                    # systemd unit テンプレ
├── projects/<name>/          # プロジェクト別 manifest
└── allocations/ports.json    # worktree → host port 割当 (gitignore)
```

## 設計メモ

- 詳細設計は親 repo の `~/.claude/plans/github-app-staged-hejlsberg.md` を参照
- 1 worktree = 1 Incus project の隔離モデル
- gateway 経由で host に 1 ポートだけ公開 (per-service exposure はしない)
- `images:ubuntu/24.04` と `images:debian/12` を base、GHCR pull はしない
- ビルド成果物は worktree の `target/` ではなく Incus volume に置く (host worktree を汚さない)
