#!/bin/sh
set -eu
# オプションはなるべく長い形で書く（短い形のままのものは、busybox・OpenSSH・git に長い形がないもの）
fail() { echo "entrypoint: $*" >&2; exit 1; }
: "${UPSTREAM:?例: git@github.com:owner/repo.git}"
protected_branches="${PROTECTED_BRANCHES:-main develop}"   # 既定値はここだけ（フックは gate.protected を読む）
case "$protected_branches" in
  *[*?[]*) fail "PROTECTED_BRANCHES にパターンは使えません（ブランチ名を完全一致で列挙）: $protected_branches" ;;
esac
# 空白だけなどで 0 件になると何も守らないので拒否。区切りは空白 1 つにそろえる（パターンは上で拒否済み）
# shellcheck disable=SC2086
set -- $protected_branches; [ $# -gt 0 ] || fail "PROTECTED_BRANCHES が空です"; protected_branches="$*"; set --
CONFIG_DIR=/config          # github_key, client_keys.pub, known_hosts を置いたディレクトリ（読み取り専用でマウント）
REPO=/srv/git/repo.git  # root で操作できるよう、Dockerfile で safe.directory に登録してある
gate_git() { git --git-dir="$REPO" "$@"; }

for file in github_key known_hosts; do
  [ -s "$CONFIG_DIR/$file" ] || fail "$CONFIG_DIR/$file がありません"
done
[ -f "$CONFIG_DIR/client_keys.pub" ] || fail "$CONFIG_DIR/client_keys.pub がありません（空のファイルでよい）"

GITHUB_KEY=/home/git/.ssh/github_key
AGENT_DIR=/run/git-push-gate
# 止まった接続が後の push をすべて待たせないよう、タイムアウトを付ける（BatchMode: 対話的な入力を求めない）
SSH_OPTIONS="-o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/ssh/github_known_hosts -o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

# GitHub 用の秘密鍵とホスト鍵（git ユーザーだけが読める）
install --owner git --group git --mode 600 "$CONFIG_DIR/github_key" "$GITHUB_KEY"
install --owner root --group root --mode 644 "$CONFIG_DIR/known_hosts" /etc/ssh/github_known_hosts

if ssh-keygen -y -P '' -f "$GITHUB_KEY" >/dev/null 2>&1; then
  # パスフレーズなし: 鍵ファイルを直接使う
  ssh_command="ssh -i $GITHUB_KEY $SSH_OPTIONS"
  agent_socket=""
else
  # パスフレーズ付き: コンテナ内の ssh-agent に、人間が unlock で一度だけ読み込ませる
  [ -s "$CONFIG_DIR/github_key.pub" ] || fail "パスフレーズ付きの鍵には $CONFIG_DIR/github_key.pub も必要です"
  install --owner git --group git --mode 644 "$CONFIG_DIR/github_key.pub" "$GITHUB_KEY.pub"
  install --directory --owner git --group git --mode 700 "$AGENT_DIR"
  agent_socket="$AGENT_DIR/agent.sock"
  rm -f "$agent_socket"
  su -s /bin/sh git -c "ssh-agent -a $agent_socket" >/dev/null
  # -i に公開鍵を渡すと、エージェント内の対応する鍵だけを使う
  ssh_command="ssh -i $GITHUB_KEY.pub -o IdentityAgent=$agent_socket $SSH_OPTIONS"
  echo "entrypoint: 鍵はロックされています。ホストで次を実行してください: docker compose exec git-push-gate unlock" >&2
fi

# クライアント（devcontainer）の公開鍵を、強制コマンド付きで登録
client_keys=$(grep -Ev '^[[:space:]]*(#|$)' "$CONFIG_DIR/client_keys.pub" || true)
# 1 行に 1 つの公開鍵（種類、base64、省略できるコメント）だけを許す。オプション（from= など）付きの行や、
# 人間がエージェントの出力を貼るときに紛れ込んだ余計な文字は、起動を止めて知らせる
# 空でも起動する（devcontainer の client/setup.sh が鍵を作るには、先にゲートのホスト鍵が要るため）。誰も push できない
[ -n "$client_keys" ] || echo "entrypoint: 警告: $CONFIG_DIR/client_keys.pub に公開鍵がないので、まだ誰も push できません" >&2
key_line='(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+=*( [A-Za-z0-9@._-]+)?'
if [ -n "$client_keys" ] && printf '%s\n' "$client_keys" | grep -Evxq "$key_line"; then
  fail "$CONFIG_DIR/client_keys.pub には、「種類 公開鍵 [コメント]」の形の行だけを書いてください（オプションや余計な文字は使えない）"
fi
if [ -n "$client_keys" ]; then
  printf '%s\n' "$client_keys" | sed 's|^|command="/usr/local/bin/git-push-gate",restrict |' > /home/git/.ssh/authorized_keys
else
  : > /home/git/.ssh/authorized_keys
fi
chown git:git /home/git/.ssh/authorized_keys && chmod 600 /home/git/.ssh/authorized_keys
# 登録した鍵のフィンガープリントを出す（docker compose logs で、意図した鍵だけか確かめられる）
if [ -n "$client_keys" ]; then
  echo "entrypoint: 登録したクライアントの鍵:" >&2
  ssh-keygen -l -f /home/git/.ssh/authorized_keys >&2 || fail "クライアントの鍵を読めません"
fi

[ -d "$REPO" ] || git init --quiet --bare "$REPO"
# /srv/git は git ユーザーの持ち物なので、root が書き込む前に、シンボリックリンクに差し替えられていないか確かめる
for path in "$REPO" "$REPO/config" "$REPO/hooks" "$REPO/hooks/pre-receive"; do
  [ ! -L "$path" ] || fail "$path がシンボリックリンクです"
done
gate_git config remote.upstream.url "$UPSTREAM"   # fetch refspec は付けない
gate_git config core.sshCommand "$ssh_command"
if [ -n "$agent_socket" ]; then
  gate_git config gate.agentSocket "$agent_socket"
else
  gate_git config --unset gate.agentSocket || true
fi
gate_git config gate.protected "$protected_branches"
# 許可する接頭辞（空白区切り。例: "agent/ claude/"）。設定すると、それ以外のブランチは作成・更新・削除させない
allowed_prefixes="${ALLOWED_BRANCH_PREFIXES:-}"
case "$allowed_prefixes" in
  *[*?[]*) fail "ALLOWED_BRANCH_PREFIXES にパターンは使えません（接頭辞を列挙）: $allowed_prefixes" ;;
esac
# shellcheck disable=SC2086
set -- $allowed_prefixes; allowed_prefixes="$*"; set --
# 制限なしは「*」と書く（フックは、設定を読めなければ拒否する。パターンは上で拒否しているので取り違えない）
gate_git config gate.allowedPrefixes "${allowed_prefixes:-*}"
# 壊れたオブジェクト（同じ名前の項目が 2 つある木など）は受け付けない
gate_git config receive.fsckObjects true
# 変な mode（40777 や 100600 など）も拒否する（既定では警告だけで、ls-tree は正規化して表示する）
gate_git config receive.fsck.badFilemode error
# bare リポジトリの HEAD が指すブランチ（master など）の削除を receive-pack が拒否すると、
# GitHub では削除済みなのにクライアントには失敗と返るので、拒否させない（保護は pre-receive が行う）
gate_git config receive.denyDeleteCurrent ignore
# receive-pack が裏で起動する gc は、ロックのファイル記述子を引き継いで次の push を待たせるので止める
gate_git config receive.autogc false
# 受け付ける大きさの上限（ボリュームを埋められないように）
gate_git config receive.maxInputSize "${MAX_PUSH_SIZE:-500m}"
# 受け取ったもの（fetch と push）は常にパックのまま置き、緩いオブジェクトにしない。
# 緩いオブジェクトがあれば、どれも使われていないもの（拒否した push の証明書など）と分かり、すぐ消せる
gate_git config fetch.unpackLimit 1
gate_git config receive.unpackLimit 1
install --owner root --group root --mode 755 /usr/local/share/git-push-gate/pre-receive "$REPO/hooks/pre-receive"
chown --recursive --no-dereference git:git "$REPO"   # シンボリックリンクの先を変えない
chown --no-dereference root:root "$REPO/hooks" "$REPO/hooks/pre-receive" "$REPO/config"
chmod 644 "$REPO/config"

# ホスト鍵はボリュームに置き、コンテナを作り直しても変わらないようにする（クライアントの known_hosts が合うように）
HOST_KEY_DIR=/srv/git/ssh_host_keys
install --directory --owner root --group root --mode 700 "$HOST_KEY_DIR"
[ -s "$HOST_KEY_DIR/ssh_host_ed25519_key" ] || ssh-keygen -q -t ed25519 -N '' -C git-push-gate -f "$HOST_KEY_DIR/ssh_host_ed25519_key"

# 最初の fetch（全履歴）は時間がかかるので、push の前に時間制限なしで済ませておく。
# UPSTREAM・鍵・known_hosts の間違いもここで分かる。パスフレーズ付きの鍵は unlock の後に行う
if [ -z "$agent_socket" ]; then
  su -s /bin/sh git -c "git --git-dir=$REPO fetch --prune --no-tags --quiet upstream '+refs/heads/*:refs/heads/*'" \
    || echo "entrypoint: 警告: GitHub から fetch できません（UPSTREAM・鍵・known_hosts を確認してください）" >&2
fi
# push の中では gc を止めているので、起動時に整理する（push を受け付ける前なのでロックは要らない）。
# どこからも使われていないオブジェクト（拒否された push の証明書など）も、すぐ消す（ゲートは GitHub の写しなので、消して困るものはない）
# 前の版で作られた、使われている緩いオブジェクトはパックにまとめる（repack -d）
su -s /bin/sh git -c "git --git-dir=$REPO gc --auto --quiet && git --git-dir=$REPO prune --expire=now && git --git-dir=$REPO repack -d --quiet" \
  || echo "entrypoint: 警告: gc に失敗しました" >&2
exec /usr/sbin/sshd -D -e -h "$HOST_KEY_DIR/ssh_host_ed25519_key"
