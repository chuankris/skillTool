---
name: analyze-cpu-skill
description: >
  CentOS 服务器 CPU 占用过高的系统性诊断 skill(针对 PostgreSQL 11 + Redis + Tomcat 技术栈,
  通过 SSH 远程执行)。当用户提到:压测/并发时 CPU 飙高、服务器卡顿、负载过高、找慢 SQL、
  postgres 进程占 CPU、怀疑磁盘 IO 瓶颈、Tomcat 线程占 CPU、需要性能排查报告时,务必使用本 skill。
  即使用户只说"帮我看看为什么这么卡"也应触发。
compatibility: 本机需有 ssh/scp(可选 sshpass)。目标服务器 CentOS 7,bash 脚本兼容 Python 2.7 环境,不依赖 python3。
---

# CentOS CPU 高占用诊断

## 背景

典型场景:外部接口 20 并发调用时服务器 CPU 飙到 80%+。技术栈:CentOS 7 + PostgreSQL 11
(海康平台自带,进程名 `hik.postgresql11`,路径可能非标准)+ Redis + Tomcat。
不要预设原因——可能是慢 SQL,也可能是磁盘 IO、GC、连接风暴。先分型,再深入。

## 准备工作(只做一次)

1. 连接信息分两类处理:
   - **凭据(PG 用户名/密码、SSH 密码):每次会话向用户询问,不写入任何文件。**
     run_remote.sh 在终端交互场景会自己提问;若由 AI 非交互执行,AI 先问用户拿到值,
     再以环境变量方式传入(如 `PGUSER=xxx PGPASSWORD=xxx bash run_remote.sh ...`),
     同样不落盘。
   - 非敏感项(服务器 IP、端口、业务库名)询问后写入 `scripts/config.env` 免得重复问。
   业务库名说明:该环境是海康平台,有几十个库(acps_acpsdb、eportal_portaldb 等),
   让用户指定接口主要打到哪个库;不确定就先填 postgres,慢 SQL 统计是全实例的、自动带库名。
   `PSQL_BIN` 不必问——海康环境 psql 通常不在 PATH 和环境变量里,留空即可,
   脚本会自动上服务器搜索(进程路径推断 + find),00 的输出会给出找到的路径,
   找到后把它写回 config.env 避免每次重搜。
2. 执行环境探测:`bash scripts/run_remote.sh 00_check_env.sh`
   - 确认 psql 路径、PG 连通性、pg_stat_statements 状态、慢查询日志配置、jstack/iostat 是否可用。
   - 若 psql 自动搜索也失败,把 00 输出里列出的候选路径给用户确认。
3. 若 `pg_stat_statements` 显示"库已加载但扩展未创建",在业务库执行:
   `CREATE EXTENSION pg_stat_statements;`(已加载 shared_preload_libraries 时不需要重启)。
   若库未加载,需改 postgresql.conf 的 `shared_preload_libraries` 并重启 PG——先征得用户同意。
4. 若慢查询日志未开(`log_min_duration_statement = -1`),可不重启开启:
   `ALTER SYSTEM SET log_min_duration_statement = 1000; SELECT pg_reload_conf();`

## 选择诊断模式

- CPU 是**瞬时飙高**(压测一打就高、停了就降)→ 走下面"三阶段"流程。
- CPU 是**缓慢爬升**(运行越久越高,本案例属于这种)→ 优先走"长期趋势监测",
  三阶段流程在爬升明显后再做一轮,两边互相印证。

## 长期趋势监测(缓慢爬升场景)

```bash
bash scripts/run_remote.sh 07_longterm_monitor.sh start 60   # 启动采样,每60秒一行
# ……让系统带业务正常跑数小时~数天,期间可随时 status 看一眼……
bash scripts/run_remote.sh 07_longterm_monitor.sh report     # 取趋势报告
bash scripts/run_remote.sh 07_longterm_monitor.sh clean      # 结束后清理(含服务器上的凭据缓存)
```

report 的"前1/4 vs 后1/4均值"表里,**和 CPU 一起持续上涨的那一列就是方向**:

| 上涨的指标 | 指向的积累型问题 | 下一步 |
|---|---|---|
| pg_total / pg_idle_tx | 连接泄漏 / 事务不提交(idle in transaction 还会拖垮 vacuum) | 02 snapshot 看是谁的连接,查应用连接池配置 |
| java_threads | 线程泄漏(线程池无界/定时任务堆积) | 04 看线程栈里大量重复的线程名 |
| mem_pct 涨 + 后期 wa/si-so 出现 | 内存泄漏 → 换页拖累 CPU | 04 的 jstat 看老年代占用是否只升不降 |
| time_wait | 短连接风暴累积 | 06 确认端口,应用改连接池/keepalive |
| us 涨但上面都平稳 | 数据量增长/表膨胀,同样的 SQL 越跑越慢 | 02 report 看 mean_time 高的 SQL;查 n_dead_tup 膨胀:`SELECT relname,n_dead_tup,n_live_tup FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;` 确认 autovacuum 是否被 idle_in_tx 卡住 |
| swap_mb | 物理内存不足,系统在硬撑 | 看 detail.log 里 pmem 高的进程 |

detail.log 每半小时存一次现场(进程 Top10 + 活跃 SQL),用于回看"爬升那一段时间谁在干活"。
pg_stat_statements 本身就是累积统计,长期跑后 02 report 的数据更有说服力。

## 诊断流程(三阶段,瞬时飙高/压测复现场景)

### 阶段一:压测前基线

```bash
bash scripts/run_remote.sh 01_sys_snapshot.sh        # 空载系统快照
bash scripts/run_remote.sh 02_pg_diagnose.sh reset   # 清零 pg_stat_statements 统计
```

### 阶段二:压测中实时抓取(让用户发起 20 并发,然后立刻执行)

```bash
bash scripts/run_remote.sh 02_pg_diagnose.sh watch 60   # 每2秒轮询活跃慢SQL,持续60秒
bash scripts/run_remote.sh 01_sys_snapshot.sh           # 高载系统快照(含线程级CPU)
bash scripts/run_remote.sh 05_io_diagnose.sh            # 磁盘IO采样(压测中跑才有意义)
bash scripts/run_remote.sh 04_tomcat_check.sh           # 抓高CPU的Java线程栈
```

watch 和其他脚本可开多个终端并行跑;至少保证 watch、01、05 都在压测期间执行过。

### 阶段三:压测后汇总

```bash
bash scripts/run_remote.sh 02_pg_diagnose.sh report   # pg_stat_statements Top SQL 等
bash scripts/run_remote.sh 03_redis_check.sh
bash scripts/run_remote.sh 06_net_conn.sh
bash scripts/run_remote.sh 08_misc_check.sh           # 矿马/软中断/降频/THP/cron/cgroup
```

所有结果落在本地 `results/<时间戳>/` 目录,逐个读取后按下面的方法解读。

## 组件自动发现与自主推理排查(重要,固定脚本之外的兜底)

固定脚本只覆盖 PG/Redis/Tomcat/系统层。真实服务器上往往还部署了别的东西
(该海康平台就是几十个 Java 微服务 + artemis 消息队列 + Elasticsearch 等),
排查不能被固定脚本框住。流程:

1. 执行 `bash scripts/run_remote.sh 09_discover_services.sh` 拿到部署清单:
   按进程聚合的资源排名、systemd 服务、监听端口、Java 进程明细、docker、部署目录。
2. 通读清单,主动推理:哪些组件占资源靠前或有嫌疑、它是干什么的、它会以什么方式
   消耗 CPU(如 ES 的 merge/GC、artemis 的消息堆积重投、nginx 的 TLS 握手)。
   把"嫌疑组件 + 怀疑理由"列给用户看。
3. 对每个嫌疑组件,**自己编写检测脚本**:在 `scripts/` 下新建 `adhoc_<组件名>.sh`,
   然后 `bash scripts/run_remote.sh adhoc_<组件名>.sh` 执行。约定:
   - 不写 shebang,直接写命令;`lib/common.sh` 的函数(section/have/PSQL/RCLI 等)
     和 config.env 变量自动可用;
   - 只读采集:查状态、读日志、看统计接口都可以;禁止重启服务、改配置、删文件,
     任何写操作必须先征得用户同意;
   - 输出用 `section "段名"` 分段,便于事后解读;
   - 跑完留在 scripts/ 目录,下次同类问题可复用。
   例:怀疑 ES → adhoc 里 curl localhost:9200/_nodes/hot_threads 和 _cat/thread_pool;
   怀疑 artemis → 查其 console/jolokia 接口的队列堆积数;怀疑某 java 微服务 →
   复用 04 的思路对它的 PID 做 jstack。
4. adhoc 结果同样纳入证据链和最终报告。

## 结果解读:先看 CPU 分型

读 01 快照里 top 的 `%Cpu(s)` 行,按最高的一项走分支:

**us(用户态)高 → 真在算,继续定位算什么**
- 01 的进程榜首是 postgres → 看 02 report 的 Top SQL:
  - 某条 SQL 占总耗时 > 30% → 主要元凶,看它的执行计划(`EXPLAIN (ANALYZE, BUFFERS)`)
  - watch 结果里反复出现的同一条 SQL → 同样是元凶
  - report 里 seq_scan 高的大表 + Top SQL 里 WHERE 该表 → 缺索引,给出建索引建议
  - 没有突出的单条 SQL,但 calls 极高 → N+1 查询/缓存未命中打穿到 DB,结合 03 的 Redis 命中率判断
- 榜首是 java/tomcat → 看 04 的线程栈:
  - 大量线程在同一业务方法 → 代码热点
  - GC 线程(`GC task thread`)占 CPU 或 jstat 显示 FGC 频繁 → 堆内存不足/内存泄漏
  - 大量线程 BLOCKED 在同一把锁 → 锁竞争

**wa(iowait)高 → 磁盘瓶颈**
- 05 的 iostat:`%util` 接近 100% 或 `await` 高(SSD>5ms、机械盘>20ms)→ 盘已打满
- pidstat -d 看谁在读写:postgres 写多 → 看 02 report 的 checkpoint 段:
  - `checkpoints_req` 占比高 → max_wal_size/shared_buffers 偏小,压测时疯狂刷盘
  - `temp_files`/`temp_bytes` 大 → work_mem 不够,排序/哈希落盘,这也会同时推高 us
- 读多且 02 的 cache 命中率 < 95% → shared_buffers 偏小或查询扫描量太大

**sy(内核态)高 → 系统调用/调度开销**
- 06 的上下文切换率 > 10万/秒 → 线程过多互相抢核;看 Tomcat 线程数、PG 连接数
- TIME_WAIT 数万级 → 短连接风暴,建议连接池/keepalive
- PG 连接数接近 max_connections → 没用连接池,每请求建连(PG fork 进程很贵)

**st(steal)高 → 虚拟机宿主超卖,与应用无关,找运维/云厂商**

**对不上号的情况 → 跑 08 杂项检查**
- 各进程 CPU 加起来远小于总 CPU → ld.so.preload 注入的隐身矿马
- si 高 / ksoftirqd 占 CPU → 网络风暴/网卡问题
- 占用率高但系统不算卡 → CPU 被降频,实际频率对照标称看
- 榜首是不认识的进程 → 08 的矿马排查 + 09 的组件清单对照

多个指标同时异常时,按"放大链"找根因:例如缺索引的慢 SQL(us)→ 大量扫描挤掉缓存(wa)
→ 连接堆积(sy)。根因通常是链条最上游那个。

## 产出报告

诊断完成后写一份 `results/诊断报告_<日期>.md`,固定结构:

```markdown
# CPU 高占用诊断报告
## 结论(一句话:根因是什么)
## 证据链(每条证据注明来自哪个脚本输出的哪一段)
## 修复建议(按优先级排序,给出具体 SQL/配置/命令)
## 复测方法(改完后如何验证)
```

建议要具体可执行:建索引给出完整 `CREATE INDEX CONCURRENTLY ...`,改参数给出
`ALTER SYSTEM SET ...` 和是否需要重启,代码问题给出类名/方法名(来自线程栈)。

## 首次运行检查清单(按顺序,任何一步失败先解决再往下)

1. 本机环境:Windows 上必须在 Git Bash 或 WSL 里执行(脚本是 bash);`ssh -V` 确认有 ssh。
2. `bash scripts/run_remote.sh 00_check_env.sh` —— 一条命令同时验证:SSH 连通、
   凭据询问流程、psql 探测、PG 连通。看到 "PSQL_BIN=..." 和 PG 版本输出即全链路 OK,
   把 PSQL_BIN 写回 config.env。
3. 若 psql 连接报 pg_hba 拒绝:把 config.env 的 PGHOST 改成 socket 目录(如 /tmp)再试。
4. `bash scripts/run_remote.sh 09_discover_services.sh` 摸清部署全貌,再开始正式诊断。

## 注意事项

- 目标机是生产或准生产环境:所有脚本均为只读采集,唯一例外是 `02 reset`(清统计)和
  用户明确同意的配置修改。不要擅自重启任何服务。
- PG 是 11 版本:pg_stat_statements 字段是 `total_time`/`mean_time`
  (PG13+ 改名 `total_exec_time`,脚本已按 11 写,勿改)。
- 海康自带 PG 的 psql 不在 PATH 里是常态,00 脚本会探测;若探测失败,
  用 `find / -name psql -type f 2>/dev/null` 让用户确认。
- jstack 可能不存在(只装了 JRE):04 脚本会自动降级为 `kill -3`(线程 dump 输出到
  catalina.out,无害)。
- 脚本输出全部是带 `=====[ 段名 ]=====` 分隔的纯文本,逐段读取解读即可。
- 凭据安全:本地不存任何密码;唯一例外是 07 长期监测需要在服务器
  `/tmp/cpu_longmon/env.sh`(权限600)缓存 PG 凭据供后台采样器使用,
  监测结束务必执行 `07_longterm_monitor.sh clean` 删除。要事先告知用户这一点。
