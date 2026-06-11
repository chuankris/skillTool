# 00 环境探测:确认工具可用性、psql 路径、PG 配置现状。只读,不改任何东西。

section "系统信息"
cat /etc/redhat-release 2>/dev/null
uname -r
echo "CPU核数: $(nproc)"
free -h | head -2

section "诊断工具可用性"
for t in top ps vmstat free ss netstat iostat pidstat sar perf; do
  if have "$t"; then echo "OK      $t"; else echo "MISSING $t"; fi
done
have iostat || echo ">> iostat/pidstat 缺失会影响IO诊断,建议: yum install -y sysstat"

section "psql 探测"
if detect_psql; then
  echo "PSQL_BIN=$PSQL_BIN"
  echo ">> 请把上面这行写回 config.env,避免每次重新搜索"
else
  echo "自动探测失败,候选(供人工确认):"
  ps -eo pid,args | grep -E '[p]ostgres|[p]ostmaster' | head -5
fi

if [ -n "${PSQL_BIN:-}" ] && [ -x "$PSQL_BIN" ]; then
  section "PG 连通性与版本"
  PSQL "SELECT version();"

  section "PG 关键配置"
  PSQL "SELECT name, setting, unit FROM pg_settings WHERE name IN
        ('shared_preload_libraries','log_min_duration_statement','logging_collector',
         'log_directory','data_directory','max_connections','shared_buffers',
         'work_mem','max_wal_size','effective_cache_size');"

  section "pg_stat_statements 状态"
  PSQL "SELECT CASE WHEN current_setting('shared_preload_libraries') LIKE '%pg_stat_statements%'
        THEN '库已加载' ELSE '库未加载(需改配置并重启PG)' END AS preload_status;"
  PSQL "SELECT CASE WHEN count(*)>0 THEN '扩展已创建,可直接用'
        ELSE '扩展未创建: 请在本库执行 CREATE EXTENSION pg_stat_statements;' END AS ext_status
        FROM pg_extension WHERE extname='pg_stat_statements';"

  section "数据库列表(按大小Top15)"
  PSQL "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size,
        numbackends AS conns FROM pg_stat_database
        WHERE datname NOT LIKE 'template%'
        ORDER BY pg_database_size(datname) DESC LIMIT 15;" postgres
fi

section "Redis 探测"
if detect_redis_cli; then
  echo "REDIS_CLI_BIN=$REDIS_CLI_BIN"
  RCLI ping || echo "!! redis 连接失败,检查 REDIS_HOST/PORT/PASS"
else
  echo "未找到 redis-cli"
fi

section "Java/Tomcat 探测"
if detect_java_pid; then
  echo "CPU最高的java进程 PID=$TOMCAT_PID"
  ps -o pid,pcpu,pmem,etime,args -p "$TOMCAT_PID" | cut -c1-200
  if detect_java_tools; then
    echo "JAVA_BIN_DIR=$JAVA_BIN_DIR (jstack 可用)"
  else
    echo "!! 未找到 jstack(可能只装了JRE),04 脚本将降级用 kill -3 方式 dump 线程"
  fi
else
  echo "未发现 java 进程"
fi
