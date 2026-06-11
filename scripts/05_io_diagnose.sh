# 05 磁盘IO诊断:盘是否打满、谁在读写、swap。压测进行中执行才有意义。只读。

section "磁盘使用率与挂载"
df -h | grep -vE 'tmpfs|overlay'

if have iostat; then
  section "iostat -x 1 5 (关键: %util接近100=盘打满; await SSD>5ms 机械>20ms=过载; avgqu-sz>2=排队)"
  iostat -x 1 5
else
  section "iostat 缺失(yum install -y sysstat),降级用 /proc/diskstats 差值估算"
  awk '{print $3,$6,$10}' /proc/diskstats > /tmp/ds1_$$
  sleep 5
  awk '{print $3,$6,$10}' /proc/diskstats > /tmp/ds2_$$
  echo "设备  5秒内读扇区  5秒内写扇区 (1扇区=512B)"
  join /tmp/ds1_$$ /tmp/ds2_$$ | awk '$2!=$4 || $3!=$5 {printf "%-10s r=%-12d w=%-12d\n",$1,$4-$2,$5-$3}'
  rm -f /tmp/ds1_$$ /tmp/ds2_$$
fi

if have pidstat; then
  section "pidstat -d 1 5 进程级读写 (确认是postgres在写还是java在写)"
  pidstat -d 1 5 | tail -30
else
  section "pidstat 缺失,降级: 读写量Top10进程 (/proc/*/io 5秒差值)"
  for p in $(ps -eo pid --no-headers); do
    [ -r "/proc/$p/io" ] && awk -v p="$p" '/^read_bytes|^write_bytes/{s[$1]=$2} END{print p, s["read_bytes:"], s["write_bytes:"]}' "/proc/$p/io" 2>/dev/null
  done | sort > /tmp/io1_$$
  sleep 5
  for p in $(ps -eo pid --no-headers); do
    [ -r "/proc/$p/io" ] && awk -v p="$p" '/^read_bytes|^write_bytes/{s[$1]=$2} END{print p, s["read_bytes:"], s["write_bytes:"]}' "/proc/$p/io" 2>/dev/null
  done | sort > /tmp/io2_$$
  join /tmp/io1_$$ /tmp/io2_$$ | awk '{dr=$4-$2; dw=$5-$3; if(dr>0||dw>0) print dr+dw, dr, dw, $1}' | \
    sort -rn | head -10 | while read tot dr dw pid; do
      printf "pid=%-8s read=%-12s write=%-12s %s\n" "$pid" "$dr" "$dw" "$(ps -o comm= -p "$pid" 2>/dev/null)"
    done
  rm -f /tmp/io1_$$ /tmp/io2_$$
fi

section "swap活动 (si/so 持续非0=内存不足在换页,CPU高可能是假象)"
vmstat 1 3

section "PG 数据目录所在盘 (对照上面iostat确认是不是PG把盘打满)"
if detect_psql; then
  PGDATA=$(PSQL "SHOW data_directory;" postgres | sed -n 3p | tr -d ' ')
  echo "data_directory: $PGDATA"
  df -h "$PGDATA" 2>/dev/null | tail -1
fi

section "脏页回写压力"
grep -E 'Dirty|Writeback:' /proc/meminfo
