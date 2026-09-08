#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

bash -c "
  source '$ENGINE_DIR/lib/ui.sh'
  source '$ENGINE_DIR/lib/runtime.sh'
  source '$ENGINE_DIR/lib/config.sh'
  ENV_JSON='$TESTS_DIR/fixtures/env.min.json'
  SPEC_JSON='$ENGINE_DIR/templates/spec.demo.json'
  WORK_DIR='$WORK'; APP_NAME='tp-app'
  source '$ENGINE_DIR/lib/gen_microservices.sh'
  gen_microservices
" >/dev/null 2>&1

assert_eq "1" "$([[ -f "$WORK/services/api/server.js" ]] && echo 1 || echo 0)" \
  "l'API est générée sous services/api/"
assert_eq "1" "$([[ -f "$WORK/services/web/Dockerfile" ]] && echo 1 || echo 0)" \
  "le front est généré sous services/web/"
assert_eq "0" "$([[ -d "$WORK/microservices" ]] && echo 1 || echo 0)" \
  "plus de répertoire microservices/"

web_df=$(cat "$WORK/services/web/Dockerfile")
assert_contains "$web_df" "nginxinc/nginx-unprivileged" "le front utilise nginx-unprivileged"
assert_not_contains "$web_df" "FROM nginx:alpine" "plus de nginx:alpine privilégié"
assert_contains "$web_df" "EXPOSE 8080" "le front expose 8080, pas 80"

api_srv=$(cat "$WORK/services/api/server.js")
assert_contains "$api_srv" "process.env.PORT" "l'API lit son port depuis PORT"

api_df=$(cat "$WORK/services/api/Dockerfile")
assert_contains "$api_df" "USER node" "l'API tourne en utilisateur non-root"

nginx_conf=$(cat "$WORK/services/web/nginx.conf")
assert_contains "$nginx_conf" "listen       8080" "la conf nginx écoute sur 8080"

finish
