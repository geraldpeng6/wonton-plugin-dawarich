# shellcheck shell=bash
# scripts/smoke.sh 的一项一项探测。页面特征、身份、数据都走真实的应用接口。

# 页面：SSO 登录后落到应用的时间线/地图页，标题带 Dawarich。
web_assert() { grep -qi '<title>[^<]*dawarich'; }

# 工具：上游自带的只读 MCP。get_latest_location 空库时也返回 {"point":null}，不依赖数据。
export MCP_TOOL=get_latest_location
export MCP_ARGS={}

mcp_assert() {
  grep -q '"point"' && ! grep -q '"isError":true'
}

identity_check() { # 设置页（Account）显示主人邮箱：<用户名>@wonton.internal
  local page
  page="$(_authorized_page /settings/users)" || { echo "页面失败"; return 1; }
  grep -qF "${SMOKE_OWNER}@wonton.internal" <<<"$page" ||
    { echo "设置页没显示主人邮箱 ${SMOKE_OWNER}@wonton.internal：$(head -c 200 <<<"$page")"; return 1; }
}

# 应用会话要经 OIDC 建立过才有：先普通请求，拿到的是登录页就带 --sso 从 webui.path 走一遍登录链。
_authorized_page() {
  local page
  page="$(dweb "$1")" || return 1
  if grep -qi 'sign in' <<<"$page"; then
    page="$(dweb --sso "$1")" || return 1
  fi
  printf '%s' "$page"
}

# 数据：按设置页复制按钮里的接口密钥调应用自己的 API（过网关带核心会话 cookie）。
# data_write 写一个带随机标记（device_id）的点，data_check 从 points 列表里找回这个标记。
_api_key() {
  local page key
  page="$(_authorized_page /settings/users)" || { echo "设置页请求失败"; return 1; }
  key="$(grep -o 'data-clipboard-text-value="[^"]*"' <<<"$page" | head -1 | sed 's/.*="//; s/"$//')"
  [[ "$key" =~ ^[0-9a-f]{32,128}$ ]] || { echo "设置页上取不到接口密钥：$(head -c 200 <<<"$page")"; return 1; }
  printf '%s' "$key"
}

data_write() {
  local key marker lat lon body code
  key="$(_api_key)" || { echo "$key"; return 1; }
  marker="wontonsmoke${RANDOM}${RANDOM}"
  lat="55.0${RANDOM}1"
  lon="12.6${RANDOM}2"
  body="$(printf '{"locations":[{"type":"Feature","geometry":{"type":"Point","coordinates":[%s,%s]},"properties":{"timestamp":1700000123,"device_id":"%s"}}]}' "$lon" "$lat" "$marker")"
  code="$(curl -sS --noproxy '*' -m 30 -b "$SMOKE_JAR" -H 'Content-Type: application/json' -d "$body" \
    -o /dev/null -w '%{http_code}' "$SMOKE_WEB_ORIGIN/api/v1/points?api_key=$key")" ||
    { echo "请求失败：$code"; return 1; }
  [[ "$code" == 2* ]] || { echo "写点失败：POST /api/v1/points 返回 $code"; return 1; }
  printf '%s' "$marker" >"$SMOKE_STATE"
}

data_check() {
  local key marker
  key="$(_api_key)" || { echo "$key"; return 1; }
  marker="$(cat "$SMOKE_STATE")"
  [[ -n "$marker" ]] || { echo "标记为空"; return 1; }
  curl -sS --noproxy '*' -m 30 -b "$SMOKE_JAR" \
    "$SMOKE_WEB_ORIGIN/api/v1/points?api_key=$key&per_page=10000" | grep -qF "$marker" ||
    { echo "points 列表里没有标记 $marker"; return 1; }
}
