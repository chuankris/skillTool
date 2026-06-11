# 02 PG 诊断。用法(经 run_remote.sh):
#   02_pg_diagnose.sh            -> snapshot: 当前活跃SQL/锁/连接
#   02_pg_diagnose.sh watch 60   -> 压测中每2秒轮询慢SQL,持续60秒
#   02_pg_diagnose.sh report     -> 压测后汇总: Top SQL/全表扫描/缓存/检查点
#   02_pg_diagnose.sh reset      -> 压测前清零统计(唯一的写操作)
# 注意: PG11 字段为 total_time/mean_time (PG13+ 改名,本环境勿改)

MODE="${1:-snapshot}"
detect_psql || exit 1

ACTIVE_SQL="SELECT pid, datname, usename,
       to_char(now()-query_start,'HH24:MI:SS.MS') AS run_for,
       state, wait_event_type||':'||wait_event AS waiting,
       left(regexp_replace(query, E'[\\n\\r ]+', ' ', 'g'), 160) AS query
FROM pg_stat_activity
WHERE state <> 'idle' AND pid <> pg_backend_pid()
ORDER BY query_start;"

case "$MODE" in
snapshot)
  section "活跃会话(正在执行的SQL,按开始时间排序,run_for 长的就是慢SQL)"
  PSQL "$ACTIVE_SQL" postgres

  section "锁等待(blocked_by 指向持锁进程)"
  PSQL "SELECT w.pid AS waiting_pid, w.datname,
        pg_blocking_pids(w.pid) AS blocked_by,
        to_char(now()-w.query_start,'HH24:MI:SS') AS waited,
        left(w.query,120) AS waiting_query
        FROM pg_stat_activity w
        WHERE cardinality(pg_blocking_pids(w.pid)) > 0;" postgres

  section "连接数分布(接近 max_connections 就是连接风暴)"
  PSQL "SELECT (SELECT setting FROM pg_settings WHERE name='max_connections') AS max_conn,
        count(*) AS total,
        count(*) FILTER (WHERE state='active') AS active,
        count(*) FILTER (WHERE state='idle') AS idle,
        count(*) FILTER (WHERE state='idle in transaction') AS idle_in_tx
        FROM pg_stat_activity;" postgres
  PSQL "SELECT datname, count(*) FROM pg_stat_activity GROUP BY 1 ORDER BY 2 DESC LIMIT 10;" postgres
  ;;

watch)
  DUR="${2:-60}"
  section "实时轮询活跃SQL: 每2秒一次,持续 ${DUR}秒 (压测期间执行)"
  END=$(( $(date +%s) + DUR ))
  while [ "$(date +%s)" -lt "$END" ]; do
    echo "--- $(date '+%T') ---"
    PSQL "SELECT pid, datname,
          round(extract(epoch FROM now()-query_start)::numeric,1) AS sec,
          state, coalesce(wait_event,'') AS wait,
          left(regexp_replace(query, E'[\\n\\r ]+', ' ', 'g'), 140) AS query
          FROM pg_stat_activity
          WHERE state='active' AND pid<>pg_backend_pid()
            AND now()-query_start > interval '0.5 s'
          ORDER BY sec DESC LIMIT 10;" postgres
    sleep 2
  done
  echo ">> 解读: 反复出现的同一条SQL即压测期间的慢SQL元凶"
  ;;

report)
  section "Top20 SQL 按总耗时 (cpu_pct=占全实例SQL总耗时百分比,>30%即主要元凶)"
  PSQL "SELECT d.datname,
        round(s.total_time::numeric,1) AS total_ms, s.calls,
        round(s.mean_time::numeric,2) AS avg_ms,
        round((100*s.total_time/sum(s.total_time) OVER ())::numeric,1) AS cpu_pct,
        s.rows,
        left(regexp_replace(s.query, E'[\\n\\r ]+', ' ', 'g'), 140) AS query
        FROM pg_stat_statements s JOIN pg_database d ON d.oid = s.dbid
        ORDER BY s.total_time DESC LIMIT 20;"

  section "Top10 SQL 按调用次数 (calls 巨高=N+1查询或缓存击穿)"
  PSQL "SELECT d.datname, s.calls, round(s.mean_time::numeric,2) AS avg_ms,
        left(regexp_replace(s.query, E'[\\n\\r ]+', ' ', 'g'), 140) AS query
        FROM pg_stat_statements s JOIN pg_database d ON d.oid = s.dbid
        ORDER BY s.calls DESC LIMIT 10;"

  section "全表扫描 Top15 (当前库 $PGDATABASE; 大表seq_scan高+idx_scan低=缺索引)"
  PSQL "SELECT relname, seq_scan, seq_tup_read, idx_scan, n_live_tup,
        pg_size_pretty(pg_total_relation_size(relid)) AS size
        FROM pg_stat_user_tables
        WHERE seq_scan > 0
        ORDER BY seq_tup_read DESC LIMIT 15;"

  section "各库缓存命中率/临时文件 (hit<95%=shared_buffers不足或扫描量太大; temp大=work_mem不足)"
  PSQL "SELECT datname,
        round(100.0*blks_hit/nullif(blks_hit+blks_read,0),2) AS cache_hit_pct,
        temp_files, pg_size_pretty(temp_bytes) AS temp_size,
        xact_commit, xact_rollback
        FROM pg_stat_database
        WHERE blks_hit+blks_read > 0 AND datname NOT LIKE 'template%'
        ORDER BY blks_hit+blks_read DESC LIMIT 15;" postgres

  section "检查点压力 (checkpoints_req占比高=压测时被迫频繁刷盘,调大max_wal_size)"
  PSQL "SELECT checkpoints_timed, checkpoints_req,
        buffers_checkpoint, buffers_backend, buffers_clean,
        round(100.0*checkpoints_req/nullif(checkpoints_timed+checkpoints_req,0),1) AS req_pct
        FROM pg_stat_bgwriter;" postgres
  ;;

reset)
  section "清零统计(压测前执行,使统计只反映压测期间)"
  PSQL "SELECT pg_stat_statements_reset();" 2>&1
  PSQL "SELECT pg_stat_reset();"
  echo ">> 已清零,现在可以发起压测"
  ;;

*) echo "未知模式: $MODE (可用: snapshot|watch [秒]|report|reset)"; exit 1;;
esac
