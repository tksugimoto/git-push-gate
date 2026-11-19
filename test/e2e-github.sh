#!/bin/sh
# e2e テスト用の「GitHub」。git ユーザーの SSH で /home/git/repo.git を公開する。
set -eu
install --owner git --group git --mode 700 --directory /home/git/.ssh
# ゲートの鍵（push 用）とクライアントの鍵（fetch 用。本番では読み取り専用のトークンに相当）
cat /github/authorized_keys /github/client.pub > /home/git/.ssh/authorized_keys
chown git:git /home/git/.ssh/authorized_keys && chmod 600 /home/git/.ssh/authorized_keys

BARE_REPO=/home/git/repo.git
git init --quiet --bare --initial-branch main "$BARE_REPO"
SEED_DIR=$(mktemp --directory)
git -C "$SEED_DIR" init --quiet --initial-branch main
mkdir --parents "$SEED_DIR/.github/workflows"
printf 'on: push\npermissions: {contents: read}\njobs: {}\n' > "$SEED_DIR/.github/workflows/ci.yml"
echo seed > "$SEED_DIR/README"
git -C "$SEED_DIR" add --all
git -C "$SEED_DIR" -c user.name=t -c user.email=t@example.com commit --quiet --message init
git -C "$SEED_DIR" push --quiet "$BARE_REPO" main main:develop
chown --recursive git:git "$BARE_REPO"

ssh-keygen -A >/dev/null
exec /usr/sbin/sshd -D -e
