# git-trace.nvim: GitHub PR レビュー機能（閲覧専用）

## Context

現状、PR レビューはブラウザで差分を確認し、該当ファイルを Neovim で開き直すという二度手間になっている。Neovim の方が差分が見やすく LSP の定義ジャンプも使えるため、PR レビューの閲覧体験を Neovim 上で完結させたい。コメント投稿は将来課題としスコープ外。実装先は自作プラグイン git-trace.nvim（gh CLI + 非同期 `vim.system()` + GitHub provider の基盤が既存）。

/know-your-unknowns の「インタビュー」手法でアーキテクチャ未決定事項を 6 問解消済み。以下が確定事項。

## 決定事項一覧表（インタビュー結果）

| # | 論点 | 決定 | 理由・補足 |
|---|------|------|-----------|
| 1 | checkout 方式 | **git worktree**（`stdpath("cache")/git-trace/worktrees/<repo-id>/pr-<N>` に detached で展開） | 作業ツリー・未コミット変更に無影響。LSP は worktree ルートで起動し定義ジャンプが worktree 内で完結 |
| 2 | diff 表示 | **ネイティブ diff モード**（vsplit: 左=base のスクラッチバッファ、右=worktree 実ファイル、`:diffthis`） | トグル 1 キーで「diff ⇔ 修正後コード単独」切替。右側は常に実ファイルなので LSP がそのまま機能。ゼロ依存維持 |
| 3 | ファイル一覧 UI | **quickfix リスト**（status A/M/D + 追加/削除行数をテキスト表示） | `:cnext`/`:cprev` で巡回、既存の quickfix 習熟がそのまま活きる。実装コスト最小 |
| 4 | 変更箇所マーク | **自前 extmark**（単独表示時に `git diff <merge-base>` の hunk をパースし sign column に +/~/_） | gitsigns 依存を避けゼロ依存維持。hunk 間ジャンプも自前キーマップ |
| 5 | worktree 後始末 | **キャッシュ再利用**（Close はバッファのみ閉じ worktree 残置、再オープンは fetch 更新のみ、`:GitTraceReviewClean` で一括削除） | 中断・再開が多いワークフローと相性良。LSP 再インデックスも回避 |
| 6 | エントリポイント | **`:GitTraceReview {N}`** + **引数なしで `gh pr list` → `vim.ui.select`** | 「PR 一覧はあってもなくてもよい」を最小コストで充足。blame 連携は不要 |

追加の技術決定（標準に従い確定）:
- diff の base は **3-dot 比較**（`git merge-base refs/git-trace/pr/<N> origin/<baseRef>`）。GitHub の Files changed と同一。
- fetch は fork PR でも動く `refs/pull/<N>/head` を **専用 ref `refs/git-trace/pr/<N>`** に固定（FETCH_HEAD は揮発するため）。
- ファイル一覧・行数は **ローカル git で計算**（`gh pr view --json files` は 100 ファイル上限があるため使わない）。

## モジュール構成

既存の関心分離（実行 / パース(純粋関数) / オーケストレーション）を踏襲し、`review/` 名前空間に閉じる。

```
lua/git-trace/
  init.lua                # [変更] :GitTraceReview / :GitTraceReviewClose / :GitTraceReviewClean 登録
  config.lua              # [変更] review セクション追加
  provider/github.lua     # [変更] pr_view(N) / list_open_prs() + パース純粋関数
  review/
    init.lua              # セッション管理・オーケストレーション（公開 API: open/close/clean/toggle_diff/next_file/...）
    git.lua               # レビュー用 git 実行層（fetch/merge-base/diff/show/worktree 操作）
    worktree.lua          # worktree パス計算(純粋) + ensure/clean
    parser.lua            # 純粋関数: parse_hunks / parse_name_status / parse_numstat / parse_worktree_list
    ui/
      diff.lua            # vsplit + base スクラッチ + diffthis/diffoff トグル
      signs.lua           # extmark signs + hunk ジャンプ
      qflist.lua          # 純粋 build_items + setqflist ラッパ
tests/review/             # parser/worktree/qflist/signs/git の spec（既存方式踏襲）
```

再利用する既存資産: `vim.system + vim.schedule + (value, err) callback` パターン（`git.lua:25-104` / `github.lua:63-86`）、`vim.ui.select` の PR 選択ブロック（`init.lua:60-70`）、auth エラー変換（`github.lua:74-77`）、`config.apply/validate`、コマンド登録方式（`init.lua:11-22`、force=true）。

## 主要フロー

`:GitTraceReview 123` →
1. `gh pr view 123 --json number,title,url,state,baseRefName,headRefOid`（引数なし時は先に `gh pr list --json number,title,author` → `vim.ui.select`）
2. `git fetch origin +refs/pull/123/head:refs/git-trace/pr/123 +refs/heads/<base>:refs/remotes/origin/<base>`
3. `worktree.ensure`: 登録済みなら worktree 内で `checkout --detach --force`、未登録なら `worktree prune` → `worktree add --detach`
4. `git merge-base refs/git-trace/pr/123 origin/<base>` → `git diff --name-status -z -M` + `--numstat -z -M` を突合し ReviewFile[] を合成
5. quickfix に流し込み（filename = worktree 内絶対パス）、`copen`
6. `BufWinEnter` autocmd（worktree パスプレフィックスでガード）が diff 表示を自動起動

diff トグル: ON = base スクラッチ（`git show <merge-base>:<path>`、buftype=nofile/bufhidden=wipe、filetype は右から継承、バッファ名 `gittrace://pr<N>/<sha:8>/<path>`）を leftabove vsplit + 両窓 diffthis。OFF = base 窓 close + diffoff + 自前 signs 適用。トグル状態はファイル横断で維持。

## 落とし穴（実装時に必ず考慮）

1. `gh pr view --json files` は 100 ファイル上限 → ファイル一覧はローカル git で計算する。
2. FETCH_HEAD は揮発 → `refs/git-trace/pr/<N>` 固定 ref。detached worktree との組合せで「checkout 中ブランチへの fetch 拒否」も構造的に回避。
3. `diffoff` は window オプション（wrap/foldmethod/scrollbind 等）をユーザー値に戻さない → diffthis 前に退避・復元。`diffoff!` は使用禁止（タブ内全窓に波及）。
4. base（左）窓フォーカス中の `:cnext` はレイアウトを崩す → next_file/prev_file キーマップは main_win にフォーカスしてから `:cc` 実行。
5. 同一 repo の複数 clone → repo-id に `owner__repo + repo_root の sha256 先頭8桁` を使う。
6. worktree の LSP は別インスタンスで起動する（動作はする）。node_modules 等の依存物がないとフル機能にならない言語がある旨 README に明記。
7. `-U0` の純削除 hunk は new_start=0 になり得る → sign 行は 1 に clamp。
8. エッジケース: 削除ファイル(D)=base 単独表示、新規(A)=base 空バッファ、バイナリ=diff/signs スキップし `[binary]` 表示、リネーム(R)=`git show <mb>:<old_path>` + qf text `R old -> new`。

## config 追加（最小）

```lua
review = {
  worktree_dir = nil,   -- nil なら stdpath("cache").."/git-trace/worktrees"（実行時解決）
  pr_list_limit = 30,
  open_qf = true,
  keymaps = {           -- false で全無効。バッファローカルに設定
    toggle_diff = "<leader>rd",
    next_file = "]f", prev_file = "[f",
    next_hunk = "]c", prev_hunk = "[c",   -- 単独表示時のみ（diff モード中はネイティブ ]c が同じ動き）
    close = "<leader>rq",
  },
}
```

## 実装ステップ（各段階で動作確認可能）

1. **データ層**: config 拡張、`provider/github.lua` に pr_view/list_open_prs、`review/git.lua`、`review/parser.lua` + パーステスト一式。
2. **worktree + quickfix 最小版**: `review/worktree.lua`、`review/ui/qflist.lua`、`review/init.lua` 骨格、コマンド 3 つ登録。→ `:GitTraceReview 123` で qf 一覧から worktree 実ファイルが開く。
3. **diff 表示**: `review/ui/diff.lua`、BufWinEnter フック、トグル、D/A/binary/R 対応、winopts 退避復元。
4. **signs + hunk ジャンプ**: `review/ui/signs.lua`、BufReadPost 再描画、`]c`/`[c`。
5. **仕上げ**: キーマップ config 反映、再入ガード・冪等性、オーケストレーションテスト、README 更新。

## テスト方針

既存方式（純粋関数は直接テスト、副作用は vim.system/vim.schedule モンキーパッチ → after_each 復元）を踏襲。対象: parse_hunks（count 省略/削除/複数）、parse_name_status（NUL 区切り・R100）、parse_numstat（binary `-`）、repo_id/worktree_path、build_items（D/R/binary の text）、marks_for（行展開・clamp）、fetch_pr の refspec、worktree.ensure の分岐、review.open の setqflist キャプチャ。UI 窓操作は手動確認項目として列挙。

## 検証方法

- `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"`（CI と同一）
- 実機確認（このリポジトリ自身の PR で）: `:GitTraceReview <N>` → qf 一覧表示 → `<CR>` で vsplit diff → トグルで単独表示 + signs → 右窓で `gd` 定義ジャンプ → `:cnext` でファイル巡回 → `:GitTraceReviewClose` 後の再オープンが fetch のみで高速 → `:GitTraceReviewClean` で worktree と refs/git-trace が消えることを `git worktree list` / `git for-each-ref` で確認
- fork PR・削除ファイル・新規ファイル・バイナリ・リネームを含む PR で表示崩れがないこと

---

## 貼り付け可能な実装依頼プロンプト（deliverable）

別セッションで実装を依頼する場合は以下を貼り付ける:

```
git-trace.nvim に GitHub PR を Neovim 上でレビューする機能（閲覧専用、コメント投稿なし）を
追加してください。実装計画は plans/pr-review.md に確定済みです。この計画の
「決定事項一覧表」「モジュール構成」「主要フロー」「落とし穴」に厳密に従い、「実装ステップ」の
順に 1 ステップずつ実装 → テスト（PlenaryBustedDirectory tests/）を通してから次へ進んでください。

要点:
- git worktree 方式（stdpath("cache")/git-trace/worktrees/<owner__repo-roothash>/pr-<N>、
  detached HEAD、fetch は refs/pull/<N>/head → refs/git-trace/pr/<N> の専用 ref）
- ネイティブ diff モード（左=git show <merge-base>:<path> のスクラッチ、右=worktree 実ファイル、
  diffthis。トグル 1 キーで単独表示⇔diff。単独表示時は自前 extmark で +/~/_ signs）
- ファイル一覧は quickfix（filename=worktree 絶対パス、BufWinEnter autocmd で diff 自動起動）
- worktree はキャッシュ再利用（Close で残置、:GitTraceReviewClean で一括削除）
- コマンド: :GitTraceReview [N]（引数なしは gh pr list → vim.ui.select）/ :GitTraceReviewClose /
  :GitTraceReviewClean
- diff base は 3-dot（merge-base）。ファイル一覧はローカル git（--name-status/--numstat -z -M）で計算
  （gh の files JSON は 100 件上限のため使わない）
- 既存パターン厳守: vim.system + vim.schedule + (value, err) callback、純粋関数分離とテスト、
  ゼロ依存（plenary はテストのみ）、Neovim >= 0.10
```
