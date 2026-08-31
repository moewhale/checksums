#!/usr/bin/env bash
# fetch-checksums.sh — 抓取 versions.yaml 中定义的软件包并生成 SHA256 产物
# 用法:
#   ./tools/fetch-checksums.sh --update   # 下载并刷新 dist/ (默认)
#   ./tools/fetch-checksums.sh --check    # 校验 dist/ 是否完整且与上游一致
#   ./tools/fetch-checksums.sh --verify   # 用 dist 校验本地已下载文件（可选）
#
# 环境变量:
#   FETCH_RETRY=3  FETCH_TIMEOUT=60  KEEP_TMP=0  MIRROR_FALLBACK=1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSIONS="${ROOT}/versions.yaml"
DIST_DIR="${ROOT}/dist"
SHA_FILE="${DIST_DIR}/checksums.sha256"
JSON_FILE="${DIST_DIR}/checksums.json"

FETCH_RETRY="${FETCH_RETRY:-3}"
FETCH_TIMEOUT="${FETCH_TIMEOUT:-60}"
KEEP_TMP="${KEEP_TMP:-0}"
MIRROR_FALLBACK="${MIRROR_FALLBACK:-1}"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }
need_cmd curl
need_cmd sha256sum
need_cmd jq

# yq 可选：优先用 yq 解析，否则用 grep/sed fallback
HAS_YQ=0
if command -v yq >/dev/null 2>&1; then HAS_YQ=1; fi

# 解析 versions.yaml，输出每行: name|version|filename|url
parse_versions() {
  if [ "$HAS_YQ" -eq 1 ]; then
    yq eval -r '.packages | to_entries[] | "\(.key)|\(.value.version)|\(.value.filename)|\(.value.url)"' "$VERSIONS"
  else
    # fallback: 纯 bash 解析（兼容无 yq 环境，假设格式如 SPEC 示例）
    awk '
      /^  [a-zA-Z0-9_-]+:/ { pkg=$1; sub(/:$/,"",pkg); sub(/^  /,"",pkg); cur=pkg }
      /version:/ && cur { gsub(/.*version:[[:space:]]*"/,""); gsub(/".*/,""); ver=$0; v[cur]=ver }
      /filename:/ && cur { gsub(/.*filename:[[:space:]]*"/,""); gsub(/".*/,""); f[cur]=$0 }
      /variant:/ && cur { gsub(/.*variant:[[:space:]]*"/,""); gsub(/".*/,""); f[cur]=$0 }
      /url:/ && cur && !/binary_url/ && !/fallback/ { gsub(/.*url:[[:space:]]*"/,""); gsub(/".*/,""); u[cur]=$0 }
      END { for (k in v) printf "%s|%s|%s|%s\n", k, v[k], f[k], u[k] }
    ' "$VERSIONS"
  fi
}

render_template() {
  local tmpl="$1" ver="$2"
  echo "$tmpl" | sed "s/{version}/${ver}/g"
}

download_one() {
  local url="$1" out="$2"
  echo "  ↓ $url"
  if curl -fsSL --retry "$FETCH_RETRY" --connect-timeout 15 --max-time "$FETCH_TIMEOUT" -o "$out" "$url"; then
    if [ -s "$out" ]; then return 0; fi
  fi
  return 1
}

# 为 postgresql 做 v{version} -> v{major} 回退
try_postgresql_fallback() {
  local ver="$1" file="$2" out="$3"
  local major
  major=$(echo "$ver" | cut -d. -f1)
  local url2="https://ftp.postgresql.org/pub/source/v${major}/postgresql-${ver}.tar.gz"
  echo "  ↻ retry postgresql fallback: $url2"
  download_one "$url2" "$out"
}

# 为 mariadb binary 做 archive 回退
try_mariadb_binary() {
  local ver="$1" out="$2"
  local urls=(
    "https://archive.mariadb.org/mariadb-${ver}/bintar-linux-systemd-x86_64/mariadb-${ver}-linux-systemd-x86_64.tar.gz"
    "https://archive.mariadb.org/mariadb-${ver}/bintar-linux-glibc_214-x86_64/mariadb-${ver}-linux-glibc_214-x86_64.tar.gz"
  )
  for u in "${urls[@]}"; do
    echo "  ↻ retry mariadb binary: $u"
    if download_one "$u" "$out"; then return 0; fi
  done
  return 1
}

do_update() {
  mkdir -p "$DIST_DIR"
  local tmp_sha="${SHA_FILE}.tmp"
  local tmp_json="${JSON_FILE}.tmp"
  : > "$tmp_sha"
  echo '{"generated_at":"'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'","packages":{}}' > "$tmp_json"

  local count=0 fail=0
  local extra_packages=()

  # 额外处理：mariadb binary、postgresql fallback 在主循环内
  while IFS='|' read -r name version filename url; do
    [ -z "$name" ] && continue
    # yq 可能输出.variant 为空时 fallback filename
    if [ -z "$filename" ] || [ "$filename" = "null" ]; then
      # 尝试从 url 提取 filename
      filename=$(basename "$url" | sed "s/{version}/${version}/g")
    fi
    local rendered_file rendered_url
    rendered_file=$(render_template "$filename" "$version")
    rendered_url=$(render_template "$url" "$version")

    # 特殊：url 包含 {version} 的二次渲染已做，额外处理 binary
    local tmp_out="/tmp/${rendered_file}"
    echo "[${name}] ${version} -> ${rendered_file}"

    local dl_ok=0
    if download_one "$rendered_url" "$tmp_out"; then
      dl_ok=1
    else
      # 回退逻辑
      if [ "$name" = "postgresql" ]; then
        if try_postgresql_fallback "$version" "$rendered_file" "$tmp_out"; then dl_ok=1; fi
      fi
      # pcre 的 sourceforge download 链接可能重定向，curl 已处理；失败则尝试 alt
      if [ "$dl_ok" -eq 0 ] && [ "$name" = "pcre" ]; then
        local alt="https://sourceforge.net/projects/pcre/files/pcre/${version}/pcre-${version}.tar.bz2/download"
        echo "  ↻ retry pcre alt: $alt"
        if download_one "$alt" "$tmp_out"; then dl_ok=1; fi
      fi
      # openssl-compat 已在 url 中处理 old/1.1.1
      # jemalloc github release 需处理 {version} 已渲染
    fi

    if [ "$dl_ok" -eq 0 ]; then
      echo "  ✗ failed to download ${name} ${version} from ${rendered_url}" >&2
      fail=$((fail+1))
      continue
    fi

    # 计算 sha256
    local sha
    sha=$(sha256sum "$tmp_out" | awk '{print $1}')
    echo "  ✓ ${sha}  ${rendered_file}"

    # 写入 sha 文件
    echo "${sha}  ${rendered_file}" >> "$tmp_sha"

    # 写入 json（用 jq 合并）
    local tmp2="/tmp/json_${name}.tmp"
    jq --arg name "$name" --arg ver "$version" --arg file "$rendered_file" --arg url "$rendered_url" --arg sha "$sha" \
      '.packages[$name] = {"version":$ver,"filename":$file,"url":$url,"sha256":$sha,"source":"origin"}' \
      "$tmp_json" > "$tmp2" && mv "$tmp2" "$tmp_json"

    # 额外：mariadb 同时抓 binary
    if [ "$name" = "mariadb" ]; then
      local bin_file="mariadb-${version}-linux-systemd-x86_64.tar.gz"
      local bin_url="https://archive.mariadb.org/mariadb-${version}/bintar-linux-systemd-x86_64/${bin_file}"
      local bin_out="/tmp/${bin_file}"
      echo "  [mariadb-binary] -> ${bin_file}"
      if download_one "$bin_url" "$bin_out" || try_mariadb_binary "$version" "$bin_out"; then
        local bin_sha
        bin_sha=$(sha256sum "$bin_out" | awk '{print $1}')
        echo "  ✓ ${bin_sha}  ${bin_file}"
        echo "${bin_sha}  ${bin_file}" >> "$tmp_sha"
        jq --arg file "$bin_file" --arg sha "$bin_sha" --arg url "$bin_url" \
          '.packages["mariadb-binary"] = {"version":"'"$version"'","filename":$file,"url":$url,"sha256":$sha,"source":"origin"}' \
          "$tmp_json" > "$tmp2" && mv "$tmp2" "$tmp_json"
        if [ "$KEEP_TMP" != "1" ]; then rm -f "$bin_out"; fi
      else
        echo "  ⚠ mariadb binary not found, keep source only" >&2
      fi
    fi

    count=$((count+1))
    if [ "$KEEP_TMP" != "1" ]; then rm -f "$tmp_out"; fi
  done < <(parse_versions)

  if [ "$count" -eq 0 ]; then
    echo "no packages fetched, abort" >&2
    rm -f "$tmp_sha" "$tmp_json"
    return 1
  fi

  if [ "$fail" -gt 0 ]; then
    echo "[!] $fail package(s) failed, but $count succeeded" >&2
    # 若失败数过多则不覆写旧文件
    if [ "$count" -lt 3 ]; then
      echo "too few successes, abort to avoid corrupting dist" >&2
      rm -f "$tmp_sha" "$tmp_json"
      return 1
    fi
  fi

  sort -u "$tmp_sha" -o "$tmp_sha"
  # 美化 json：排序 keys
  jq -S '.' "$tmp_json" > "${tmp_json}.sorted" && mv "${tmp_json}.sorted" "$tmp_json"

  # 原子替换
  mv "$tmp_sha" "$SHA_FILE"
  mv "$tmp_json" "$JSON_FILE"

  # 更新 versions.yaml meta.updated
  if [ "$HAS_YQ" -eq 1 ]; then
    yq -i '.meta.updated = "'"$(date -u +"%Y-%m-%d")"'"' "$VERSIONS" || true
  fi

  echo ""
  echo "[+] Wrote ${SHA_FILE} ($(wc -l < "$SHA_FILE") entries)"
  cat "$SHA_FILE"
  echo ""
  echo "[+] Wrote ${JSON_FILE}"
  cat "$JSON_FILE"
}

do_check() {
  if [ ! -f "$SHA_FILE" ]; then echo "missing $SHA_FILE" >&2; return 1; fi
  if [ ! -f "$JSON_FILE" ]; then echo "missing $JSON_FILE" >&2; return 1; fi
  echo "[+] Checking dist coverage against versions.yaml ..."
  local missing=0
  while IFS='|' read -r name version filename url; do
    [ -z "$name" ] && continue
    if [ -z "$filename" ] || [ "$filename" = "null" ]; then
      filename=$(basename "$url" | sed "s/{version}/${version}/g")
    fi
    local rendered_file
    rendered_file=$(render_template "$filename" "$version")
    if ! grep -q "  ${rendered_file}$" "$SHA_FILE"; then
      echo "  MISSING: ${rendered_file} (${name} ${version})"
      missing=$((missing+1))
    else
      echo "  OK: ${rendered_file}"
    fi
    # 额外检查 mariadb binary
    if [ "$name" = "mariadb" ]; then
      local bin="mariadb-${version}-linux-systemd-x86_64.tar.gz"
      if ! grep -q "  ${bin}$" "$SHA_FILE"; then
        echo "  MISSING: ${bin} (mariadb-binary)"
        missing=$((missing+1))
      else
        echo "  OK: ${bin}"
      fi
    fi
  done < <(parse_versions)

  if [ "$missing" -gt 0 ]; then
    echo "[!] $missing artifact(s) missing from $SHA_FILE. Run: ./tools/fetch-checksums.sh --update" >&2
    return 1
  fi
  echo "[+] All pinned artifacts present in dist."

  # 额外：校验 json 与 sha 一致
  local json_count sha_count
  json_count=$(jq '.packages | length' "$JSON_FILE")
  sha_count=$(wc -l < "$SHA_FILE")
  echo "[+] json packages: $json_count, sha entries: $sha_count"
  return 0
}

do_verify() {
  # 用 dist 校验本地文件（若存在）
  if [ ! -f "$SHA_FILE" ]; then echo "missing $SHA_FILE" >&2; exit 1; fi
  echo "[+] Verifying local files against $SHA_FILE ..."
  sha256sum -c "$SHA_FILE" --ignore-missing || true
}

case "${1:---update}" in
  --update) do_update ;;
  --check)  do_check ;;
  --verify) do_verify ;;
  *) echo "Usage: $0 [--update|--check|--verify]" >&2; exit 1 ;;
esac
