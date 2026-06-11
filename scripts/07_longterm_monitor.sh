# 07 长期趋势监测:适用于"CPU缓慢爬升"场景(连接泄漏/线程泄漏/内存泄漏/表膨胀等积累型问题)。
# 在服务器上后台跑一个轻量采样器(每分钟一行CSV,开销可忽略),跑数小时~数天后取报告看趋势。
# 用法(经 run_remote.sh):
#   07_longterm_monitor.sh start [间隔秒,默认60]   -> 部署并启动采样器
#   07_longterm_monitor.sh status                  -> 是否在跑 + 最近几条样本
#   07_longterm_monitor.sh report                  -> 取回全部CSV + 趋势摘要
#   07_longterm_monitor.sh stop                    -> 停止采样(保留数据)
#   07_longterm_monitor.sh clean                   -> 停止并删除全部数据(含服务器上的凭据缓存)

MODE="${1:-status}"
MON=/tmp/cpu_longmon

case "$MODE" in
start)
  INT="${2:-60}"
  if [ -f "$MON/pid" ] && kill -0 "$(cat "$MON/pid")" 2>/dev/null; then
    echo "采样器已在运行(PID=$(cat "$MON/pid")),如需重启请先 stop"; exit 0
  fi
  mkdir -p "$MON" && chmod 700 "$MON"
  detect_psql >/dev/null 2>&1 || true
  detect_java_pid >/dev/null 2>&1 || true
  # 凭据只存在服务器 root-only 文件里,clean 时删除
  declare -p PGHOST PGUSER PGPASSWORD PGPORT PSQL_BIN TOMCAT_PID 2>/dev/null > "$MON/env.sh"
  chmod 600 "$MON/env.sh"

  cat > "$MON/sampler.sh" <<'SAMPLER_EOF'
#!/bin/bash
export LC_ALL=C LANG=C
. /tmp/cpu_longmon/env.sh 2>/dev/null
INT="${1:-60}"; OUT=/tmp/cpu_longmon; N=0
echo $$ > "$OUT/pid"   # 采样器自己记录真实PID(setsid后$!不可靠)
CSV="$OUT/trend.csv"
[ -f "$CSV" ] || echo "time,us,sy,wa,st,load1,mem_pct,swap_mb,pg_total,pg_active,pg_idle_tx,java_threads,time_wait,top_proc,top_cpu" > "$CSV"
PSQLQ() {
  [ -n "$PSQL_BIN" ] && [ -x "$PSQL_BIN" ] && \
  PGPASSWORD="$PGPASSWORD" "$PSQL_BIN" -h "${PGHOST:-127.0.0.1}" -p "${PGPORT:-5432}" -U "$PGUSER" -d postgres -tA -c "$1" 2>/dev/null
}
while :; do
  TS=$(date '+%F %T')
  read -r US SY WA ST <<EOF2
$(top -bn1 | grep -i 'cpu(s)' | head -1 | awk -F, '{for(i=1;i<=NF;i++){n=split($i,a," "); k[a[n]]=a[n-1]} print k["us"],k["sy"],k["wa"],k["st"]}')
EOF2
  LOAD1=$(awk '{print $1}' /proc/loadavg)
  MEMP=$(free | awk '/Mem:/{printf "%.1f",100*$3/$2}')
  SWAPM=$(free -m | awk '/Swap:/{print $3}')
  PGROW=$(PSQLQ "SELECT count(*)||','||count(*) FILTER (WHERE state='active')||','||count(*) FILTER (WHERE state='idle in transaction') FROM pg_stat_activity;")
  [ -n "$PGROW" ] || PGROW=",,"
  JPID="$TOMCAT_PID"
  [ -n "$JPID" ] && kill -0 "$JPID" 2>/dev/null || JPID=$(ps -eo pid,pcpu,args --sort=-pcpu | grep '[j]ava' | awk 'NR==1{print $1}')
  JTHR=$([ -n "$JPID" ] && ps -o nlwp= -p "$JPID" 2>/dev/null | tr -d ' ')
  TW=$(( $(ss -ant state time-wait 2>/dev/null | wc -l) - 1 )); [ "$TW" -lt 0 ] && TW=0
  TOPP=$(ps -eo comm,pcpu --sort=-pcpu | awk 'NR==2{print $1","$2}')
  echo "$TS,$US,$SY,$WA,$ST,$LOAD1,$MEMP,$SWAPM,$PGROW,$JTHR,$TW,$TOPP" >> "$CSV"
  # 每30个样本(默认半小时)记一次详细现场,便于回看爬升瞬间谁在干活
  if [ $((N % 30)) -eq 0 ]; then
    { echo "########## $TS ##########"
      ps -eo pid,pcpu,pmem,nlwp,comm --sort=-pcpu | head -11
      PSQLQ "SELECT pid||' | '||datname||' | '||state||' | '||left(regexp_replace(query,E'[\n\r]+',' ','g'),120) FROM pg_stat_activity WHERE state<>'idle' LIMIT 10;"
    } >> "$OUT/detail.log" 2>&1
  fi
  N=$((N+1))
  sleep "$INT"
done
SAMPLER_EOF
  chmod 700 "$MON/sampler.sh"
  rm -f "$MON/pid"
  nohup setsid bash "$MON/sampler.sh" "$INT" >> "$MON/sampler.log" 2>&1 &
  sleep 2   # 等采样器把自己的真实PID写进pid文件
  if [ -f "$MON/pid" ] && kill -0 "$(cat "$MON/pid")" 2>/dev/null; then
    echo "采样器已启动: PID=$(cat "$MON/pid"), 间隔${INT}秒, 数据在 $MON/trend.csv"
    echo "建议至少跑到 CPU 明显爬升后再取报告: 07_longterm_monitor.sh report"
  else
    echo "!! 启动失败,日志:"; tail -20 "$MON/sampler.log"
  fi
  ;;

status)
  if [ -f "$MON/pid" ] && kill -0 "$(cat "$MON/pid")" 2>/dev/null; then
    echo "运行中 PID=$(cat "$MON/pid")"
  else
    echo "未在运行"
  fi
  [ -f "$MON/trend.csv" ] && { echo "样本数: $(($(wc -l < "$MON/trend.csv")-1))"; echo "最近5条:"; tail -5 "$MON/trend.csv"; }
  ;;

report)
  [ -f "$MON/trend.csv" ] || { echo "无数据,先执行 start"; exit 1; }
  section "趋势摘要 (前1/4时段均值 vs 后1/4时段均值,涨幅大的列就是泄漏/积累方向)"
  awk -F, 'NR>1 {rows++; for(i=2;i<=13;i++) v[rows][i]=$i}
    END{
      if(rows<8){print "样本太少(<8),先多跑一会"; exit}
      q=int(rows/4); split("us sy wa st load1 mem_pct swap_mb pg_total pg_active pg_idle_tx java_threads time_wait",name," ")
      printf "%-14s %12s %12s %10s\n","指标","前1/4均值","后1/4均值","变化"
      for(i=2;i<=13;i++){
        a=0;b=0;ca=0;cb=0
        for(r=1;r<=q;r++)        if(v[r][i]!=""){a+=v[r][i];ca++}
        for(r=rows-q+1;r<=rows;r++) if(v[r][i]!=""){b+=v[r][i];cb++}
        if(ca>0&&cb>0){ma=a/ca;mb=b/cb;
          printf "%-14s %12.2f %12.2f %+9.1f%%\n",name[i-1],ma,mb,(ma>0?(mb-ma)*100/ma:0)}
      }
    }' "$MON/trend.csv"

  section "完整CSV数据 (交给AI画趋势/逐列分析)"
  cat "$MON/trend.csv"

  section "周期性详细现场 (最近200行)"
  [ -f "$MON/detail.log" ] && tail -200 "$MON/detail.log"
  ;;

stop)
  [ -f "$MON/pid" ] && kill "$(cat "$MON/pid")" 2>/dev/null
  pkill -f "$MON/sampler.sh" 2>/dev/null
  echo "已停止,数据保留在 $MON (report 仍可用; 彻底清理用 clean)"
  ;;

clean)
  [ -f "$MON/pid" ] && kill "$(cat "$MON/pid")" 2>/dev/null
  pkill -f "$MON/sampler.sh" 2>/dev/null
  rm -rf "$MON"
  echo "已停止并删除 $MON (含凭据缓存)"
  ;;

*) echo "未知模式: $MODE (可用: start [秒]|status|report|stop|clean)"; exit 1;;
esac
