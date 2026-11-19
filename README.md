# git-push-gate

保護ブランチのないリポジトリでも、AIエージェントには main / develop 以外への push だけを許可する中継サーバーです。

GitHub の Rulesets やブランチ保護が使えない環境（プランの制約、管理者権限がない等）で、devcontainer 内の AI エージェントに feature ブランチの push を任せつつ、保護したいブランチへの書き込みは人間だけに残すことを目的にしています。

## 前提条件（必ず守ること）

ゲートが守れるのは「エージェントの push」だけです。エージェントにはワークフロー（`.github/workflows`）と複合アクション（`.github/actions`）を変更させませんが、**人間が書いた既存のワークフローが、エージェントの書き換えたコードを write 権限やシークレット付きで実行できると、ゲートの保証はすべてなくなります**（例: `on: push` + `contents: write` のワークフローが、feature ブランチへの push でも動き、エージェントが書き換えたスクリプトで `git push origin HEAD:main` する）。

- リポジトリの Settings → Actions → General → **Workflow permissions を「Read repository contents and packages permissions」にする**。`permissions` を書いていない既存のワークフロー（`npm test` を実行するだけの CI など）が、write 権限のトークンで動かないようにするため。あわせて「Allow GitHub Actions to create and approve pull requests」を無効にする
- write 権限やシークレットを持つワークフローは、保護ブランチへの `push` でだけ動くようにする（`branches: [main]` など）
- そうしたワークフローを `pull_request` で動かさない（`branches: [main]` で絞っても、main 向けの PR では head 側のコードで動く）
- `issue_comment` などで PR の head を checkout して実行するワークフローを置かない
- デフォルトブランチの `pull_request_target` のワークフローは、エージェントが自分のブランチを base にした PR を作るだけで動く。PR の head を checkout しなくても、特権付きで動くことを前提に中身を確認する
- 特権付きのワークフローを、パターン（`branches: ['release/**']` など）や保護していないブランチ名（`gh-pages` など）で動かさない。エージェントはそういう名前のブランチを作れる（`PROTECTED_BRANCHES` にパターンは書けない）
- デフォルトブランチの `workflow_run` や `on: create` / `delete` のワークフローで、エージェントの push で動いた実行の成果物やブランチ名を、特権付きで使わない
- 設定変数（`vars`）に機密情報を置かない。エージェントのコードを実行するワークフローから読める
- feature ブランチや PR で動くワークフローを、セルフホストのランナーで動かさない。トークンが読み取り専用でも、エージェントのコードがそのマシンで動く（ゲートの鍵を持つホストなら、鍵まで届く）
- すべてのブランチをシークレット付きでビルドする外部の CI（CircleCI、Vercel など）も、エージェントのコードをシークレット付きで動かす。エージェントのブランチではシークレットを使わない設定にする
- エージェントは PR 用のトークンで、トークンの持ち主（人間）として PR にコメント・ラベル付け・レビューができる。コメント（`/deploy` など）、ラベル（`safe-to-test` など）、承認をきっかけに特権付きで動くワークフローやボット（自動マージを含む）を置かない
- ブランチの内容を使って動く外部のアプリ（自動マージのボット、`gh-pages` からの Pages の公開など）も、エージェントが push したブランチで動きうる
- マージは、レビューしたコミットに限る（`gh pr merge --match-head-commit <SHA>` など）。保護ブランチがないので、レビューの後、マージの直前にエージェントが PR のブランチに push できる
- **ワークフローのトリガーや権限を変えたら、エージェントのブランチを消す**（`ALLOWED_BRANCH_PREFIXES` を使うと対象が分かりやすい）。既存のエージェントのブランチには変える前の版が残り、エージェントはそれを push や PR で動かせる（下記「ワークフローと複合アクション」と「限界」）

## 仕組み

```
devcontainer (エージェント)                git-push-gate コンテナ                    GitHub
  fetch ───────────────────────────────────────────────────────────────────────▶  (読み取り専用トークン)
  push ──SSH (コンテナ間専用の鍵)──▶  sshd → git-push-gate → pre-receive ──SSH──▶  (GitHub 用の鍵はここだけ)
```

- GitHub に書き込める鍵は git-push-gate コンテナだけが持ち、エージェントの環境には置きません。
- エージェントの SSH 鍵は `authorized_keys` の強制コマンドで `git-push-gate` に固定され、push（`git-receive-pack`）以外は実行できません。
- push を受け付ける前に GitHub の最新状態を fetch するので、fast-forward の判定は GitHub と一致します。
- `pre-receive` フックが検査し、通った更新だけをその場で GitHub に push します（`--atomic` と `--force-with-lease`）。lease には、クライアントが送ってきた値ではなく、直前に fetch した GitHub の値を使います。GitHub 側で失敗すればエージェントの push も失敗します。
- 保護ブランチが GitHub に 1 つでもなければ（名前の間違いなど）、またはデフォルトブランチが保護ブランチに入っていなければ、push を受け付けません。何も守らないまま動くのを防ぐためです。
- GitHub に push できた更新と、ゲートが拒否した push（` REJECTED ` と理由）、push 以外のコマンドの試みを、ゲートの `/srv/git/repo.git/push-gate.log` に記録します（`docker compose exec git-push-gate cat /srv/git/repo.git/push-gate.log`）。main やワークフローを変えようとした試みも、ここで分かります。ただし、フックに届く前に git が拒否したもの（壊れたオブジェクトなど）は記録されません。ブランチ名に使えるのは、英数字と `.` `_` `/` `-` だけです（下記）。制御文字、UTF-8 の C1 制御文字（U+009B など）、表示の向きを変える文字（U+202E など）を含む名前は、名前を書かずに拒否します（記録を表示したときに、端末の制御シーケンスとして働いたり、`…/Main` のように見せかけたりしないように）。255 バイトを超える ref 名も、名前を書かずに拒否します。拒否と push 以外のコマンドの試みは、記録が 10MB を超えると書きません（ボリュームを埋められないように。受け付けた更新は書きます）。
- ゲートのリポジトリの整理（gc）は、起動時と、push を受け付ける前（ロックを持った状態）に行います。
- 判定は受け付けの前に fetch した値で行い、GitHub に push する直前に、GitHub の保護ブランチがその値のままであることを確かめます（デフォルトブランチと、push するブランチと同じ名前のタグも、このとき確かめます）。変わっていれば拒否します。push を始めてからデータを送り終えるまで（最大 10 分）と判定の間に、人間が保護ブランチのワークフローを直していても、古い状態で判定した結果を push しないためです。残る隙間は、GitHub への push の間（最大 5 分）だけです。判定に時間がかからないよう、1 回の push で送れる ref は 50 個までです。
- ゲートは起動時（パスフレーズ付きの鍵なら unlock の後）に GitHub を fetch します。最初の fetch は全履歴なので時間がかかるためで、UPSTREAM・鍵・known_hosts の間違いもここで分かります（ログに警告が出る）。
- push を受け付ける前の fetch は 10 分（一度も fetch できていなければ 30 分）で打ち切ります。時間切れになった fetch は途中から再開しないので、人間がとても大きな push をした後などで毎回時間切れになるときは、ゲートを再起動してください（パスフレーズ付きの鍵なら、再起動の後に unlock）。起動時と unlock の fetch には時間制限がありません。
- 受け付けは 10 分、GitHub への push は 5 分で打ち切ります。止まったクライアントが、ほかの push を待たせ続けないためです。ただし、受け付けが時間切れになっても、フックの判定と GitHub への push はその後も続くことがあり、その間はロックも残ります（判定は CPU 時間で 60 分、GitHub への push は 5 分が上限）。終わっていることもあります（クライアントには失敗と返る）。その場合は fetch して確かめてください。記録の書き込みに失敗したときも、GitHub への push は成功として扱います。

## 拒否するもの

| 対象 | 理由 |
|---|---|
| 保護ブランチ（既定 `main develop`）の更新・削除 | 本来の目的。大文字・小文字だけが違う名前（`Main` など）も拒否 |
| ブランチ以外の ref（タグなど） | |
| GitHub にないブランチの削除 | 何もしないのに、受け付けた更新として記録が残る |
| push 証明書（`git push --signed`） | 使わない。receive-pack は案内していなくても受け取り、`MAX_PUSH_SIZE` と関係なく、拒否した push でもオブジェクト置き場に残す。ゲートは受け取ったものを常にパックのまま置くので、緩いオブジェクトはどれも使われていないものと分かる。緩いオブジェクトと一時ファイルが 100MB を超えたら push の前に消し、起動時にも消す。途中で切れた push の受け取りかけのデータは、push の前に毎回消す |
| 紛らわしいブランチ名（`HEAD`、`refs/`・`heads/`・`tags/`・`remotes/`・`pull/` で始まるもの、途中に `/refs/` があるもの、`/HEAD` で終わるもの、`-` で始まるもの、40 桁の 16 進数。どれも大文字・小文字を問わない） | 人間やツールが、別の ref やコミット ID と取り違える |
| GitHub にあるタグと同じ名前のブランチ（`v1.2.3` など） | 短い名前で引くツール（`git clone --branch`、`uses: owner/repo@v1` など）が、タグではなくブランチを取ることがある。ゲートが確かめるのは push の時点のタグだけ。後から人間が作ったタグと同じ名前になった既存のブランチは、エージェントは更新できないが、削除はできる（人間が消してもよい） |
| 英数字と `.` `_` `/` `-` 以外の文字を含むブランチ名 | `$` `` ` `` `;` `|` `(` などは、人間が書いたワークフローで `${{ github.head_ref }}` をそのままコマンドに埋め込んでいると、コマンドとして実行される。ASCII 以外の文字は、記録やメッセージを表示したときに、端末の制御シーケンスとして働いたり、別の名前に見せかけたりする |
| `.github/workflows` と `.github/actions` の変更 | 下記 |

### ワークフローと複合アクション

エージェントが push したブランチの `.github/workflows` と `.github/actions` は、保護ブランチの**どれか 1 つ**（main / develop など）と**同一**でなければ拒否します（ワークフローのファイルを消すのは可。ファイルがなければ動かない）。中身は解析せず、コミットの履歴（親や分岐点）も使いません。履歴はエージェントが自由に作れるためです。

ワークフローを変えたいときは、人間がホストから GitHub に直接 push してください。人間がワークフローを変えたブランチに、エージェントがワークフローをそのままにしてコミットを積むことはできません（人間がワークフローを試しているブランチで、エージェントのコードを特権付きで動かされないように）。ただし、保護ブランチのワークフローに戻したコミットでの強制 push や、ブランチの削除はできます。また、そのブランチを base にした PR を作れ、`pull_request` のワークフローは base とのマージコミットから読まれます。人間がワークフローを試すときは、`ALLOWED_BRANCH_PREFIXES` を設定して、エージェントが触れない名前のブランチを使ってください。変更が main に入れば、エージェントはまた main から作業できます。

- 人間がワークフローを直した後、古い版を持つ既存のブランチには push できません。main に rebase してください。ただし、古い版がほかの保護ブランチ（develop など）に残っていれば、その版は使えるままです。直すときは、すべての保護ブランチで直してください。
- ただし、GitHub に残っている古い版のブランチそのものは消えません。エージェントは、そのブランチを base にした PR を作れ、`pull_request` のワークフローは base とのマージコミットから読まれるので、直す前の版が動きます。ワークフローのトリガーや権限を変えたら、エージェントのブランチを消してください（上記「前提条件」）。
- `.github` や `.github/workflows` がシンボリックリンクなど、ディレクトリでなければ拒否します。大文字・小文字だけが違う `.GITHUB` や `.github/Workflows` も拒否します。
- 比較は木が正しい形であることを前提にしているので、ゲートは `receive.fsckObjects` で壊れたオブジェクト（並びの壊れた木など）を拒否します。変な mode（`100600` や `40777` など。比較では正規化されて同じに見える）も `receive.fsck.badFilemode` で拒否します。どちらかの設定が無効なら、push を受け付けません。

#### 中身を検査しない理由

以前は、ワークフローの中身を検査して安全なものだけを通していましたが、次の理由で、内容による判定は安全にできないと判断しました。

- `pull_request` のワークフローは、PR の head ではなく、GitHub が作る**マージコミット**（`refs/pull/N/merge`）から読まれます。エージェントは自分のブランチどうしの PR を作れるので、それぞれは検査を通る 2 つの変更を組み合わせて、どちらにもない（検査されていない）ワークフローを動かせます。
- YAML の解釈は、パーサーごとに細かく違います（単独の CR を改行とみなすかなど）。ゲートと GitHub の解釈が 1 か所でも違えば、検査をすり抜けられます。
- `pull_request_target` は、PR の head ではなく **base ブランチ**のワークフローが、write 権限とシークレット付きで動きます。エージェントは自分の push したブランチを base にした PR を作れるので、エージェントが書いたワークフローが特権付きで動いてしまいます。

同一かどうかだけを見る方式なら、解析は要らず、エージェントが push したブランチの先端のワークフローは、常に今の保護ブランチのどれかと同じ（人間が書いた版）になります。ただし、PR のマージコミットでは、人間が書いた 2 つの版の組み合わせが動くことがあります（「限界」を参照）。

## 使い方

### 1. 鍵とホスト鍵を用意する

**ワークスペース（devcontainer にマウントされるディレクトリ）の外**に設定ディレクトリを作ります。

```sh
gate_dir=~/.config/git-push-gate/REPO
mkdir -p "$gate_dir" && cd "$gate_dir"   # macOS の mkdir には --parents がない

# GitHub 用の鍵（この用途専用に作る。パスフレーズは付けても付けなくてもよい）
ssh-keygen -t ed25519 -C git-push-gate -f github_key
# → github_key.pub を GitHub に登録（下記「GitHub 用の鍵の選び方」を参照）

# GitHub のホスト鍵。表示されたフィンガープリントを GitHub のドキュメントと照合すること
ssh-keyscan -t ed25519 github.com > known_hosts
ssh-keygen -lf known_hosts

# devcontainer 側の公開鍵を書くファイル。最初は空でよい（下記 3. の setup.sh が表示する公開鍵を足す）
touch client_keys.pub
```

#### パスフレーズ

パスフレーズ付きの鍵の場合は `github_key.pub` も同じディレクトリに置いてください。起動後は鍵がロックされた状態になり、エージェントからの push は「ロックされています」というエラーで止まります。ホストで一度だけ次を実行すると、コンテナを止めるまで有効になります。

```sh
docker compose exec git-push-gate unlock
```

環境変数 `UNLOCK_LIFETIME`（例: `8h`）を指定すると、その時間が経つと自動で再ロックされます。

#### GitHub 用の鍵の選び方

| 方法 | 書き込める範囲 | 手間 |
|---|---|---|
| Deploy key（書き込み可） | 対象リポジトリだけ | リポジトリの管理者権限が必要 |
| マシンユーザーの SSH 鍵 | 招待されたリポジトリだけ | アカウントの作成と招待が必要 |
| 自分のアカウントに専用の鍵を追加 | 自分が書き込めるすべてのリポジトリ | 鍵を登録するだけ |

自分のアカウントの鍵でも、ホストにはもともと同じ範囲の認証情報（普段の push に使っているもの）があり、エージェントからは読めない場所に置くので、増えるリスクは「ホスト上の鍵ファイルが 1 つ増える」ことです。既存の鍵は使い回さず、漏れたときにそれだけ取り消せる専用の鍵にしてください。

### 2. compose に追加する

[examples/compose.yaml](examples/compose.yaml) を参照してください。

| 環境変数 | 説明 |
|---|---|
| `UPSTREAM` | 必須。例: `git@github.com:owner/repo.git` |
| `PROTECTED_BRANCHES` | 保護するブランチ（空白区切り、完全一致。`release/*` のようなパターンは使えない）。すべて GitHub に存在し、デフォルトブランチを含むこと（そうでないと push を受け付けない）。既定 `main develop` |
| `UNLOCK_LIFETIME` | パスフレーズ付きの鍵を解除しておく時間（例: `8h`）。既定は無期限。コンテナを再起動すると（`docker compose restart` を含む）、鍵はロックされ直すので、もう一度 `unlock` が必要 |
| `ALLOWED_BRANCH_PREFIXES` | 設定すると、この接頭辞（空白区切り。例: `agent/ claude/`）で始まるブランチしか作成・更新・削除させない。人間のブランチを強制 push・削除させない、`gh-pages` やワークフローの `branches:` に合う名前を作らせない、のに使う。既定は制限なし |
| `MAX_PUSH_SIZE` | 1 回の push で受け付ける大きさの上限（`receive.maxInputSize`）。既定 `500m`。push 証明書（下記）はこの上限に入らないので、メモリを compose の `mem_limit` で限る（例を参照） |

| マウント先 | 内容 |
|---|---|
| `/config` | `github_key`, `known_hosts`, `client_keys.pub`、パスフレーズ付きなら `github_key.pub`（読み取り専用で可）。クライアント用の秘密鍵は置かない |
| `/srv/git` | 中継用の bare リポジトリと sshd のホスト鍵（ボリューム推奨） |

### 3. devcontainer 側の push 先を設定する

devcontainer の中で [client/setup.sh](client/setup.sh)（コメントを除いて 50 行足らず）を実行します。ホストで実行するスクリプトはありません。setup.sh は次のことをします。書き込むのは `~/.ssh` と `.git/config` だけで、利用側のリポジトリにコミットされるものはありません。

- クライアント用の鍵を devcontainer の中で作る（秘密鍵は外に出さない。すでにあれば作り直さない）
- ゲートのホスト鍵を `~/.ssh/git-push-gate_known_hosts` に書き、`~/.ssh/config` に `Host git-push-gate` を足す（SSH エージェントは使わない設定）
- `git remote set-url --push origin ssh://git@git-push-gate/repo.git`（fetch は今までどおり GitHub から）
- 作った公開鍵を表示する

ホストでゲートを操作するコマンドは、ゲートを単独で起動したなら、その compose のディレクトリで `docker compose exec git-push-gate …` / `docker compose restart git-push-gate` と書けます。devcontainer の compose に入れたなら、VS Code がプロジェクト名を変えるので、コンテナ名を指定して `docker exec` / `docker restart` を使ってください（`docker ps --filter label=com.docker.compose.service=git-push-gate --format '{{.Names}}'` で分かります）。エージェントが書き換えられる compose のファイルを、ホストで読ませずに済みます。

手順:

0. devcontainer を作ったら（リビルドのたびに）、setup.sh より前に、エージェントを動かす前に、人間が devcontainer の中で下の「[確かめ方](#確かめ方)」を済ませます。

1. ホストで、ゲートのホスト鍵を表示します。

   ```sh
   docker compose exec git-push-gate cat /srv/git/ssh_host_keys/ssh_host_ed25519_key.pub
   ```

2. devcontainer の中で、ワークスペースのディレクトリで setup.sh を実行します。setup.sh は、このリポジトリから内容を貼り付けるなどして持ち込みます（ワークスペースに置くならコミットしない）。ゲートのアドレスとポートは、compose 方式なら `git-push-gate` と `22`、ゲートを別に起動したなら下の表のとおりです。

   ```sh
   sh setup.sh git-push-gate 22 'ssh-ed25519 AAAA... git-push-gate'   # 1. で表示されたホスト鍵
   ```

   秘密の情報を使わないので、AI エージェントに頼んでもかまいません（その場合も、0. の「確かめ方」は先に人間が済ませてください）。例: 「client/setup.sh の内容で ~/setup.sh を作り、`sh ~/setup.sh git-push-gate 22 '<ホスト鍵>'` を実行して、表示された公開鍵を教えて」

3. 表示された公開鍵を、ホストで、ゲートの `/config` にマウントしたディレクトリ（「1. 鍵とホスト鍵を用意する」で作った設定ディレクトリ。ゲートを単独で起動したなら、その `config/`）の `client_keys.pub` に足し、ゲートだけを再起動します（`docker compose restart git-push-gate`。パスフレーズ付きの鍵なら、この後もう一度 `unlock`）。
   - **シェルのコマンド（`echo '…' >> client_keys.pub` など）では貼らず、エディタで貼ってください。** エージェントが出した文字列に `'` や `$(…)` が紛れていると、ホストで実行されてしまいます。
   - 貼るのは `ssh-ed25519 AAAA… git-push-gate-client` の 1 行だけです。ゲートは、この形でない行があると起動を止め、起動時に登録した鍵のフィンガープリントをログ（`docker compose logs git-push-gate`）に出します。

devcontainer をリビルドすると `~/.ssh` が消えるので、0.・2.・3. をやり直します（古い公開鍵は `client_keys.pub` から消してください）。ゲートのホスト鍵は `/srv/git` のボリュームに保存されるので、ゲートのコンテナを作り直しても変わりません。

### 利用側のリポジトリを変更せずに使う（compose を使わない devcontainer）

devcontainer.json が `image` や Dockerfile の方式で compose を使っていない場合は、ゲートを別に起動し、ポートをホストに公開してつなぎます。利用側のリポジトリにコミットする変更は要りません。

devcontainer は既定の bridge ネットワークで動くのでコンテナ名では届かず、Feature では `--network` を指定できないためです。compose 方式でも、devcontainer.json の `dockerComposeFile` に書かれたファイルしか読まれない（`docker-compose.override.yml` や `COMPOSE_FILE` は使われない）ので、ゲートを足すには devcontainer.json の変更が要ります。

1. ワークスペースの外に [examples/standalone/compose.yaml](examples/standalone/compose.yaml) を置き、同じディレクトリの `config/` に鍵など（「1. 鍵とホスト鍵を用意する」で作ったファイル）を置いて起動します。

   ```sh
   cd ~/.config/git-push-gate/REPO
   docker info --format '{{.OperatingSystem}}'   # Docker Desktop か、それ以外か
   echo GATE_BIND=172.17.0.1 > .env               # Docker Desktop 以外のときだけ（docker0 の IP）
   docker compose up --detach
   ```

   | Docker | 公開先（`GATE_BIND`） | devcontainer から見たゲート |
   |---|---|---|
   | Docker Desktop（Mac / Windows。WSL2 バックエンドを含む） | `127.0.0.1`（既定） | `host.docker.internal` |
   | Linux・WSL に直接入れた Docker Engine | docker0 の IP（多くは `172.17.0.1`） | デフォルトゲートウェイ（docker0 の IP） |

   `0.0.0.0` には公開しないでください（LAN に公開されます）。Docker Desktop の経路は未検証です。

2. 上の「3. devcontainer 側の push 先を設定する」の手順で、devcontainer の中で setup.sh を実行します。ゲートのアドレスとポートは、表の「devcontainer から見たゲート」と、公開したポート（既定 `2222`）です。

   ```sh
   sh setup.sh host.docker.internal 2222 'ssh-ed25519 AAAA... git-push-gate'   # Docker Desktop
   sh setup.sh 172.17.0.1 2222 'ssh-ed25519 AAAA... git-push-gate'             # Linux の Docker Engine
   ```



## devcontainer 側で必要な設定

ゲートを置いても、エージェントの環境に書き込み可能な認証情報があれば意味がありません。

- VS Code のユーザー設定で、次の 3 つを止める（どれも、ゲートを通らずに GitHub に push できる認証情報を devcontainer に渡す仕組み。実際の VS Code での確認はまだ）
  - `dev.containers.gitCredentialHelperConfigLocation` を `none`（ホストの git の認証情報の転送）
  - `git.terminalAuthentication` を `false`（統合ターミナルに `GIT_ASKPASS` を設定し、VS Code が HTTPS の認証に答える仕組み）
  - `github.gitAuthentication` を `false`（その答えに、VS Code にサインインしている GitHub のアカウントを使う仕組み。サインインしていなくても、push のときにサインインを求める画面が出る）
- VS Code で GitHub にサインインしない（サインアウトする）。devcontainer の中で動く拡張機能は、サインインしたアカウントのトークン（`repo` スコープなど）を受け取れ、エージェントが同じユーザーで動いていれば、それに届くおそれがある（推測。確かめてはいない）
- SSH エージェントを転送しない。Dev Containers には転送を止める設定がなく、ホストに `SSH_AUTH_SOCK` があれば転送される。エージェントのない状態で VS Code を起動するのがよい。転送されても、ホストのエージェントに GitHub の鍵が入っていなければ迂回はできない（下の「確かめ方」の 4. で、GitHub に認証できないことを確かめる）
- `docker.sock` をマウントしない（docker-outside-of-docker の Feature なども使わない）
- ゲートの設定ディレクトリ（`~/.config/git-push-gate` など）をマウントしない
- **devcontainer の定義とワークスペースの `.git` は、エージェントが書き換えられる**ことに注意する
  - `.devcontainer/devcontainer.json` や compose のファイルに、マウント（docker.sock やゲートの設定ディレクトリ）や `initializeCommand`（ホストで動く）を足されると、人間がリビルドしたときに効いてしまう。リビルドの前に差分を確かめる
  - `postCreateCommand` などのライフサイクルのコマンドと、そこから呼ばれるもの（`.devcontainer/*.sh`、`npm install` のスクリプト、Makefile など）は、リビルドのたびに、下の「確かめ方」より前に devcontainer の中で動く。`~/.bashrc` にエイリアスを仕込んで確かめ方の結果を偽ることもできるので、これもリビルドの前に差分を確かめる
  - ワークスペースの `.vscode/settings.json` は、上の VS Code のユーザー設定（`git.terminalAuthentication` など）を打ち消したり、統合ターミナルの環境変数を変えたりできる（推測。確かめてはいない）。ワークスペースを開く前と、下の「確かめ方」の前に差分を確かめる
  - ワークスペースの `.git/config`（`core.fsmonitor`、`core.sshCommand` など）や `.git/hooks` は、ホストでそのディレクトリの git を使うと、ホストで実行される。ホストでは、そのワークスペースで git を使わない（別に clone したものを使う）
- エージェントに渡す GitHub トークン（PR 作成用など）は、対象のリポジトリだけに絞った fine-grained PAT にする
  - **Contents: read**。Contents: write はマージや API 経由のコミットも許してしまう
  - PR を作るなら **Pull requests: write**。PR のブランチを更新する API（`PUT /repos/{owner}/{repo}/pulls/{pull_number}/update-branch`。base を head にマージする）は、GitHub のドキュメントでは Pull requests: write だけで呼べるように書かれているが、Contents: read の fine-grained PAT では「user doesn't have permission to update head repository」（403）で拒否されることを確かめた（2026-11、持ち主が書き込めるアカウントの PAT）。Contents: write を付けると、head が main の PR を作ってこれを呼ぶだけで main を書き換えられるので、付けないこと
  - **Actions: write は付けない**（`workflow_dispatch` や再実行で、保護ブランチのワークフローを動かせてしまう）
  - classic PAT の `repo` スコープは書き込みも含むので使わない

### 確かめ方

devcontainer を作ったら（リビルドのたびに）、**setup.sh より前に、エージェントを動かす前に**、人間が devcontainer の中で次を実行してください。`OWNER/REPO` は対象のリポジトリに置き換えます。

これは、人間の設定ミス（VS Code の設定、SSH エージェントの転送、トークンの権限など）を見つけるための**目安**です。エージェントが手を入れられる環境の中で行う確認なので、エージェントがその気になれば結果を偽れます（ワークスペースの `.git` や、上のライフサイクルのコマンドで動くスクリプトは、前のセッションでエージェントが書き換えられる。devcontainer で sudo が使えるなら、コマンドそのものも差し替えられる）。ゲートを迂回させない本当の守りは、ゲートと、トークンの権限と、上の設定の側にあります。

- VS Code の統合ターミナルで実行してください（`GIT_ASKPASS` が設定されるのはそこだけです）
- エイリアスや関数の影響を受けないよう、先に設定ファイルを読まないシェルを起動してから実行します（`bash --noprofile --norc`。zsh なら `zsh -f`）
- 結果に書いた「No such file」は、zsh では「no matches found」になることがあります

1. Docker を操作できない。どれも「No such file」で、`DOCKER_HOST=` は空

   ```sh
   ls /var/run/docker.sock /var/run/docker-host.sock /run/docker.sock; echo "DOCKER_HOST=${DOCKER_HOST:-}"
   ```

2. SSH エージェントがない。`SSH_AUTH_SOCK=` は空、`ls` は「No such file」、`ssh-add -l` は「Could not open a connection to your authentication agent」（エージェントがあっても鍵がなければ「The agent has no identities」。その場合、迂回できないかの決め手は 4.）

   ```sh
   echo "SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-}"; ls /tmp/vscode-ssh-auth-*.sock; ssh-add -l
   ```

3. 認証情報のファイルがない。どれも「No such file」（`~/.ssh` は、setup.sh の前なので、ないか空。`~/.config/gh` は、エージェント用のトークンを `gh auth login` で設定したならある）

   ```sh
   ls ~/.ssh ~/.git-credentials ~/.netrc ~/.config/gh ~/.config/git-push-gate
   ```

4. GitHub に SSH で認証できない。「Permission denied (publickey)」になること（「Host key verification failed」では確かめたことにならない）。`~/.ssh/known_hosts` ができるのは、この確認によるもの

   ```sh
   ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new git@github.com
   ```

5. git に認証や接続先を差し替える設定がない。ホームディレクトリとワークスペースのディレクトリで 1 回ずつ実行します（ワークスペースの `.git/config` も見るため）。
   - `--no-pager` は、ワークスペースの設定にあるページャーで出力を絞られないようにするためのもの
   - ワークスペースでは、最初の `git rev-parse` が `.git` を表示すること（エラーなら、持ち主の違いなどでワークスペースの設定を読めていないので、確かめたことにならない）
   - 何も出ないこと。ただし、エージェント用の読み取り専用のトークンを `gh auth setup-git` で設定したならその `credential` の行は出てよく、`remote.*.url` の行は、URL に `ユーザー名:トークン@` が入っていなければよい

   ```sh
   cd ~ && git --no-pager config --show-origin --get-regexp 'credential|insteadof|extraheader|askpass|sshcommand|proxy|pushurl|hookspath'
   cd <ワークスペース> && git rev-parse --git-dir &&
     git --no-pager config --show-origin --get-regexp 'credential|insteadof|extraheader|askpass|sshcommand|proxy|pushurl|hookspath|^remote\..*\.url'
   ```

6. 環境変数にトークンや認証の仕組みがない。エージェント用の読み取り専用のトークン以外は出ないこと（`GIT_ASKPASS` が出たら VS Code の設定を見直す）

   ```sh
   env | grep -iE 'token|askpass|ssh_auth|git_ssh|(^|_)pat(_|=)|passw|secret|credential'
   ```

7. HTTPS で push できない。ワークスペースの外に作った空のリポジトリから試し、「could not read Username」か 403 などの認証のエラーで失敗すること（成功したら GitHub に `bypass-test` ができるので消し、設定を見直す）。「Author identity unknown」などで push の前に止まったら、確かめたことにならない

   ```sh
   cd "$(mktemp -d)" && git init --quiet &&
     git -c user.name=x -c user.email=x@example.com -c commit.gpgsign=false commit --quiet --allow-empty --message x &&
     GIT_TERMINAL_PROMPT=0 git push https://github.com/OWNER/REPO.git HEAD:refs/heads/bypass-test; cd -
   ```

8. エージェントのトークンで、書き込みの API を呼べない。エージェントが `gh` を使うなら、まず `gh auth status` で、使われているのが fine-grained PAT（`github_pat_…`）であることを確かめ、トークンは `gh auth token` で取ります（使っていなければ、エージェントに渡したトークンを `GH_TOKEN` に入れる）。
   - 状態コードが `403` で、本文が GitHub のメッセージ「Resource not accessible by personal access token」であること。プロキシなど、GitHub 以外が返した 403 では確かめたことにならない
   - `401` はトークンが空か無効、`404` は OWNER/REPO の間違いか、トークンがそのリポジトリを対象にしていないので、どちらも確かめたことにならない
   - それ以外（`201` や `422`）なら Contents: write があるので、トークンを作り直す（`201` ならできた `bypass-test` も消す）

   ```sh
   token=$(gh auth token 2>/dev/null || printf '%s' "$GH_TOKEN")
   curl --silent --show-error --write-out '\n%{http_code}\n' --request POST \
     --header "Authorization: Bearer $token" --header 'Content-Type: application/json' \
     --data '{"ref":"refs/heads/bypass-test","sha":"<main のコミットの SHA>"}' \
     https://api.github.com/repos/OWNER/REPO/git/refs
   ```

## 限界

- ゲートが守れるのは git の push だけです。エージェントのトークンに書き込みの権限（Contents: write、Actions: write など）があれば、GitHub の API でゲートを迂回できます（上記のトークンの権限を参照）。

- クライアント側のガードではなくサーバー側の強制ですが、GitHub のブランチ保護の代わりにはなりません。使えるならそちらが確実です。
- ワークフローが実行するコード（`npm test` から呼ばれるスクリプト、`.github/actions` 以外に置いたローカルアクション（`uses: ./tools/x` など）等）はエージェントが変更できます（上記「前提条件」）。
- 人間が書いたワークフローの版どうしを、PR のマージコミットで組み合わせられます。材料は、今の保護ブランチ（main と develop など）と、GitHub に残っているブランチ（古い版を持つエージェントのブランチや、人間のブランチ）にある版です。エージェントは分岐点を選べるので、同じファイルの 2 つの版を、変更のまとまりごとに選んで組み合わせられます（両方が違う形で変えたまとまりは競合し、ワークフローは動かない）。同じファイルでトリガーと権限の両方を変えると（例: `on: pull_request` で読み取り専用の版を、`on: push: [main]` で `contents: write` の版にする）、`on: pull_request` で write という、誰も書いていない組み合わせが作られうる。このような変更をしたら、エージェントのブランチを消すこと
- 検査するのは push されたブランチの先端のコミットだけです。途中のコミットはブランチが指さない限り動かないためで、エージェントがゲート以外で ref を作れない（PR 用のトークンが Contents: read）ことが前提です。
- 保護していないブランチは、人間が作ったものでもエージェントが強制 push・削除できます（`ALLOWED_BRANCH_PREFIXES` で制限できる）。人間がワークフローを変えたブランチも、保護ブランチのワークフローに戻したコミットでなら上書きできます。
- main にある既存のワークフローで、`issue_comment` や `pull_request_review` などで動いて PR の head を checkout するものは、エージェントが PR を作れるので危険です（head 側のコードが base 側の権限で動く）。
- ソースコードの外部送信は防げません。
- SHA-256 のリポジトリ（`--object-format=sha256`）には対応していません。push はすべて拒否されます。
- Git LFS は使えません（LFS のオブジェクトは HTTPS で送るので、ゲートを通らず、読み取り専用のトークンでは送れない）。

## 今後の課題

- 保護ブランチのワークフローを読み、feature ブランチや `pull_request` で動く特権付きのものがあれば警告する（上記「前提条件」を仕組みで確かめる）
- ゲートのリポジトリのディレクトリを root の所有にし、git ユーザーが書けるのを `objects/` と `refs/` などに限る。git ユーザーのホームディレクトリ（`authorized_keys` を含む）と、ホスト鍵を置く `/srv/git` も、今は git ユーザーの持ち物なので、同じように root の所有にする（どれも、ゲートの中でコマンドを実行されたときの被害を小さくするためのもの。強制コマンドで実行は防いでいる）

## テスト

Docker なしで動く結合テストがあります（git、util-linux の flock、GNU coreutils か busybox の timeout、python3 が必要。macOS ではそのままでは動きません）。

```sh
sh test/run.sh
```

コンテナを使った e2e テストもあります（Docker だけが必要）。イメージ自身を「GitHub」（SSH の git サーバー）とクライアントにも使い、本物の entrypoint・sshd・unlock を通して確認します。

```sh
docker build --tag git-push-gate:test .
sh test/e2e.sh
```

## ライセンス

MIT
