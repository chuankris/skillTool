#!/usr/bin/env bash
# 用法: bash run_remote.sh <脚本名> [参数...]
# 例:   bash run_remote.sh 00_check_env.sh
#       bash run_remote.sh 02_pg_diagnose.sh watch 60
#       bash run_remote.sh 07_longterm_monitor.sh start 60
# 原理: 把 连接变量 + lib/common.sh + 目标脚本 拼成一个流,通过 SSH 在远端 bash 执行,
#       输出同时打到屏幕并保存到 results/<日期>/ 下。服务器上无需预放任何文件。
# 凭据策略: config.env 里留空的账号密码会在运行时询问(密码隐藏输入),不写入磁盘。
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$DIR/config.env"
COMMON="$DIR/lib/common.sh"

[ $# -ge 1 ] || { echo "用法: bash run_remote.sh <脚本名> [参数...]"; exit 1; }
SCRIPT="$DIR/$1"; shift
[ -f "$SCRIPT" ] || { echo "找不到脚本: $SCRIPT"; exit 1; }
[ -f "$CONF" ]   || { echo "找不到配置: $CONF"; exit 1; }

# 过滤CRLF后再source(Windows编辑器/git autocrlf 会把行尾改成\r\n,导致变量带\r、远端语法错)
CONF_CLEAN="${TMPDIR:-/tmp}/cpu_skill_conf_$$"
tr -d '\r' < "$CONF" > "$CONF_CLEAN"
# shellcheck source=/dev/null
. "$CONF_CLEAN"
rm -f "$CONF_CLEAN"
trap 'rm -f "$CONF_CLEAN"' EXIT

# ---- 运行时询问缺失的凭据(不落盘) ----
ask() { # ask 变量名 提示语 [secret]
  local var="$1" prompt="$2" secret="${3:-}" val=""
  [ -n "${!var:-}" ] && return 0
  if [ ! -r /dev/tty ]; then
    echo "!! 非交互环境无法询问 $var,请以环境变量传入后重试,例如:" >&2
    echo "   $var=xxx bash run_remote.sh ..." >&2
    exit 1
  fi
  if [ "$secret" = secret ]; then
    read -r -s -p "$prompt: " val </dev/tty; echo >&2
  else
    read -r -p "$prompt: " val </dev/tty
  fi
  printf -v "$var" '%s' "$val"
}
ask SSH_HOST "服务器IP"
ask SSH_USER "SSH用户名(默认root,直接回车)" ; SSH_USER="${SSH_USER:-root}"
NEED_PG_RE='00_|02_|05_|07_'
if [[ "$(basename "$SCRIPT")" =~ $NEED_PG_RE ]]; then
  ask PGUSER     "PG管理员用户名"
  ask PGPASSWORD "PG密码" secret
fi

OUTDIR="$DIR/../results/$(date +%Y%m%d)"
mkdir -p "$OUTDIR"
OUT="$OUTDIR/$(date +%H%M%S)_$(basename "$SCRIPT" .sh)${1:+_$1}.txt"

SSH_CMD="ssh -p ${SSH_PORT:-22} -o StrictHostKeyChecking=no -o ConnectTimeout=10"
if [ -n "${SSH_PASS:-}" ] && command -v sshpass >/dev/null 2>&1; then
  SSH_CMD="sshpass -p $SSH_PASS $SSH_CMD"
fi

# 远端需要的变量(在本机内存里拼好,经SSH管道注入,不经过任何文件)
PRELUDE=""
for v in PGHOST PGUSER PGPASSWORD PGPORT PGDATABASE PSQL_BIN \
         REDIS_HOST REDIS_PORT REDIS_PASS REDIS_CLI_BIN TOMCAT_PID JAVA_BIN_DIR; do
  PRELUDE+="$(printf '%s=%q' "$v" "${!v:-}")"$'\n'
done

echo ">>> 在 $SSH_USER@$SSH_HOST 上执行 $(basename "$SCRIPT") $* ,结果保存到 $OUT" >&2
# tr -d '\r': 防止脚本文件在Windows侧沾上CRLF导致远端bash语法错误
{ printf '%s' "$PRELUDE"; cat "$COMMON" "$SCRIPT" | tr -d '\r'; } | \
  $SSH_CMD "$SSH_USER@$SSH_HOST" "bash -s -- $*" | tee "$OUT"
RC=${PIPESTATUS[1]}
echo ">>> 完成(SSH 退出码 $RC),结果文件: $OUT" >&2
exit "$RC"
