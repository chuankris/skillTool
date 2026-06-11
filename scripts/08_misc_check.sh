# 08 杂项检查:矿马/软中断/CPU降频/THP/定时任务/cgroup限制/其他中间件。全部只读。

section "可疑进程排查 (矿马特征: 从/tmp或/dev/shm启动、二进制已删除、名字伪装)"
echo "--- 已知矿马进程名 ---"
ps -eo pid,pcpu,user,args | grep -iE 'kdevtmpfsi|kinsing|xmrig|minerd|kthreaddi|sysupdate|networkservice' | grep -v grep || echo "(未发现)"
echo "--- 从 /tmp /dev/shm /var/tmp 启动的进程 ---"
for p in $(ps -eo pid --no-headers); do
  exe=$(readlink /proc/$p/exe 2>/dev/null)
  case "$exe" in /tmp/*|/dev/shm/*|/var/tmp/*) echo "PID=$p exe=$exe args=$(ps -o args= -p $p | cut -c1-100)";; esac
done
echo "--- 二进制已被删除仍在运行的进程 (矿马常用手法) ---"
for p in $(ps -eo pid --no-headers); do
  readlink /proc/$p/exe 2>/dev/null | grep -q '(deleted)' && \
    echo "PID=$p comm=$(cat /proc/$p/comm 2>/dev/null) args=$(ps -o args= -p $p | cut -c1-100)"
done
echo "(以上三段无输出即正常)"

section "ld.so.preload 注入检查 (被注入可让矿马在 top/ps 里隐身)"
if [ -s /etc/ld.so.preload ]; then
  echo "!! /etc/ld.so.preload 非空,高度可疑:"; cat /etc/ld.so.preload
  echo "!! 隐身时 top 看不到真凶但 CPU 高: 对比 top 总CPU 与 各进程CPU之和 是否差距巨大"
else
  echo "正常(文件不存在或为空)"
fi
echo "LD_PRELOAD 环境注入的进程:"
grep -l 'LD_PRELOAD' /proc/*/environ 2>/dev/null | head -5 || true

section "定时任务清单 (矿马驻留点 + 定时备份/扫描撞车排查)"
echo "--- root crontab ---"; crontab -l 2>/dev/null || echo "(空)"
echo "--- /etc/crontab ---"; grep -v '^#' /etc/crontab 2>/dev/null | grep -v '^\s*$'
echo "--- /etc/cron.d/ ---"; for f in /etc/cron.d/*; do [ -f "$f" ] && echo "[$f]" && grep -vE '^#|^\s*$' "$f"; done 2>/dev/null
echo "--- 各用户crontab ---"
for u in /var/spool/cron/*; do [ -f "$u" ] && echo "[$u]" && cat "$u"; done 2>/dev/null || echo "(无)"

section "对外可疑连接 (矿池常见端口/陌生公网IP)"
ss -antp state established 2>/dev/null | awk 'NR>1{print $4}' | \
  grep -vE '^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|\[::1\])' | \
  sort | uniq -c | sort -rn | head -15
echo "(出现陌生公网IP:端口 且对应进程占CPU高 => 矿马外连; 内网地址已过滤)"

section "软中断 si (网络风暴/网卡问题时 ksoftirqd 吃CPU)"
top -bn1 | grep -i 'cpu(s)' | head -1
ps -eo pid,pcpu,comm | grep ksoftirqd
echo "--- 软中断分布 Top ---"
head -1 /proc/softirqs; grep -E 'NET_RX|NET_TX|TIMER' /proc/softirqs

section "CPU 实际频率 (实际MHz远低于标称=被降频,占用率高是假象)"
lscpu 2>/dev/null | grep -iE 'model name|^cpu mhz|max mhz|min mhz'
echo "--- 当前各核频率(/proc/cpuinfo) ---"
grep MHz /proc/cpuinfo | sort | uniq -c
echo "--- 调度策略(powersave=节能降频,建议performance) ---"
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "(无cpufreq接口,可能是虚拟机)"

section "透明大页 THP (PG官方建议关闭; khugepaged累计CPU时间长=它在捣乱)"
cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null
ps -o pid,time,comm -C khugepaged 2>/dev/null

section "容器与cgroup限制"
if have docker; then
  docker ps --format '{{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null | head -20
  echo "--- 容器资源占用 ---"
  timeout 10 docker stats --no-stream 2>/dev/null | head -20
else
  echo "未安装docker"
fi

section "其他中间件进程 (artemis/ES/nginx等,按CPU排序)"
ps -eo pid,pcpu,pmem,comm,args --sort=-pcpu | \
  grep -iE 'artemis|elastic|nginx|kafka|rabbit|mongo|mysql|zookeeper|nodejs|node ' | \
  grep -v grep | head -10 | cut -c1-170 || echo "(未发现)"

section "安全/监控类软件 (杀毒扫描也会定时吃CPU)"
ps -eo pid,pcpu,comm,args --sort=-pcpu | \
  grep -iE 'safedog|titanagent|hostguard|aegis|clamd|freshclam|sav|qcloud|aliyun' | \
  grep -v grep | head -10 | cut -c1-150 || echo "(未发现)"
