#!/bin/sh
# devcontainer の中で、ワークスペースのディレクトリで実行し、push 先を git-push-gate に向ける（ホストでは実行しない）。
# 人間が統合ターミナルで実行しても、AI エージェントに頼んでもよい（秘密の情報は使わない）。
#
#   sh setup.sh <ゲートのアドレス> <ポート> '<ゲートのホスト鍵>'
#   例: sh setup.sh host.docker.internal 2222 'ssh-ed25519 AAAA...'
#
# クライアント用の鍵は devcontainer の中で作り、秘密鍵は外に出さない。表示される公開鍵を、
# 人間がゲートの /config にマウントしたディレクトリの client_keys.pub に足して、ゲートを再起動する。
# 書き込むのは ~/.ssh と .git/config だけで、利用側のリポジトリにコミットされるものはない。
set -eu
# オプションはなるべく長い形で書く（短い形のままのものは、busybox や OpenSSH に長い形がないもの）
[ $# -eq 3 ] || { echo "使い方: sh setup.sh <ゲートのアドレス> <ポート> '<ゲートのホスト鍵>'" >&2; exit 1; }
gate_host=$1; gate_port=$2
set -f; set -- $3   # 「種類 鍵 [コメント]」の形（ゲートの .pub をそのまま貼ってよい）
host_key_type=${1:-}; host_key_data=${2:-}
case "$gate_host" in ''|*[!A-Za-z0-9.:-]*) echo "アドレスが不正です: $gate_host" >&2; exit 1 ;; esac
case "$gate_port" in ''|*[!0-9]*) echo "ポートが不正です: $gate_port" >&2; exit 1 ;; esac
[ "$gate_port" -ge 1 ] && [ "$gate_port" -le 65535 ] || { echo "ポートが不正です: $gate_port" >&2; exit 1; }
case "$host_key_type" in ssh-ed25519) ;; *) echo "ホスト鍵は ssh-ed25519 の公開鍵を指定してください" >&2; exit 1 ;; esac
case "$host_key_data" in ''|*[!A-Za-z0-9+/=]*) echo "ホスト鍵が不正です" >&2; exit 1 ;; esac
# 何かを書き込む前に、git のリポジトリの中で、push 先を変える remote があることを確かめる
remote_name=${REMOTE:-origin}
git rev-parse --git-dir >/dev/null || { echo "git のリポジトリ（ワークスペース）のディレクトリで実行してください" >&2; exit 1; }
git remote get-url "$remote_name" >/dev/null || { echo "remote $remote_name がありません（環境変数 REMOTE で指定できます）" >&2; exit 1; }

umask 077
mkdir --parents ~/.ssh
[ -f ~/.ssh/git-push-gate ] || ssh-keygen -q -t ed25519 -N '' -C git-push-gate-client -f ~/.ssh/git-push-gate
# 公開鍵のファイルがなくなっていたら、秘密鍵から作り直す
if [ ! -s ~/.ssh/git-push-gate.pub ]; then
  public_key=$(ssh-keygen -y -f ~/.ssh/git-push-gate) && [ -n "$public_key" ] \
    || { echo "~/.ssh/git-push-gate を読めません。消してからやり直してください" >&2; exit 1; }
  # ssh-keygen -y はコメントも出すことがあるので、種類と鍵だけを取り、コメントを付け直す（ゲートはコメントを 1 つまでしか許さない）
  set -- $public_key
  printf '%s %s git-push-gate-client\n' "$1" "$2" > ~/.ssh/git-push-gate.pub
fi
printf 'git-push-gate %s %s\n' "$host_key_type" "$host_key_data" > ~/.ssh/git-push-gate_known_hosts
# SSH エージェントは使わず（IdentityAgent none）、この鍵とホスト鍵だけを使う。
# ~/.ssh/config の Host * にある ProxyCommand や ForwardAgent も、ここで打ち消す（先に書いた値が使われる）
cat > ~/.ssh/git-push-gate.conf <<EOF
Host git-push-gate
  HostName $gate_host
  Port $gate_port
  User git
  IdentityFile ~/.ssh/git-push-gate
  IdentitiesOnly yes
  IdentityAgent none
  HostKeyAlias git-push-gate
  UserKnownHostsFile ~/.ssh/git-push-gate_known_hosts
  StrictHostKeyChecking yes
  ProxyCommand none
  ProxyJump none
  ForwardAgent no
EOF
# Include は Host より前に置く必要があるので、先頭に足す
if ! grep -qx 'Include ~/.ssh/git-push-gate.conf' ~/.ssh/config 2>/dev/null; then
  { echo 'Include ~/.ssh/git-push-gate.conf'; cat ~/.ssh/config 2>/dev/null || true; } > ~/.ssh/config.new
  mv ~/.ssh/config.new ~/.ssh/config
fi
git remote set-url --push "$remote_name" ssh://git@git-push-gate/repo.git

echo "push 先を git-push-gate（$gate_host:$gate_port）にしました。"
echo "まだなら、次の 1 行（公開鍵）を、ホストでエディタを使って、ゲートの /config にマウントしたディレクトリの client_keys.pub に足し、ゲートを再起動してください:"
cat ~/.ssh/git-push-gate.pub
