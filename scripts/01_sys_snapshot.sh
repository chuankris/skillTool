# 01 系统快照:CPU 分型(us/sy/wa/st)、进程/线程级 CPU、内存、负载。只读。

section "时间与负载"
date '+%F %T'
uptime
echo "CPU核数: $(nproc)  (负载超过核数才算高)"

section "CPU 总体分型 (取第2次采样,关键看 us/sy/wa/st 哪个高)"
top -b -n 2 -d 1 | grep 'Cpu(s)' | tail -1
have mpstat && mpstat -P ALL 1 2 | tail -n +4

section "进程级 CPU Top20"
ps aux --sort=-%cpu | head -21 | cut -c1-180

section "线程级 CPU Top30 (postgres线程=对应一个连接在跑的SQL; java线程可与jstack对照)"
top -H -b -n 1 | head -7 | tail -1
top -H -b -n 1 | awk 'NR>7' | sort -k9 -rn | head -30 | cut -c1-160

section "vmstat 1 5 (r=运行队列 b=阻塞 cs=上下文切换 wa=IO等待 si/so=swap换页)"
vmstat 1 5

section "内存与swap"
free -h
grep -E 'Dirty|Writeback:' /proc/meminfo
