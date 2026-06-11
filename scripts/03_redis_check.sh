# 03 Redis 检查:慢命令、命中率、连接、耗时命令分布。只读。

detect_redis_cli || { echo "未找到 redis-cli"; exit 1; }
RCLI ping >/dev/null || { echo "redis 连接失败,检查 REDIS_HOST/PORT/PASS"; exit 1; }

section "慢日志 Top20 (时间单位微秒,>10000us=10ms 就值得关注)"
RCLI slowlog get 20

section "命中率 (低于90%说明缓存没起作用,请求打穿到PG)"
RCLI info stats | grep -E 'keyspace_hits|keyspace_misses|instantaneous_ops_per_sec|total_commands_processed' | tr -d '\r'
RCLI info stats | tr -d '\r' | awk -F: '
  /keyspace_hits/{h=$2} /keyspace_misses/{m=$2}
  END{ if(h+m>0) printf "hit_ratio: %.2f%%\n", 100*h/(h+m); else print "hit_ratio: N/A(无读请求)" }'

section "客户端与阻塞"
RCLI info clients | tr -d '\r'

section "内存"
RCLI info memory | grep -E 'used_memory_human|used_memory_peak_human|maxmemory_human|mem_fragmentation_ratio' | tr -d '\r'

section "命令耗时分布 Top15 按总耗时 (per_call高的命令如 keys/hgetall 多半是大key)"
# 行格式: cmdstat_get:calls=N,usec=N,usec_per_call=N
RCLI info commandstats | tr -d '\r' | \
  awk -F'[:,=]' 'NF>=7 {print $5, $3, $7, $1}' | sort -rn | head -15 | \
  awk '{printf "total_usec=%-12s calls=%-10s per_call_usec=%-8s %s\n", $1, $2, $3, $4}'

section "键空间"
RCLI info keyspace | tr -d '\r'
echo ">> 如怀疑大key,可手动执行: redis-cli --bigkeys (扫描型操作,压测结束后再跑)"
