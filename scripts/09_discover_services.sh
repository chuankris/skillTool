# 09 组件自动发现:盘点服务器上实际部署了什么,输出给 AI 推理"还有哪些嫌疑组件"。只读。
# AI 拿到本清单后,对照 SKILL.md 的"自主推理排查"章节决定是否编写 adhoc 脚本深入检测。

section "按进程聚合的资源占用 Top25 (同名进程合并,一眼看清谁是大户)"
ps -eo comm,pcpu,pmem,nlwp --no-headers | \
  awk '{c[$1]+=$2; m[$1]+=$3; t[$1]+=$4; n[$1]++}
       END{printf "%-30s %8s %8s %8s %6s\n","COMMAND","CPU%","MEM%","THREADS","PROCS";
           for(k in c) printf "%-30s %8.1f %8.1f %8d %6d\n",k,c[k],m[k],t[k],n[k]}' | \
  sort -k2 -rn | head -26

section "运行中的 systemd 服务"
systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null | head -50

section "监听端口及归属进程 (每个监听端口背后都是一个组件)"
ss -tlnp 2>/dev/null | head -60

section "Java 进程明细 (海康平台是微服务架构,每个java进程是一个组件)"
ps -eo pid,pcpu,pmem,args --sort=-pcpu | grep '[j]ava' | \
  awk '{printf "PID=%s CPU=%s%% MEM=%s%% ", $1,$2,$3;
        for(i=4;i<=NF;i++) if($i ~ /-Dapp|-Dname|\.jar$|catalina/) printf "%s ", $i; print ""}' | head -30

section "docker 容器"
have docker && docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null | head -30 || echo "未安装docker"

section "已安装的常见中间件包"
rpm -qa 2>/dev/null | grep -iE 'postgres|redis|nginx|elastic|artemis|activemq|kafka|rabbit|mongo|mysql|mariadb|zookeeper|tomcat|haproxy|keepalived' | head -30

section "部署目录盘点"
for d in /opt /usr/local /home /data /app; do
  [ -d "$d" ] && echo "--- $d ---" && ls -1 "$d" 2>/dev/null | head -20
done
echo "--- 海康组件目录 ---"
ls -1 /opt/hikvision* 2>/dev/null | head -40 || true
find /opt/hikvision* -maxdepth 1 -type d 2>/dev/null | head -40

section "开机自启服务 (systemd enabled + chkconfig)"
systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend 2>/dev/null | head -40
chkconfig --list 2>/dev/null | grep ':on' | head -10

section "内核与系统参数摘要"
uname -r
sysctl -n vm.swappiness vm.dirty_ratio vm.dirty_background_ratio 2>/dev/null | \
  paste <(echo swappiness; echo dirty_ratio; echo dirty_background_ratio) - 2>/dev/null || \
  { echo "swappiness=$(cat /proc/sys/vm/swappiness)"; echo "dirty_ratio=$(cat /proc/sys/vm/dirty_ratio)"; }
