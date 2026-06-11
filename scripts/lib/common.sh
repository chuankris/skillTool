# ===== 公共函数(由 run_remote.sh 自动拼接,勿单独执行) =====

# 强制英文输出: top/ps/free 被中文本地化后,所有 awk/grep 解析都会失效
export LC_ALL=C LANG=C

section() { echo; echo "=====[ $* ]====="; }

have() { command -v "$1" >/dev/null 2>&1; }

# 自动探测 psql:依次尝试 config 指定路径 -> 常见路径 -> 由 postgres 进程路径推断 -> find 全盘搜
detect_psql() {
  [ -n "${PSQL_BIN:-}" ] && [ -x "$PSQL_BIN" ] && return 0
  local c
  for c in /usr/bin/psql /usr/pgsql-11/bin/psql /usr/local/pgsql/bin/psql \
           /opt/pgsql*/bin/psql /opt/hikvision/*/pgsql*/bin/psql; do
    [ -x "$c" ] && PSQL_BIN="$c" && return 0
  done
  # 从正在运行的 postgres 主进程的可执行文件路径推断(海康环境最可靠的方法)
  local pgpid pgbin
  pgpid=$(ps -eo pid,comm,args | grep -E '[p]ostgres|[p]ostmaster' | awk 'NR==1{print $1}')
  if [ -n "$pgpid" ] && [ -r "/proc/$pgpid/exe" ]; then
    pgbin=$(dirname "$(readlink -f /proc/$pgpid/exe)")
    [ -x "$pgbin/psql" ] && PSQL_BIN="$pgbin/psql" && return 0
  fi
  # 兜底:全盘搜索(可能要几十秒)
  PSQL_BIN=$(find / -name psql -type f -perm -u+x 2>/dev/null | head -1)
  [ -n "$PSQL_BIN" ] && return 0
  echo "!! 未找到 psql,请手动确认路径后填入 config.env 的 PSQL_BIN" >&2
  return 1
}

# PSQL "SQL语句" [库名]   —— 以管理员账号执行 SQL
PSQL() {
  local sql="$1" db="${2:-$PGDATABASE}"
  PGPASSWORD="$PGPASSWORD" "$PSQL_BIN" -h "${PGHOST:-127.0.0.1}" -p "$PGPORT" -U "$PGUSER" \
    -d "$db" -X -P pager=off -v ON_ERROR_STOP=0 -c "$sql" 2>&1
}

detect_redis_cli() {
  [ -n "${REDIS_CLI_BIN:-}" ] && [ -x "$REDIS_CLI_BIN" ] && return 0
  local c rpid
  for c in /usr/bin/redis-cli /usr/local/bin/redis-cli /opt/redis*/bin/redis-cli \
           /opt/hikvision/*/redis*/bin/redis-cli; do
    [ -x "$c" ] && REDIS_CLI_BIN="$c" && return 0
  done
  rpid=$(ps -eo pid,comm | grep '[r]edis-server' | awk 'NR==1{print $1}')
  if [ -n "$rpid" ] && [ -r "/proc/$rpid/exe" ]; then
    c="$(dirname "$(readlink -f /proc/$rpid/exe)")/redis-cli"
    [ -x "$c" ] && REDIS_CLI_BIN="$c" && return 0
  fi
  REDIS_CLI_BIN=$(find / -name redis-cli -type f -perm -u+x 2>/dev/null | head -1)
  [ -n "$REDIS_CLI_BIN" ]
}

RCLI() {
  if [ -n "${REDIS_PASS:-}" ]; then
    "$REDIS_CLI_BIN" -h "$REDIS_HOST" -p "$REDIS_PORT" -a "$REDIS_PASS" "$@" 2>/dev/null
  else
    "$REDIS_CLI_BIN" -h "$REDIS_HOST" -p "$REDIS_PORT" "$@" 2>/dev/null
  fi
}

# 找 CPU 最高的 java 进程 PID
detect_java_pid() {
  [ -n "${TOMCAT_PID:-}" ] && return 0
  TOMCAT_PID=$(ps -eo pid,pcpu,args --sort=-pcpu | grep '[j]ava' | awk 'NR==1{print $1}')
  [ -n "$TOMCAT_PID" ]
}

# 找 jstack/jstat 所在目录(由 java 进程的可执行文件推断,JRE 环境可能没有)
detect_java_tools() {
  [ -n "${JAVA_BIN_DIR:-}" ] && [ -x "$JAVA_BIN_DIR/jstack" ] && return 0
  detect_java_pid || return 1
  local jbin
  jbin=$(dirname "$(readlink -f /proc/$TOMCAT_PID/exe)" 2>/dev/null)
  for c in "$jbin" "$jbin/../bin" "$(dirname "$jbin")/bin"; do
    [ -x "$c/jstack" ] && JAVA_BIN_DIR="$(cd "$c" && pwd)" && return 0
  done
  return 1
}
