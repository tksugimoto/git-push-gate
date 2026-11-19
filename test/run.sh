#!/bin/sh
# Docker なしで動く結合テスト。ローカルの bare リポジトリを GitHub に見立て、
# SSH の代わりに --receive-pack で git-push-gate を直接起動する。
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK_DIR=$(mktemp --directory)
trap 'rm -rf "$WORK_DIR"' EXIT
export GIT_CONFIG_NOSYSTEM=1 HOME="$WORK_DIR/home" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
  GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir --parents "$HOME"; git config --global init.defaultBranch main; git config --global advice.detachedHead false
cd "$WORK_DIR"

# 「GitHub」
git init --quiet --bare gh.git
git clone --quiet gh.git seed 2>/dev/null
( cd seed && mkdir --parents .github/workflows .github/actions/a \
  && printf 'on: push\n' > .github/workflows/ci.yml && echo x > .github/actions/a/action.yml \
  && git add --all && git commit --quiet --message init && git push --quiet origin main main:develop )

# ゲート側のリポジトリ（entrypoint.sh 相当）
git init --quiet --bare gate.git
git --git-dir=gate.git config remote.upstream.url "$WORK_DIR/gh.git"
git --git-dir=gate.git config gate.protected "main develop"   # 以下 4 つは entrypoint.sh が書き込むもの
git --git-dir=gate.git config receive.fsckObjects true
git --git-dir=gate.git config receive.fsck.badFilemode error
git --git-dir=gate.git config gate.allowedPrefixes "*"
git --git-dir=gate.git config fetch.unpackLimit 1
git --git-dir=gate.git config receive.unpackLimit 1
git --git-dir=gate.git config receive.denyDeleteCurrent ignore
git --git-dir=gate.git config receive.autogc false
# ローカル転送だと quarantine 用の環境変数が上流に漏れるので外す（SSH 越しの GitHub では不要）
git --git-dir=gate.git config remote.upstream.receivepack \
  'env -u GIT_QUARANTINE_PATH -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES git-receive-pack'
cp "$ROOT/hooks/pre-receive" gate.git/hooks/pre-receive
cat > rp <<RP
#!/bin/sh
export SSH_ORIGINAL_COMMAND="git-receive-pack 'repo.git'" GIT_PUSH_GATE_REPO="$WORK_DIR/gate.git"
exec "$ROOT/bin/git-push-gate"
RP
chmod +x rp

# 開発環境（fetch は「GitHub」、push はゲート）
git clone --quiet gh.git dev
cd dev
git remote set-url --push origin "$WORK_DIR/gate.git"
git config remote.origin.receivepack "$WORK_DIR/rp"
git config push.negotiate false

pass=0; fail=0
expect() { # expect ok|ng 説明 push引数...
  want=$1; desc=$2; shift 2
  if git push "$@" >"$WORK_DIR/out" 2>&1; then got=ok; else got=ng; fi
  # 拒否はゲートか git の正規の拒否によるものに限る（別の理由での失敗を見逃さない）
  if [ "$got" = ng ] && ! grep -Eq 'git-push-gate:|\[rejected\]|fsck error' "$WORK_DIR/out"; then got=error; fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "ok   $desc"
  else fail=$((fail+1)); echo "FAIL $desc (expected $want)"; sed 's/^/     /' "$WORK_DIR/out"; fi
}
gh_has() { git --git-dir="$WORK_DIR/gh.git" rev-parse --quiet --verify "refs/heads/$1" >/dev/null; }
wf() { # ブランチを main から切ってワークフローを書き換え
  git switch --quiet --force-create "$1" origin/main; printf '%s\n' "$2" > .github/workflows/ci.yml; git commit --quiet --all --message "$1"
}
human() { # 人間がホストから GitHub に直接 push する（ゲートを通らない）
  ( cd "$WORK_DIR/seed" && git fetch --quiet && git switch --quiet --force-create "$1" "origin/${2:-main}" && sh -c "$3" && git add --all \
    && git commit --quiet --message "$1" && git push --quiet origin "$1" )
  git fetch --quiet
}

git switch --quiet --create feat; echo a > a; git add a; git commit --quiet --message a
expect ok "feature ブランチの新規作成" origin feat
gh_has feat || { echo "FAIL GitHub に feat がない"; fail=$((fail+1)); }
expect ng "main への push" origin HEAD:main
expect ng "develop への push" origin feat:develop
expect ng "main の削除" origin :main
expect ng "タグ" origin HEAD:refs/tags/v1

# 人間が GitHub 側で feat を進めた
( cd "$WORK_DIR/seed" && git fetch --quiet && git switch --quiet --create feat origin/feat && echo h > h && git add h \
  && git commit --quiet --message human && git push --quiet origin feat )
echo b > b; git add b; git commit --quiet --message b
expect ng "GitHub 側が先行しているときの通常 push" origin feat
git fetch --quiet; git rebase --quiet origin/feat
expect ok "取り込んだ後の push" origin feat
git commit --quiet --amend --message b2
expect ok "強制 push" --force origin feat
expect ok "feature ブランチの削除" origin :feat

# ワークフローは保護ブランチのどれか 1 つと同一のものだけ（消すのは可）。中身は見ない
wf w1 "on: pull_request";                                          expect ng "ワークフローの変更" origin w1
git switch --quiet --force-create w2 origin/main; echo 'on: push' > .github/workflows/new.yml; git add --all; git commit --quiet --message w2
expect ng "ワークフローの追加" origin w2
git switch --quiet --force-create w3 origin/main; echo 'on: push' > ".github/workflows/$(printf '\303\251').yml"; git add --all; git commit --quiet --message w3
expect ng "ASCII 以外を含む名前のワークフローの追加" origin w3
git switch --quiet --force-create w4 origin/main; git rm --quiet .github/workflows/ci.yml; git commit --quiet --message w4
expect ok "ワークフローの削除" origin w4
git switch --quiet --force-create w5 origin/main; git mv .github/workflows/ci.yml .github/workflows/ci2.yml; git commit --quiet --message w5
expect ng "ワークフローの名前の変更" origin w5
git switch --quiet --force-create w6 origin/main; chmod +x .github/workflows/ci.yml; git commit --quiet --all --message w6
expect ng "ワークフローの実行権限の変更" origin w6
git switch --quiet --force-create w7 origin/main; git rm -r --quiet .github/workflows; mkdir --parents wfdir
printf 'on: pull_request_target\npermissions: write-all\njobs: {}\n' > wfdir/x.yml; ln -s ../wfdir .github/workflows
git add --all; git commit --quiet --message w7;                                     expect ng ".github/workflows がシンボリックリンク" origin w7
git switch --quiet --force-create w8 origin/main; git rm -r --quiet .github; mkdir --parents gh/workflows; echo 'on: push' > gh/workflows/x.yml; ln -s gh .github
git add --all; git commit --quiet --message w8;                                     expect ng ".github がシンボリックリンク" origin w8
git switch --quiet --force-create w9 origin/main; mkdir --parents .github/workflows/sub; echo 'on: push' > .github/workflows/sub/x.yml; git add --all; git commit --quiet --message w9
expect ng "サブディレクトリへのワークフローの追加" origin w9
git switch --quiet --force-create w10 origin/main; mkdir --parents .GITHUB/workflows; echo 'on: push' > .GITHUB/workflows/y.yml; git add --all; git commit --quiet --message w10
expect ng "大文字の .GITHUB" origin w10
git switch --quiet --force-create w11 origin/main; mkdir --parents .github/Workflows; echo 'on: push' > .github/Workflows/x.yml; git add --all; git commit --quiet --message w11
expect ng "大文字の .github/Workflows" origin w11
git switch --quiet --force-create w12 origin/main; git rm -r --quiet .github/actions; ln -s ../x .github/actions; git add --all; git commit --quiet --message w12
expect ng ".github/actions がシンボリックリンク" origin w12
# 並びの壊れた木（zzz の後ろに .github）。ls-tree に .github が見えないので、fsck で止める
command -v python3 >/dev/null || { echo "FAIL このテストには python3 が必要です"; exit 1; }
broken_tree=$(python3 - "$(git rev-parse origin/main:.github)" "$(git hash-object -w --stdin </dev/null)" <<'PY' | git hash-object -t tree -w --literally --stdin
import sys
gh, empty = (bytes.fromhex(x) for x in sys.argv[1:])
sys.stdout.buffer.write(b"100644 zzz\0" + empty + b"40000 .github\0" + gh)
PY
)
[ "$broken_tree" != 4b825dc642cb6eb9a060e54bf8d69288fbee4904 ] || { echo "FAIL 並びの壊れた木を作れませんでした"; exit 1; }
expect ng "並びの壊れた木" origin "$(git commit-tree "$broken_tree" -p origin/main -m w13):refs/heads/w13"   # 作業ツリーには取り出さない
git --git-dir="$WORK_DIR/gate.git" config receive.fsckObjects false
git switch --quiet --force-create w14 origin/main; echo f > f; git add f; git commit --quiet --message w14
expect ng "fsck が無効なゲート" origin w14
git --git-dir="$WORK_DIR/gate.git" config receive.fsckObjects true
# 複数の ref を 1 回で push したとき、1 つでも拒否なら何も GitHub に届かない
git switch --quiet --force-create multi origin/main; echo m > m; git add m; git commit --quiet --message multi
expect ng "正常な ref と main を同時に push" origin multi HEAD:main
if gh_has multi; then fail=$((fail+1)); echo "FAIL 拒否された push の一部が GitHub に届いた"; else pass=$((pass+1)); echo "ok   拒否された push は一部も GitHub に届かない"; fi
# 人間がワークフローを変えたブランチには、エージェントは push できない（人間がワークフローを試すブランチを守る）
human hw main "printf 'on: pull_request\n' > .github/workflows/ci.yml"
git switch --quiet --force-create hw origin/hw; echo c > c; git add c; git commit --quiet --message c
expect ng "人間が変更したワークフローのブランチへの push（人間がワークフローを試すブランチを守る）" origin hw
git rebase --quiet --onto origin/hw HEAD~1; git commit --quiet --allow-empty --message e
expect ng "人間が変更したワークフローのブランチへの強制 push" --force origin hw
printf 'on: [push]\n' > .github/workflows/ci.yml; git commit --quiet --all --message hw2
expect ng "人間が変更したワークフローの書き換え" origin hw
git reset --quiet --hard origin/hw
expect ng "人間が変更したワークフローを別のブランチへ" origin hw:refs/heads/hw-copy
human ha main "echo z >> .github/actions/a/action.yml"
git switch --quiet --force-create ha origin/ha; echo c > c; git add c; git commit --quiet --message c
expect ng "人間が変更した .github/actions のブランチへの push" origin ha
# 名前を間違えた保護ブランチ
git --git-dir="$WORK_DIR/gate.git" config gate.protected "main develop nosuch"
git switch --quiet --force-create typo origin/main; echo t > t; git add t; git commit --quiet --message typo
expect ng "GitHub にない保護ブランチ" origin typo
git --git-dir="$WORK_DIR/gate.git" config gate.protected "main develop"
# 紛らわしいブランチ名
git switch --quiet --force-create odd origin/main; echo o > o; git add o; git commit --quiet --message odd
expect ng "HEAD という名前のブランチ" origin odd:refs/heads/HEAD
expect ng "大文字だけが違う保護ブランチ（Main）" origin odd:refs/heads/Main
expect ng "refs/ で始まるブランチ名" origin odd:refs/heads/refs/tags/v1
# 保護ブランチの一覧が空白だけ
git --git-dir="$WORK_DIR/gate.git" config gate.protected " "
expect ng "保護ブランチの一覧が空のときの削除" origin :develop
git --git-dir="$WORK_DIR/gate.git" config gate.protected "main develop"
expect ng "- で始まるブランチ名" origin odd:refs/heads/-x
expect ng "+ で始まるブランチ名" origin odd:refs/heads/+x
expect ng "@ という名前のブランチ" origin odd:refs/heads/@
expect ng "40 桁の 16 進数のブランチ名" origin "odd:refs/heads/$(git rev-parse HEAD)"
# デフォルトブランチ（main）が保護ブランチに入っていない
git --git-dir="$WORK_DIR/gate.git" config gate.protected "develop"
expect ng "デフォルトブランチが保護されていない" origin odd:refs/heads/odd2
git --git-dir="$WORK_DIR/gate.git" config gate.protected "main develop"
# フックに不正な形式の行が渡ったとき（receive-pack は ref 名を検査する前にフックへ渡す）
if printf 'x refs/heads/main refs/heads/evil\n' | (cd "$WORK_DIR/gate.git" && GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$WORK_DIR/out" 2>&1 \
   || ! grep -q '不正な更新の指定' "$WORK_DIR/out"
then fail=$((fail+1)); echo "FAIL 不正な形式の行は拒否"; sed 's/^/     /' "$WORK_DIR/out"; else pass=$((pass+1)); echo "ok   不正な形式の行は拒否"; fi
# ref 名の末尾に空白がある行（read で区切ると取り除かれ、整えた名前で GitHub に push してしまう）
if printf '%s %s refs/heads/trail \n' 0000000000000000000000000000000000000000 "$(git rev-parse origin/main)" \
   | (cd "$WORK_DIR/gate.git" && GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$WORK_DIR/out" 2>&1 || ! grep -q '不正な更新の指定' "$WORK_DIR/out" || gh_has trail
then fail=$((fail+1)); echo "FAIL 末尾に空白のある行は拒否"; sed 's/^/     /' "$WORK_DIR/out"; else pass=$((pass+1)); echo "ok   末尾に空白のある行は拒否"; fi
git switch --quiet --force-create act origin/main; echo y >> .github/actions/a/action.yml; git commit --quiet --all --message act
expect ng ".github/actions の変更" origin act
git switch --quiet --force-create co origin/main; echo "* @me" > .github/CODEOWNERS; git add --all; git commit --quiet --message co
expect ok "CODEOWNERS の変更" origin co

# 複数の保護ブランチの版を 1 つのコミットで混ぜる（develop にだけあるワークフローと、main の .github/actions）
( cd "$WORK_DIR/seed" && git fetch --quiet && git switch --quiet --force-create dv origin/develop && echo 'on: push' > .github/workflows/dev-only.yml \
  && echo dv >> .github/actions/a/action.yml && git add --all && git commit --quiet --message dv && git push --quiet origin HEAD:develop )
git fetch --quiet
git switch --quiet --force-create mix origin/main; git checkout --quiet origin/develop -- .github/workflows/dev-only.yml; git commit --quiet --message mix
expect ng "main と develop の版を混ぜたコミット" origin mix
git switch --quiet --force-create dvok origin/develop; echo d > d; git add d; git commit --quiet --message dvok
expect ok "develop の内容そのままのコミット" origin dvok
# 2 回に分けても混ぜられない（develop の内容のブランチに、main の .github/actions を載せる）
git checkout --quiet origin/main -- .github/actions; git commit --quiet --message mix2
expect ng "2 回に分けて main と develop の版を混ぜる" origin dvok
# 人間が main と develop のワークフローを直した後、古い版を持つ既存のブランチ
git switch --quiet --force-create stale origin/main; echo s > s; git add s; git commit --quiet --message stale
expect ok "古い版になる前のブランチの作成" origin stale
( cd "$WORK_DIR/seed" && git fetch --quiet && for b in main develop; do git switch --quiet --force-create "fix-$b" "origin/$b" \
  && printf 'on: push\n# fixed\n' > .github/workflows/ci.yml && git commit --quiet --all --message "fix $b" && git push --quiet origin "HEAD:$b"; done )
git fetch --quiet
echo s2 >> s; git commit --quiet --all --message stale2
# 古い版を持つ既存のブランチにも push できない（main に rebase すれば通る）
expect ng "人間が main を直した後の、古い版を持つ既存のブランチへの push" origin stale
stale_tip=$(git rev-parse HEAD)
git rebase --quiet origin/main
expect ok "main に rebase した後の push" --force origin stale
# 古い版を新しいブランチに写すのも拒否
expect ng "古い版を持つ新しいブランチ" origin "$stale_tip:refs/heads/stale-copy"
# ブランチにはコミットだけ（注釈付きタグのオブジェクトは拒否）
git tag --annotate --message t tobj origin/main
expect ng "注釈付きタグのオブジェクトをブランチに" origin "$(git rev-parse tobj):refs/heads/tagobj"
# 受け付けを始めた後に、GitHub の保護ブランチが更新された（push の途中で止めて、古い状態で判定させる手口）
# （フックを直接呼ぶので、ゲートにあるコミットを使う）
( cd "$WORK_DIR/seed" && git fetch --quiet && git switch --quiet --force-create fix2 origin/main && echo '# fix2' >> .github/workflows/ci.yml \
  && git commit --quiet --all --message fix2 && git push --quiet origin HEAD:main )   # ゲートはまだ fetch していない
if printf '%s %s refs/heads/race\n' 0000000000000000000000000000000000000000 "$(git rev-parse origin/main)" \
   | (cd "$WORK_DIR/gate.git" && GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$WORK_DIR/out" 2>&1 || ! grep -q '受け付けを始めた後に GitHub で更新' "$WORK_DIR/out" || gh_has race
then fail=$((fail+1)); echo "FAIL 受け付けの途中で保護ブランチが更新されたら拒否"; sed 's/^/     /' "$WORK_DIR/out"; else pass=$((pass+1)); echo "ok   受け付けの途中で保護ブランチが更新されたら拒否"; fi
git fetch --quiet; git --git-dir="$WORK_DIR/gate.git" fetch --quiet --prune upstream '+refs/heads/*:refs/heads/*'
# 制御文字を含む行（記録に端末の制御シーケンスを書き込ませない）
if printf '%s %s refs/heads/x\033[2Kx\n' 0000000000000000000000000000000000000000 "$(git rev-parse origin/main)" \
   | (cd "$WORK_DIR/gate.git" && GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$WORK_DIR/out" 2>&1 || ! grep -q '制御文字' "$WORK_DIR/out" \
   || LC_ALL=C grep -q "$(printf '\033')" "$WORK_DIR/gate.git/push-gate.log"
then fail=$((fail+1)); echo "FAIL 制御文字を含む行は、記録に書かずに拒否"; sed 's/^/     /' "$WORK_DIR/out"; else pass=$((pass+1)); echo "ok   制御文字を含む行は、記録に書かずに拒否"; fi
# push 以外のコマンドも記録する
SSH_ORIGINAL_COMMAND="$(printf 'ls \033[2K')" GIT_PUSH_GATE_REPO="$WORK_DIR/gate.git" sh "$ROOT/bin/git-push-gate" >/dev/null 2>&1 || true
if grep -q 'REJECTED 許可されていないコマンド' "$WORK_DIR/gate.git/push-gate.log" && ! LC_ALL=C grep -q "$(printf '\033')" "$WORK_DIR/gate.git/push-gate.log"
then pass=$((pass+1)); echo "ok   push 以外のコマンドを、中身を書かずに記録"; else fail=$((fail+1)); echo "FAIL push 以外のコマンドを、中身を書かずに記録"; fi
# 許可する接頭辞
git --git-dir="$WORK_DIR/gate.git" config gate.allowedPrefixes "agent/ claude/"
git switch --quiet --force-create pfx origin/main; echo p > p; git add p; git commit --quiet --message pfx
expect ng "許可されていない接頭辞のブランチ" origin pfx
expect ok "許可された接頭辞のブランチ" origin pfx:refs/heads/agent/pfx
expect ng "許可されていない接頭辞のブランチの削除" origin :stale
git --git-dir="$WORK_DIR/gate.git" config gate.allowedPrefixes "*"
# UTF-8 の C1 制御文字（U+009B は CSI）や、表示の向きを変える文字（U+202E）を含む名前は、記録に書かずに拒否
git switch --quiet --force-create u8 origin/main; echo u > u; git add u; git commit --quiet --message u8
expect ng "C1 制御文字を含む名前" origin "u8:refs/heads/ok$(printf '\302\233')2J"
expect ng "表示の向きを変える文字を含む名前" origin "u8:refs/heads/x$(printf '\342\200\256')/niaM"
if LC_ALL=C grep -q "$(printf '\302\233')\|$(printf '\342\200\256')" "$WORK_DIR/gate.git/push-gate.log"
then fail=$((fail+1)); echo "FAIL ASCII 以外の文字を記録に書かない"; else pass=$((pass+1)); echo "ok   ASCII 以外の文字を記録に書かない"; fi
# GitHub にある同じ名前のタグ（軽量タグと注釈付きタグ）
( cd "$WORK_DIR/seed" && git tag v9 origin/main && git tag --annotate --message t v8 origin/main && git push --quiet origin v9 v8 )
expect ng "軽量タグと同じ名前のブランチ" origin u8:v9
expect ng "注釈付きタグと同じ名前のブランチ" origin u8:refs/heads/v8
expect ok "タグと違う名前のブランチ" origin u8:refs/heads/v7
# 紛らわしい名前・使えない文字
expect ng "大文字の 40 桁の 16 進数の名前" origin "u8:refs/heads/$(git rev-parse origin/main | tr a-f A-F)"
expect ng "heads/ で始まる名前" origin u8:refs/heads/heads/main
expect ng "tags/ で始まる名前（タグ v9 がある）" origin u8:refs/heads/tags/v9
expect ng "シェルの特殊文字を含む名前" origin 'u8:refs/heads/x$(id)'
expect ng "; を含む名前" origin 'u8:refs/heads/a;b'
expect ok "英数字と . _ / - の名前" origin u8:refs/heads/agent/fix-1.2_x
# 変な mode（中身は main と同じ）
ci_blob=$(git ls-tree origin/main .github/workflows/ci.yml | awk '{print $3}')
# mktree は mode を正規化するので、木のオブジェクトを直接作る
workflows_tree=$(python3 -c 'import sys; sys.stdout.buffer.write(b"100600 ci.yml\0" + bytes.fromhex(sys.argv[1]))' "$ci_blob" \
  | git hash-object -t tree -w --literally --stdin)
if [ -n "$workflows_tree" ] && [ "$(git cat-file tree "$workflows_tree" | head -c 6)" = 100600 ]; then
  github_tree=$(git ls-tree origin/main:.github | grep -v '	workflows$' | { cat; printf '040000 tree %s\tworkflows\n' "$workflows_tree"; } | git mktree)
  root_tree=$(git ls-tree origin/main | grep -v '	.github$' | { cat; printf '040000 tree %s\t.github\n' "$github_tree"; } | git mktree)
  expect ng "mode 100600 のワークフロー" origin "$(git commit-tree "$root_tree" -p origin/main -m mode):refs/heads/mode"
else fail=$((fail+1)); echo "FAIL mode 100600 の木を作れませんでした"; fi
expect ng "途中に /refs/ がある名前" origin u8:refs/heads/x/refs/heads/main
expect ng "末尾が /HEAD の名前" origin u8:refs/heads/x/HEAD
expect ng "ないブランチの削除" origin :refs/heads/nonexistent
# 検査の途中でシグナルを受けたら、GitHub に push せずに拒否（検査の子プロセスが止まると、検査をすり抜けるため）
mkfifo "$WORK_DIR/fifo"
(cd "$WORK_DIR/gate.git" && GIT_DIR=. exec sh "$ROOT/hooks/pre-receive") <"$WORK_DIR/fifo" >"$WORK_DIR/out" 2>&1 & hook_pid=$!
exec 8>"$WORK_DIR/fifo"
printf '%s %s refs/heads/sig\n' 0000000000000000000000000000000000000000 "$(git rev-parse origin/main)" >&8
sleep 1; kill -TERM "$hook_pid"; sleep 1; exec 8>&-
if wait "$hook_pid" || ! grep -q '中断されました' "$WORK_DIR/out" || gh_has sig
then fail=$((fail+1)); echo "FAIL シグナルを受けたら push せずに拒否"; sed 's/^/     /' "$WORK_DIR/out"; else pass=$((pass+1)); echo "ok   シグナルを受けたら push せずに拒否"; fi
# 1 行も読まないうちにシグナルを受けても、成功で終わらない（read が途中で終わるため）
mkfifo "$WORK_DIR/fifo2"
(cd "$WORK_DIR/gate.git" && GIT_DIR=. exec sh "$ROOT/hooks/pre-receive") <"$WORK_DIR/fifo2" >"$WORK_DIR/out" 2>&1 & hook_pid=$!
exec 8>"$WORK_DIR/fifo2"; sleep 1; kill -TERM "$hook_pid"; sleep 1; exec 8>&-
if wait "$hook_pid"; then fail=$((fail+1)); echo "FAIL read の最中のシグナルで成功にしない"; else pass=$((pass+1)); echo "ok   read の最中のシグナルで成功にしない"; fi
# 検査に使う子プロセスが失敗しても、すり抜けない（Main を小文字にする tr だけが失敗して空になると、main と一致しない）
mkdir --parents "$WORK_DIR/shim"
printf '#!/bin/sh\nin=$(cat); [ "$in" != Main ] || exit 1\nprintf %%s "$in" | exec %s "$@"\n' "$(command -v tr)" > "$WORK_DIR/shim/tr"
chmod +x "$WORK_DIR/shim/tr"
if printf '%s %s refs/heads/Main\n' 0000000000000000000000000000000000000000 "$(git rev-parse origin/main)" \
   | (cd "$WORK_DIR/gate.git" && PATH="$WORK_DIR/shim:$PATH" GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$WORK_DIR/out" 2>&1 || gh_has Main
then fail=$((fail+1)); echo "FAIL tr が失敗しても Main を拒否"; sed 's/^/     /' "$WORK_DIR/out"; else pass=$((pass+1)); echo "ok   tr が失敗しても Main を拒否"; fi
# 直下に項目がとても多い木も、すぐに判定する（行の数の 2 乗の時間がかかると、ロックを持ったまま動き続ける）
empty_blob=$(git hash-object -w --stdin </dev/null)
big_tree=$( { git ls-tree origin/main; seq 20000 | sed "s/^/100644 blob $empty_blob	f/"; } | git mktree)
start_time=$(date +%s)
expect ok "直下に 20000 個の項目がある木" origin "$(git commit-tree "$big_tree" -p origin/main -m big):refs/heads/big"
elapsed=$(( $(date +%s) - start_time ))
if [ "$elapsed" -le 60 ]; then pass=$((pass+1)); echo "ok   20000 個の項目の判定が 60 秒以内（$elapsed 秒）"; else fail=$((fail+1)); echo "FAIL 20000 個の項目の判定に $elapsed 秒かかった"; fi
# push 証明書の付いた push と、許可する接頭辞の設定がないゲートは拒否
for scenario in cert noprefix; do
  description="push 証明書の付いた push を拒否"
  [ $scenario = cert ] || { description="許可する接頭辞の設定がなければ拒否"; git --git-dir="$WORK_DIR/gate.git" config --unset gate.allowedPrefixes; }
  if printf '%s %s refs/heads/%s\n' 0000000000000000000000000000000000000000 "$(git rev-parse origin/main)" "$scenario" \
     | (cd "$WORK_DIR/gate.git" && if [ $scenario = cert ]; then export GIT_PUSH_CERT=0123; fi; GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$WORK_DIR/out" 2>&1 || gh_has "$scenario" \
     || ! grep -Eq 'push 証明書|gate.allowedPrefixes を読めません' "$WORK_DIR/out"
  then fail=$((fail+1)); echo "FAIL $description"; sed 's/^/     /' "$WORK_DIR/out"; else pass=$((pass+1)); echo "ok   $description"; fi
done
git --git-dir="$WORK_DIR/gate.git" config gate.allowedPrefixes "*"
# 受け取りかけのデータ（止まった receive-pack の残り）と、使われていない緩いオブジェクト（100MB 超）は、次の push の前に消す
GATE_OBJECTS="$WORK_DIR/gate.git/objects"
mkdir --parents "$GATE_OBJECTS/tmp_objdir-incoming-x" "$GATE_OBJECTS/ab"; echo x > "$GATE_OBJECTS/tmp_objdir-incoming-x/tmp_pack_x"
head -c 105000000 /dev/zero > "$GATE_OBJECTS/ab/tmp_obj_x"
git switch --quiet --force-create clean origin/main; echo c > c; git add c; git commit --quiet --message clean
expect ok "掃除の後の push" origin clean
if [ ! -e "$GATE_OBJECTS/tmp_objdir-incoming-x" ] && [ ! -e "$GATE_OBJECTS/ab/tmp_obj_x" ]; then pass=$((pass+1)); echo "ok   受け取りかけのデータと不要なファイルを消す"
else fail=$((fail+1)); echo "FAIL 受け取りかけのデータと不要なファイルを消す"; fi
# 受け取ったものはパックのまま置く（緩いオブジェクトは、どれも使われていないものになる）
if [ "$(git --git-dir="$WORK_DIR/gate.git" count-objects --verbose | sed --quiet 's/^count: //p')" = 0 ]; then pass=$((pass+1)); echo "ok   ゲートに緩いオブジェクトがない"
else fail=$((fail+1)); echo "FAIL ゲートに緩いオブジェクトがある"; git --git-dir="$WORK_DIR/gate.git" count-objects --verbose; fi
# 後から同じ名前のタグができたブランチは、更新はできないが、削除はできる
( cd "$WORK_DIR/seed" && git tag v7 origin/main && git push --quiet origin v7 )
expect ng "タグと同じ名前になったブランチの更新" origin --force origin/main:refs/heads/v7
expect ok "タグと同じ名前になったブランチの削除" origin :refs/heads/v7
# 長すぎる ref 名は、記録に書かずに拒否
long_name=$(printf 'l%.0s' $(seq 300))
expect ng "255 バイトを超える ref 名" origin "u8:refs/heads/$long_name"
if grep -q "$long_name" "$WORK_DIR/gate.git/push-gate.log"
then fail=$((fail+1)); echo "FAIL 長すぎる ref 名を記録に書かない"; else pass=$((pass+1)); echo "ok   長すぎる ref 名を記録に書かない"; fi
# 1 回の push の ref の数は 50 まで
expect ng "51 個の ref を一度に push" origin $(for i in $(seq 51); do printf 'u8:refs/heads/many%s ' "$i"; done)
gh_has many1 && { fail=$((fail+1)); echo "FAIL 51 個のうちどれかが GitHub に届いた"; }
# 判定の間に GitHub の保護ブランチが更新された（ref を送り終える前に人間が main を直す）
# （最後の : は、dash が上の ( ) を fork せずに実行して、push の前にパイプを閉じてしまうのを防ぐ）
# （ゲートにあるコミットを使う。フックを直接呼ぶので、新しいオブジェクトは渡せない）
{ printf '%s %s refs/heads/race2\n' 0000000000000000000000000000000000000000 "$(git rev-parse origin/main)"; sleep 3
  ( cd "$WORK_DIR/seed" && git fetch --quiet && git switch --quiet --force-create fix3 origin/main && echo '# fix3' >> .github/workflows/ci.yml \
    && git commit --quiet --all --message fix3 && git push --quiet origin HEAD:main ) >/dev/null 2>&1
  : ; } \
  | (cd "$WORK_DIR/gate.git" && GIT_DIR=. sh "$ROOT/hooks/pre-receive") >"$WORK_DIR/out" 2>&1 && hook_status=0 || hook_status=1
if [ $hook_status -eq 0 ] || ! grep -q '受け付けを始めた後に GitHub で更新' "$WORK_DIR/out" || gh_has race2
then fail=$((fail+1)); echo "FAIL 判定の間に保護ブランチが更新されたら拒否"; sed 's/^/     /' "$WORK_DIR/out"; else pass=$((pass+1)); echo "ok   判定の間に保護ブランチが更新されたら拒否"; fi
git fetch --quiet; git --git-dir="$WORK_DIR/gate.git" fetch --quiet --prune upstream '+refs/heads/*:refs/heads/*'

# パスフレーズ付きの鍵が未解除のとき
if command -v ssh-agent >/dev/null; then
  eval "$(ssh-agent -a "$WORK_DIR/agent.sock")" >/dev/null
  git --git-dir="$WORK_DIR/gate.git" config gate.agentSocket "$WORK_DIR/agent.sock"
  git switch --quiet --force-create locked origin/main; echo l > l; git add l; git commit --quiet --message l
  expect ng "鍵のロック中" origin locked
  grep -q 'ロックされています' "$WORK_DIR/out" || { echo "FAIL ロックのメッセージがない"; fail=$((fail+1)); }
  ssh-keygen -q -t ed25519 -N '' -f "$WORK_DIR/k"; SSH_AUTH_SOCK="$WORK_DIR/agent.sock" ssh-add -q "$WORK_DIR/k" 2>/dev/null
  expect ok "鍵の解除後" origin locked
  git --git-dir="$WORK_DIR/gate.git" config --unset gate.agentSocket
  kill "$SSH_AGENT_PID"
fi

LOG_FILE="$WORK_DIR/gate.git/push-gate.log"
if grep -v ' REJECTED ' "$LOG_FILE" | grep -q ' refs/heads/feat ' && ! grep -v ' REJECTED ' "$LOG_FILE" | grep -q 'refs/heads/main' \
   && grep ' REJECTED ' "$LOG_FILE" | grep -q 'refs/heads/main への push は禁止'
then pass=$((pass+1)); echo "ok   受け付けた更新と拒否を記録"; else fail=$((fail+1)); echo "FAIL 受け付けた更新と拒否を記録"; sed 's/^/     /' "$LOG_FILE"; fi
# 記録が 10MB を超えたら、拒否は書かない
cp "$LOG_FILE" "$WORK_DIR/log.bak"; head -c 10485760 /dev/zero | tr '\0' x >> "$LOG_FILE"; log_size=$(wc -c < "$LOG_FILE")
expect ng "記録が大きいときの main への push" origin HEAD:main
SSH_ORIGINAL_COMMAND=ls GIT_PUSH_GATE_REPO="$WORK_DIR/gate.git" sh "$ROOT/bin/git-push-gate" >"$WORK_DIR/out" 2>&1 || true
if [ "$(wc -c < "$LOG_FILE")" -eq "$log_size" ]; then pass=$((pass+1)); echo "ok   記録が 10MB を超えたら拒否を書かない"; else fail=$((fail+1)); echo "FAIL 記録が 10MB を超えたら拒否を書かない"; fi
mv "$WORK_DIR/log.bak" "$LOG_FILE"
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
