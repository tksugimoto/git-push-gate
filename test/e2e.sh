#!/bin/sh
# コンテナを使った e2e テスト。必要なのは Docker だけ。
# イメージ自身を「GitHub」（SSH の git サーバー）とクライアントにも使い、本物の entrypoint・sshd を通す。
#   docker build --tag git-push-gate:test . && sh test/e2e.sh
set -eu
IMAGE="${IMAGE:-git-push-gate:test}"
GITHUB_IMAGE="$IMAGE-https-github"   # 「GitHub」役。HTTPS でも公開するため、lighttpd などを足したもの
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONTAINER_PREFIX="gpg-e2e-$$"            # コンテナ名・ネットワーク名の接頭辞
WORK_DIR=$(mktemp -d)   # ホストで動く部分は、macOS でも動くよう短い形のオプションにする
NETWORK="$CONTAINER_PREFIX-net"

cleanup() {
  docker rm --force "$CONTAINER_PREFIX-github" "$CONTAINER_PREFIX-gate" "$CONTAINER_PREFIX-dev" >/dev/null 2>&1 || true
  docker volume rm --force "$CONTAINER_PREFIX-data" >/dev/null 2>&1 || true
  [ ! -f "$WORK_DIR/clone/compose.yaml" ] || compose down --volumes --rmi local >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  # コンテナ内で root が作ったファイルを消す
  docker run --rm --volume "$WORK_DIR:/w" --entrypoint sh "$IMAGE" -c 'rm -rf /w/* /w/.[!.]*' >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# イメージの中でコマンドを実行する（$WORK_DIR を /w にマウント。RUN_NETWORK でネットワークを変えられる）
run() {
  docker run --rm --network "${RUN_NETWORK:-$NETWORK}" --volume "$WORK_DIR:/w" --entrypoint sh \
    --env GIT_AUTHOR_NAME=t --env GIT_AUTHOR_EMAIL=t@example.com --env GIT_COMMITTER_NAME=t --env GIT_COMMITTER_EMAIL=t@example.com \
    "$IMAGE" -c "$1"
}
# clone に見立てたディレクトリで docker compose を実行する（下の「トップの compose.yaml」）
compose() { (cd "$WORK_DIR/clone" && env -u UPSTREAM docker compose --project-name "$CONTAINER_PREFIX-compose" "$@"); }
# クライアントの ssh（鍵と known_hosts をそのまま指定）
CLIENT_SSH='ssh -i /w/client/id_ed25519 -o "UserKnownHostsFile=/w/config/known_hosts /w/client/known_hosts_gate"'

pass=0; fail=0
check() { # check 説明 条件（$WORK_DIR/out に出力を書くと、失敗時に表示する）
  : > "$WORK_DIR/out"
  if eval "$2"; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1"; sed 's/^/     /' "$WORK_DIR/out"; fi
}

# プロキシ経由でしか外に出られない環境では、ビルドにもプロキシを渡す
docker build --quiet ${HTTPS_PROXY:+--network host --build-arg HTTPS_PROXY="$HTTPS_PROXY" --build-arg https_proxy="$HTTPS_PROXY"} \
  --build-arg IMAGE="$IMAGE" --tag "$GITHUB_IMAGE" "$ROOT/test/https-github" >/dev/null
docker network create "$NETWORK" >/dev/null
mkdir -p "$WORK_DIR/config" "$WORK_DIR/client" "$WORK_DIR/github/tls"
cp "$ROOT/test/e2e-github.sh" "$WORK_DIR/github/start.sh"

# 鍵: GitHub 用（パスフレーズなし・付き）、クライアント用
run 'ssh-keygen -q -t ed25519 -N "" -C gate -f /w/github_key_plain
     ssh-keygen -q -t ed25519 -N secret -C gate-pp -f /w/github_key_pp
     ssh-keygen -q -t ed25519 -N "" -C client -f /w/client/id_ed25519
     cat /w/github_key_plain.pub /w/github_key_pp.pub > /w/github/authorized_keys
     cp /w/client/id_ed25519.pub /w/github/client.pub
     cp /w/client/id_ed25519.pub /w/config/client_keys.pub'

# 「GitHub」の HTTPS の証明書と、PAT（Basic 認証のパスワード）
GITHUB_TOKEN=github_pat_e2eTEST0123456789abcdefghijklmnop
docker run --rm --volume "$WORK_DIR:/w" --entrypoint sh "$GITHUB_IMAGE" -c "set -e
  openssl req -x509 -newkey ed25519 -nodes -days 1 -subj /CN=github.com -addext subjectAltName=DNS:github.com \
    -keyout /w/github/tls/key.pem -out /w/github/tls/cert.pem 2>/dev/null
  cat /w/github/tls/key.pem /w/github/tls/cert.pem > /w/github/tls/server.pem
  echo x-access-token:$GITHUB_TOKEN > /w/github/tls/users
  chmod 644 /w/github/tls/*"

# 「GitHub」: ネットワーク上の名前は github.com
docker run --detach --name "$CONTAINER_PREFIX-github" --network "$NETWORK" --network-alias github.com \
  --volume "$WORK_DIR/github:/github:ro" --entrypoint sh "$GITHUB_IMAGE" /github/start.sh >/dev/null

wait_ssh() { # wait_ssh ホスト名 コンテナ → known_hosts の行を出力
  run "for i in \$(seq 30); do ssh-keyscan -t ed25519 $1 2>/dev/null | grep . && exit 0; sleep 1; done; exit 1" \
    || { echo "$1 の sshd が起動しません" >&2; docker logs "$2" >&2; exit 1; }
}
wait_ssh github.com "$CONTAINER_PREFIX-github" > "$WORK_DIR/config/known_hosts"

# ゲートを通る push 用に、保護ブランチ main の .github/workflows/ci.yml を取り出しておく。
# エージェントのブランチの .github は保護ブランチと完全に同一でないと拒否されるので（空や部分集合は不可）、
# clone せずに作るブランチ（下の bridge / viacompose / viasetup）には、この版をそのまま同梱する
docker exec "$CONTAINER_PREFIX-github" git --git-dir=/home/git/repo.git show main:.github/workflows/ci.yml > "$WORK_DIR/gate_ci.yml"

start_gate() { # start_gate 鍵ファイル名 [追加の docker run 引数...]
  key_file=$1; shift
  docker rm --force "$CONTAINER_PREFIX-gate" >/dev/null 2>&1 || true
  run "cp /w/$key_file /w/config/github_key && cp /w/$key_file.pub /w/config/github_key.pub"
  docker run --detach --name "$CONTAINER_PREFIX-gate" --network "$NETWORK" --network-alias gate \
    --env UPSTREAM=git@github.com:repo.git --volume "$WORK_DIR/config:/config:ro" --volume "$CONTAINER_PREFIX-data:/srv/git" \
    "$@" "$IMAGE" >/dev/null
  wait_ssh gate "$CONTAINER_PREFIX-gate" > "$WORK_DIR/client/known_hosts_gate"
}

# クライアント（devcontainer 相当）。fetch は「GitHub」から直接、push はゲートへ。
client() {
  run "set -e; export GIT_SSH_COMMAND='$CLIENT_SSH'
    git clone --quiet git@github.com:repo.git /tmp/dev && cd /tmp/dev
    git remote set-url --push origin ssh://git@gate/repo.git
    $1" >"$WORK_DIR/out" 2>&1
}
gh_has() { docker exec "$CONTAINER_PREFIX-github" git --git-dir=/home/git/repo.git rev-parse --quiet --verify "refs/heads/$1" >/dev/null; }
commit() { echo "echo $1 > $1 && git add $1 && git commit --quiet --message $1"; }

gate_has() { docker exec "$CONTAINER_PREFIX-gate" git --git-dir=/srv/git/repo.git rev-parse --quiet --verify "refs/heads/$1" >/dev/null; }
# --- パスフレーズなしの鍵 ---
start_gate github_key_plain
check "起動時に GitHub を fetch している" 'gate_has develop'

check "feature ブランチの push が GitHub に届く" \
  'client "git switch --quiet --create feat && $(commit a) && git push --quiet origin feat" && gh_has feat'
check "main への push は拒否" \
  '! client "$(commit b) && git push --quiet origin HEAD:main" && grep -q git-push-gate: "$WORK_DIR/out"'
check "ワークフローの変更は拒否" \
  '! client "echo \"# x\" >> .github/workflows/ci.yml && git commit --quiet --all --message wf && git push --quiet origin HEAD:refs/heads/wf" && grep -q git-push-gate: "$WORK_DIR/out" && ! gh_has wf'
check "任意のコマンドは拒否" \
  '! run "$CLIENT_SSH git@gate cat /etc/passwd" >"$WORK_DIR/out" 2>&1 && grep -q 許可されていません "$WORK_DIR/out" && ! grep -q root: "$WORK_DIR/out"'
check "ゲートからの clone（upload-pack）は拒否" \
  '! run "GIT_SSH_COMMAND='"'"'$CLIENT_SSH'"'"' git clone --quiet ssh://git@gate/repo.git /tmp/x" >"$WORK_DIR/out" 2>&1 && grep -q 許可されていません "$WORK_DIR/out"'
check "登録されていない鍵は拒否" \
  '! run "ssh-keygen -q -t ed25519 -N \"\" -f /tmp/k && ssh -i /tmp/k -o BatchMode=yes -o UserKnownHostsFile=/w/client/known_hosts_gate git@gate git-receive-pack /repo.git" >"$WORK_DIR/out" 2>&1 && grep -q "Permission denied" "$WORK_DIR/out"'

docker restart "$CONTAINER_PREFIX-gate" >/dev/null
wait_ssh gate "$CONTAINER_PREFIX-gate" >/dev/null
check "再起動後も push できる" \
  'client "git switch --quiet --create feat2 && $(commit c) && git push --quiet origin feat2" && gh_has feat2'

# compose を使わない devcontainer（既定の bridge で名前解決なし）から、ホストに公開したポート経由で push
cp "$WORK_DIR/client/known_hosts_gate" "$WORK_DIR/known_hosts_gate_before"
BRIDGE_GATEWAY=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')
start_gate github_key_plain --publish "$BRIDGE_GATEWAY::22"
check "コンテナを作り直してもホスト鍵が変わらない" 'cmp "$WORK_DIR/client/known_hosts_gate" "$WORK_DIR/known_hosts_gate_before"'
GATE_PORT=$(docker port "$CONTAINER_PREFIX-gate" 22/tcp | sed 's/.*://' | head -n1)
check "既定の bridge からゲートウェイ経由で push できる" 'RUN_NETWORK=bridge run "set -e
    gateway=\$(ip route | awk \"/default/{print \\\$3}\")
    git init --quiet --initial-branch bridge /tmp/d && cd /tmp/d && mkdir -p .github/workflows && cp /w/gate_ci.yml .github/workflows/ci.yml && git add .github/workflows/ci.yml && $(commit x)
    GIT_SSH_COMMAND='"'"'$CLIENT_SSH -o HostKeyAlias=gate'"'"' git push --quiet ssh://git@\$gateway:$GATE_PORT/repo.git bridge" >"$WORK_DIR/out" 2>&1 && gh_has bridge'

# トップの compose.yaml: clone したディレクトリに .env と config/ を置いて docker compose up する
CLONE_DIR="$WORK_DIR/clone"
COMPOSE_PORT=$((20000 + $$ % 20000))
mkdir -p "$CLONE_DIR"
(cd "$ROOT" && tar --exclude .git --exclude config --exclude .env -cf - .) | (cd "$CLONE_DIR" && tar -xf -)
check "UPSTREAM を書かないと、compose は起動しない" \
  '! compose config >"$WORK_DIR/out" 2>&1 && grep -q "UPSTREAM=" "$WORK_DIR/out"'
check ".env と config/ は git の管理から外れている" \
  'git -C "$ROOT" check-ignore --quiet .env && git -C "$ROOT" check-ignore --quiet config/github_key'
mkdir "$CLONE_DIR/config"
run "cp /w/github_key_plain /w/clone/config/github_key && cp /w/config/known_hosts /w/config/client_keys.pub /w/clone/config/"
printf 'UPSTREAM=git@github.com:repo.git\nGATE_BIND=%s\nGATE_PORT=%s\n' "$BRIDGE_GATEWAY" "$COMPOSE_PORT" > "$CLONE_DIR/.env"
# テストの「GitHub」に届くよう、テスト用のネットワークにもつなぐ（compose.override.yaml は自動で読まれる）
printf 'services:\n  git-push-gate:\n    networks: [default, e2e]\nnetworks:\n  e2e:\n    name: %s\n    external: true\n' "$NETWORK" > "$CLONE_DIR/compose.override.yaml"
# compose がビルドする（プロキシ経由でしか外に出られない環境では、compose と同じ名前で先にビルドしておく）
if [ -n "${HTTPS_PROXY:-}" ]; then
  docker build --quiet --network host --build-arg HTTPS_PROXY="$HTTPS_PROXY" --build-arg https_proxy="$HTTPS_PROXY" \
    --tag "$CONTAINER_PREFIX-compose-git-push-gate" "$CLONE_DIR" >/dev/null
  compose_build=""
else
  compose_build="--build"
fi
compose up --detach $compose_build --quiet-pull >"$WORK_DIR/compose-up.log" 2>&1 || { cat "$WORK_DIR/compose-up.log" >&2; exit 1; }
RUN_NETWORK=bridge run "for i in \$(seq 30); do ssh-keyscan -p $COMPOSE_PORT -t ed25519 $BRIDGE_GATEWAY 2>/dev/null | grep . && exit 0; sleep 1; done; exit 1" \
  | sed 's/^[^ ]*/compose-gate/' > "$WORK_DIR/known_hosts_compose"
check "compose で起動したゲートが、起動時に GitHub を fetch している" \
  'compose exec -T git-push-gate git --git-dir=/srv/git/repo.git rev-parse --quiet --verify refs/heads/develop >"$WORK_DIR/out" 2>&1'
COMPOSE_SSH="ssh -i /w/client/id_ed25519 -o UserKnownHostsFile=/w/known_hosts_compose -o HostKeyAlias=compose-gate"
check "compose で起動したゲートに、公開したポート経由で push できる" 'RUN_NETWORK=bridge run "set -e
    git init --quiet --initial-branch viacompose /tmp/d && cd /tmp/d && mkdir -p .github/workflows && cp /w/gate_ci.yml .github/workflows/ci.yml && git add .github/workflows/ci.yml && $(commit x)
    GIT_SSH_COMMAND='"'"'$COMPOSE_SSH'"'"' git push --quiet ssh://git@$BRIDGE_GATEWAY:$COMPOSE_PORT/repo.git viacompose" >"$WORK_DIR/out" 2>&1 && gh_has viacompose'
check "compose で起動したゲートも、main への push は拒否" '! RUN_NETWORK=bridge run "set -e
    git init --quiet --initial-branch main /tmp/d && cd /tmp/d && $(commit y)
    GIT_SSH_COMMAND='"'"'$COMPOSE_SSH'"'"' git push --quiet --force ssh://git@$BRIDGE_GATEWAY:$COMPOSE_PORT/repo.git main" >"$WORK_DIR/out" 2>&1 && grep -q git-push-gate: "$WORK_DIR/out"'
compose down --volumes --rmi local >/dev/null 2>&1

# client/setup.sh: devcontainer に見立てたコンテナの中で実行し、push 先をゲートに向ける
docker run --detach --name "$CONTAINER_PREFIX-dev" --network "$NETWORK" --volume "$ROOT/client:/client:ro" --volume "$WORK_DIR:/w:ro" \
  --entrypoint sh "$IMAGE" -c 'adduser -D -u 1001 dev && sleep 1000000' >/dev/null
until docker exec "$CONTAINER_PREFIX-dev" id dev >/dev/null 2>&1; do sleep 1; done
docker exec --user dev "$CONTAINER_PREFIX-dev" sh -c "mkdir /home/dev/ws && cd /home/dev/ws && git init --quiet --initial-branch viasetup &&
  git remote add origin https://github.invalid/repo.git &&
  mkdir -p .github/workflows && cp /w/gate_ci.yml .github/workflows/ci.yml && git add .github/workflows/ci.yml &&
  $(commit x | sed 's/git commit/git -c user.name=t -c user.email=t@example.com commit/')"
gate_host_key=$(docker exec "$CONTAINER_PREFIX-gate" cat /srv/git/ssh_host_keys/ssh_host_ed25519_key.pub)
setup() { docker exec --user dev --workdir /home/dev/ws "$CONTAINER_PREFIX-dev" sh /client/setup.sh gate 22 "$gate_host_key"; }
check "git のリポジトリの外では、何も書かずに止まる" \
  '! docker exec --user dev --workdir /tmp "$CONTAINER_PREFIX-dev" sh /client/setup.sh gate 22 "$gate_host_key" >"$WORK_DIR/out" 2>&1 &&
   ! docker exec "$CONTAINER_PREFIX-dev" test -e /home/dev/.ssh/git-push-gate'
check "存在しない remote では、何も書かずに止まる" \
  '! docker exec --user dev --workdir /home/dev/ws --env REMOTE=nope "$CONTAINER_PREFIX-dev" sh /client/setup.sh gate 22 "$gate_host_key" >"$WORK_DIR/out" 2>&1 &&
   ! docker exec "$CONTAINER_PREFIX-dev" test -e /home/dev/.ssh/git-push-gate'
check "setup.sh が公開鍵を表示する" 'setup >"$WORK_DIR/out" 2>&1 && grep -q "^ssh-ed25519 .* git-push-gate-client$" "$WORK_DIR/out"'
client_public_key=$(grep '^ssh-ed25519 .* git-push-gate-client$' "$WORK_DIR/out")
check "公開鍵を登録する前は push できない" \
  '! docker exec --user dev --workdir /home/dev/ws "$CONTAINER_PREFIX-dev" git push --quiet origin viasetup >"$WORK_DIR/out" 2>&1 && ! gh_has viasetup'
run "echo '$client_public_key' >> /w/config/client_keys.pub"
docker restart "$CONTAINER_PREFIX-gate" >/dev/null; wait_ssh gate "$CONTAINER_PREFIX-gate" >/dev/null
check "公開鍵を登録した後は、setup.sh で設定した devcontainer から push できる" \
  'docker exec --user dev --workdir /home/dev/ws "$CONTAINER_PREFIX-dev" git push --quiet origin viasetup >"$WORK_DIR/out" 2>&1 && gh_has viasetup'
check "setup.sh を 2 回実行しても、鍵を作り直さず（公開鍵のファイルがなくても）、設定も重複しない" \
  'docker exec --user dev "$CONTAINER_PREFIX-dev" rm /home/dev/.ssh/git-push-gate.pub &&
   setup >"$WORK_DIR/out" 2>&1 && grep -qxF "$client_public_key" "$WORK_DIR/out" &&
   [ "$(docker exec --user dev "$CONTAINER_PREFIX-dev" grep -c git-push-gate.conf /home/dev/.ssh/config)" = 1 ]'
check "setup.sh は不正なホスト鍵を拒否する" \
  '! docker exec --user dev --workdir /home/dev/ws "$CONTAINER_PREFIX-dev" sh /client/setup.sh gate 22 "ssh-rsa AAAA" >"$WORK_DIR/out" 2>&1'
docker rm --force "$CONTAINER_PREFIX-dev" >/dev/null
# client_keys.pub に、公開鍵の形でない行（エージェントの出力を貼るときに紛れた文字など）があれば起動しない
cp "$WORK_DIR/config/client_keys.pub" "$WORK_DIR/client_keys.pub.ok"
run "printf '%s\\n' 'ssh-ed25519 AAAA\$(id) x' >> /w/config/client_keys.pub"
docker restart "$CONTAINER_PREFIX-gate" >/dev/null; sleep 3
check "client_keys.pub に公開鍵の形でない行があれば、ゲートは起動しない" \
  '[ "$(docker inspect --format "{{.State.Running}}" "$CONTAINER_PREFIX-gate")" = false ] &&
   docker logs "$CONTAINER_PREFIX-gate" 2>&1 | grep -q "種類 公開鍵"'
run "cp /w/client_keys.pub.ok /w/config/client_keys.pub"
docker start "$CONTAINER_PREFIX-gate" >/dev/null; wait_ssh gate "$CONTAINER_PREFIX-gate" >/dev/null
check "起動時に、登録したクライアントの鍵のフィンガープリントを出す" \
  'docker logs "$CONTAINER_PREFIX-gate" 2>&1 | grep -q "SHA256:.*git-push-gate-client"'

# --- PAT（HTTPS） ---
# start_gate_token トークン [追加の docker run 引数...]（「GitHub」の証明書を、ゲートが信頼する CA として差し込む）
start_gate_token() {
  token=$1; shift
  docker rm --force "$CONTAINER_PREFIX-gate" >/dev/null 2>&1 || true
  run "rm -f /w/config/github_key /w/config/github_key.pub && printf '%s\\n' '$token' > /w/config/github_token"
  docker run --detach --name "$CONTAINER_PREFIX-gate" --network "$NETWORK" --network-alias gate \
    --env UPSTREAM=https://github.com/git/repo.git --volume "$WORK_DIR/config:/config:ro" --volume "$CONTAINER_PREFIX-data:/srv/git" \
    --volume "$WORK_DIR/github/tls/cert.pem:/etc/ssl/certs/ca-certificates.crt:ro" "$@" "$IMAGE" >/dev/null
}
gate_stopped() { # gate_stopped ログに出るはずの文字列（止まるまで最大 30 秒待つ）
  for i in $(seq 30); do
    [ "$(docker inspect --format "{{.State.Running}}" "$CONTAINER_PREFIX-gate")" = false ] && break; sleep 1
  done
  [ "$(docker inspect --format "{{.State.Running}}" "$CONTAINER_PREFIX-gate")" = false ] && docker logs "$CONTAINER_PREFIX-gate" 2>&1 | grep -q "$1"
}
credential_fill() { # credential_fill ホスト → ゲートの git が、そのホストに渡す認証情報を出力する
  docker exec "$CONTAINER_PREFIX-gate" sh -c "printf 'protocol=https\\nhost=%s\\n' '$1' | su -s /bin/sh git -c 'git --git-dir=/srv/git/repo.git credential fill'" 2>&1
}
docker exec "$CONTAINER_PREFIX-github" git --git-dir=/home/git/repo.git branch frompat main
start_gate_token "$GITHUB_TOKEN"
wait_ssh gate "$CONTAINER_PREFIX-gate" > "$WORK_DIR/client/known_hosts_gate"
check "PAT: 起動時に GitHub を HTTPS で fetch している" 'gate_has frompat'
check "PAT: feature ブランチの push が GitHub に届く" \
  'client "git switch --quiet --create featpat && $(commit p) && git push --quiet origin featpat" && gh_has featpat && ! grep -q "$GITHUB_TOKEN" "$WORK_DIR/out"'
check "PAT: main への push は拒否" \
  '! client "$(commit q) && git push --quiet origin HEAD:main" && grep -q git-push-gate: "$WORK_DIR/out" && ! grep -q "$GITHUB_TOKEN" "$WORK_DIR/out"'
check "PAT: トークンは UPSTREAM のホストにだけ渡す" \
  'credential_fill github.com | grep -qx "password=$GITHUB_TOKEN" &&
   ! credential_fill github.com.evil.example | grep -q "$GITHUB_TOKEN" && ! credential_fill evil.example | grep -q "$GITHUB_TOKEN"'
check "PAT: トークンはログにも記録にも出ない" \
  '! docker logs "$CONTAINER_PREFIX-gate" 2>&1 | grep -q "$GITHUB_TOKEN" && ! docker exec "$CONTAINER_PREFIX-gate" grep -q "$GITHUB_TOKEN" /srv/git/repo.git/push-gate.log /srv/git/repo.git/config'
check "PAT: unlock は不要と案内する" \
  'docker exec "$CONTAINER_PREFIX-gate" unlock >"$WORK_DIR/out" 2>&1 && grep -q 不要 "$WORK_DIR/out"'
start_gate_token github_pat_wrong0123456789abcdefghijklmn
wait_ssh gate "$CONTAINER_PREFIX-gate" >/dev/null
check "PAT: トークンが違えば、起動時に警告し、push も GitHub に届かない" \
  'docker logs "$CONTAINER_PREFIX-gate" 2>&1 | grep -q "fetch できません" &&
   ! client "git switch --quiet --create featpat2 && $(commit r) && git push --quiet origin featpat2" && ! gh_has featpat2'
start_gate_token "$GITHUB_TOKEN x"
check "PAT: トークンに空白などがあれば起動しない" 'gate_stopped "トークンを 1 行だけ"'
start_gate_token "$GITHUB_TOKEN" --env UPSTREAM=git@github.com:repo.git
check "PAT: UPSTREAM が SSH の形なら起動しない" 'gate_stopped "https://github.com/owner/repo.git の形"'
start_gate_token "$GITHUB_TOKEN" --env UPSTREAM=https://x-access-token:secret@github.com/git/repo.git
check "PAT: UPSTREAM にユーザー名やトークンがあれば起動せず、ログにも出さない" \
  'gate_stopped "ユーザー名やトークンは入れない" && ! docker logs "$CONTAINER_PREFIX-gate" 2>&1 | grep -q secret'
start_gate_token "$GITHUB_TOKEN" --env "UPSTREAM=https://x-access-token:secret@evil.example/x
https://github.com/git/repo.git"
check "PAT: 複数行の UPSTREAM は起動せず、ログにも出さない" \
  'gate_stopped "UPSTREAM に改行があります" && ! docker logs "$CONTAINER_PREFIX-gate" 2>&1 | grep -q secret'
start_gate_token "$GITHUB_TOKEN"
run "cp /w/github_key_plain /w/config/github_key"
docker restart "$CONTAINER_PREFIX-gate" >/dev/null 2>&1 || true
check "github_key と github_token の両方があれば起動しない" 'gate_stopped "両方があります"'
run "rm -f /w/config/github_token"
start_gate_token "" --env UPSTREAM=https://github.com/git/repo.git
run "rm -f /w/config/github_token && cp /w/github_key_plain /w/config/github_key"
docker restart "$CONTAINER_PREFIX-gate" >/dev/null 2>&1 || true
check "SSH 鍵で UPSTREAM が HTTPS なら起動しない" 'gate_stopped "UPSTREAM が HTTPS です"'

# --- パスフレーズ付きの鍵 ---
start_gate github_key_pp --env UNLOCK_LIFETIME=1h
check "PAT から SSH 鍵に切り替えると、PAT の設定は残らない" \
  '! docker exec "$CONTAINER_PREFIX-gate" git --git-dir=/srv/git/repo.git config --get-regexp "^(credential|http)\\." >"$WORK_DIR/out" 2>&1 &&
   docker exec "$CONTAINER_PREFIX-gate" git --git-dir=/srv/git/repo.git config --get core.sshCommand >/dev/null'
# ゲートの起動後に「GitHub」だけにブランチを作る（unlock の後の fetch で入るはず）
docker exec "$CONTAINER_PREFIX-github" git --git-dir=/home/git/repo.git branch fromgh main
check "unlock の前はまだ fetch していない" '! gate_has fromgh'

check "unlock 前の push は「ロックされています」で拒否" \
  '! client "git switch --quiet --create feat3 && $(commit d) && git push --quiet origin feat3" && grep -q ロックされています "$WORK_DIR/out" && ! gh_has feat3'
# 人間の unlock（パスフレーズは SSH_ASKPASS で渡す）
docker exec "$CONTAINER_PREFIX-gate" sh -c 'printf "#!/bin/sh\necho secret\n" > /tmp/askpass && chmod 755 /tmp/askpass'
check "unlock" \
  'docker exec --env SSH_ASKPASS=/tmp/askpass --env SSH_ASKPASS_REQUIRE=force "$CONTAINER_PREFIX-gate" unlock >"$WORK_DIR/out" 2>&1'
check "unlock の後に GitHub を fetch している" 'gate_has fromgh'
check "unlock 後の push が GitHub に届く" \
  'client "git switch --quiet --create feat3 && $(commit d) && git push --quiet origin feat3" && gh_has feat3'
check "unlock 後も develop への push は拒否" \
  '! client "$(commit e) && git push --quiet origin HEAD:develop" && grep -q git-push-gate: "$WORK_DIR/out"'
check "push した更新が記録されている" 'docker exec "$CONTAINER_PREFIX-gate" grep -q " refs/heads/feat3 " /srv/git/repo.git/push-gate.log'
check "鍵がエージェントに読み込まれている" \
  'docker exec "$CONTAINER_PREFIX-gate" su -s /bin/sh git -c "SSH_AUTH_SOCK=/run/git-push-gate/agent.sock ssh-add -l" | grep -q gate-pp'

# コンテナを再起動すると、またロックされる（ssh-agent はコンテナの中にあるため）
docker restart "$CONTAINER_PREFIX-gate" >/dev/null
wait_ssh gate "$CONTAINER_PREFIX-gate" >/dev/null
check "再起動の後は、またロックされている" \
  '! client "git switch --quiet --create feat4 && $(commit f) && git push --quiet origin feat4" && grep -q ロックされています "$WORK_DIR/out" && ! gh_has feat4'
# UNLOCK_LIFETIME が過ぎると、自動でロックされる
start_gate github_key_pp --env UNLOCK_LIFETIME=20
docker exec "$CONTAINER_PREFIX-gate" sh -c 'printf "#!/bin/sh\necho secret\n" > /tmp/askpass && chmod 755 /tmp/askpass'
check "UNLOCK_LIFETIME を短くして unlock" \
  'docker exec --env SSH_ASKPASS=/tmp/askpass --env SSH_ASKPASS_REQUIRE=force "$CONTAINER_PREFIX-gate" unlock >"$WORK_DIR/out" 2>&1'
check "UNLOCK_LIFETIME の間は push できる" \
  'client "git switch --quiet --create feat5 && $(commit g) && git push --quiet origin feat5" && gh_has feat5'
sleep 22
check "UNLOCK_LIFETIME が過ぎると、またロックされる" \
  '! client "git switch --quiet --create feat6 && $(commit h) && git push --quiet origin feat6" && grep -q ロックされています "$WORK_DIR/out" && ! gh_has feat6'

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
