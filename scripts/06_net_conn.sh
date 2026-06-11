# 06 网络与连接:连接风暴、TIME_WAIT、上下文切换。只读。

SS=ss; have ss || SS="netstat"

section "连接总览"
$SS -s

section "关键端口连接状态分布 (PG:5432 Redis:6379 Tomcat:8080/8443/443)"
for port in "$PGPORT" "$REDIS_PORT" 8080 8443 443; do
  [ -z "$port" ] && continue
  echo "--- 端口 $port ---"
  if [ "$SS" = ss ]; then
    ss -ant "( sport = :$port or dport = :$port )" 2>/dev/null | awk 'NR>1{c[$1]++} END{for(s in c) printf "  %-12s %d\n", s, c[s]}'
  else
    netstat -ant 2>/dev/null | awk -v p=":$port" '$4 ~ p || $5 ~ p {c[$6]++} END{for(s in c) printf "  %-12s %d\n", s, c[s]}'
  fi
done
echo ">> ESTAB数=并发连接; TIME-WAIT上万=短连接风暴,建议连接池/keepalive"

section "TIME_WAIT 总数"
if [ "$SS" = ss ]; then ss -ant state time-wait 2>/dev/null | wc -l; else netstat -ant | grep -c TIME_WAIT; fi

section "上下文切换率 (vmstat cs列: >10万/秒=线程过多互相抢核)"
vmstat 1 5

if have pidstat; then
  section "进程级上下文切换 Top (cswch=主动等待 nvcswch=被抢占,nvcswch高=CPU争抢激烈)"
  pidstat -w 1 3 2>/dev/null | awk 'NR>3' | sort -k5 -rn | head -15
fi

section "已建立连接的对端 Top10 (确认是否疯狂连DB/Redis)"
if [ "$SS" = ss ]; then
  # state过滤后列为: Recv-Q Send-Q Local:Port Peer:Port -> $4=对端
  ss -ant state established 2>/dev/null | awk 'NR>1{print $4}' | sort | uniq -c | sort -rn | head -10
else
  netstat -ant 2>/dev/null | awk '$6=="ESTABLISHED"{print $5}' | sort | uniq -c | sort -rn | head -10
fi
