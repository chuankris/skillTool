# analyze-cpu-skill

一个面向 `CentOS 7 + PostgreSQL 11 + Redis + Tomcat` 场景的远程 CPU 高占用诊断 skill。

它的目标不是“猜原因”，而是通过一组只读诊断脚本，把 CPU 高、系统卡顿、慢 SQL、磁盘 IO、Tomcat 线程热点、连接风暴这类问题拆开定位，并最终产出一份带证据链的排查报告。

## 适用场景

- 压测或并发上来后，服务器 CPU 飙高
- 服务响应变慢，怀疑 PostgreSQL 慢 SQL 或连接堆积
- 怀疑 Redis 命中率低，导致请求穿透到数据库
- 怀疑 Tomcat 线程、GC、锁竞争导致 Java 进程吃满 CPU
- 怀疑磁盘 IO、网络连接、系统配置异常拖慢整体性能
- 需要整理一份可交付的性能诊断报告

## 技术范围

- 目标系统：`CentOS 7`
- 目标组件：`PostgreSQL 11`、`Redis`、`Tomcat / Java`
- 执行方式：本地通过 `SSH` 远程执行
- 本地环境：推荐 `Git Bash` 或 `WSL`

## 目录结构

```text
.
├─ SKILL.md
├─ README.md
└─ scripts
   ├─ run_remote.sh
   ├─ config.env
   ├─ 00_check_env.sh
   ├─ 01_sys_snapshot.sh
   ├─ 02_pg_diagnose.sh
   ├─ 03_redis_check.sh
   ├─ 04_tomcat_check.sh
   ├─ 05_io_diagnose.sh
   ├─ 06_net_conn.sh
   ├─ 07_longterm_monitor.sh
   ├─ 08_misc_check.sh
   ├─ 09_discover_services.sh
   └─ lib/common.sh
```

## 环境要求

本地需要：

- `bash`
- `ssh`
- `scp`
- 可选：`sshpass`

目标服务器建议具备：

- `psql`
- `redis-cli`
- `jstack` 或至少能使用 `kill -3`
- `iostat` / `pidstat` 所在的 `sysstat`

## 快速开始

### 1. 配置基础信息

编辑 `scripts/config.env`，填入非敏感配置，例如：

- `SSH_HOST`
- `SSH_PORT`
- `SSH_USER`
- `PGHOST`
- `PGPORT`
- `PGDATABASE`

建议不要把真实密码直接写入文件：

- `SSH_PASS`
- `PGPASSWORD`
- `REDIS_PASS`

这些值可以在运行时交互输入，或者用环境变量临时传入。

### 2. 先跑一次环境检查

```bash
bash scripts/run_remote.sh 00_check_env.sh
```

这一步会检查：

- SSH 连通性
- PostgreSQL 连接与版本
- `pg_stat_statements` 是否可用
- `psql`、`redis-cli`、`jstack`、`iostat` 等工具是否可用

### 3. 选择诊断模式

如果 CPU 是压测时瞬时飙高，优先走“短时高负载诊断”。

如果 CPU 是运行越久越高，优先走“长期趋势监控”。

## 诊断模式

### 短时高负载诊断

适合：

- 压测一打就高
- 并发一上来就卡
- 问题可以稳定复现

推荐流程：

```bash
# 压测前基线
bash scripts/run_remote.sh 01_sys_snapshot.sh
bash scripts/run_remote.sh 02_pg_diagnose.sh reset

# 压测进行中抓取
bash scripts/run_remote.sh 02_pg_diagnose.sh watch 60
bash scripts/run_remote.sh 01_sys_snapshot.sh
bash scripts/run_remote.sh 05_io_diagnose.sh
bash scripts/run_remote.sh 04_tomcat_check.sh

# 压测后汇总
bash scripts/run_remote.sh 02_pg_diagnose.sh report
bash scripts/run_remote.sh 03_redis_check.sh
bash scripts/run_remote.sh 06_net_conn.sh
bash scripts/run_remote.sh 08_misc_check.sh
```

### 长期趋势监控

适合：

- 运行时间越久 CPU 越高
- 怀疑连接泄漏、线程泄漏、内存泄漏
- 需要观察数小时到数天的趋势

推荐流程：

```bash
bash scripts/run_remote.sh 07_longterm_monitor.sh start 60
bash scripts/run_remote.sh 07_longterm_monitor.sh report
bash scripts/run_remote.sh 07_longterm_monitor.sh clean
```

说明：

- `start 60` 表示每 60 秒采样一次
- `report` 用于输出趋势报告
- `clean` 用于清理监控过程中写到远端临时目录的缓存文件

## 脚本说明

- `00_check_env.sh`：检查诊断环境、数据库连通性、工具可用性
- `01_sys_snapshot.sh`：抓取系统快照，适合做压测前后对比
- `02_pg_diagnose.sh`：聚焦 PostgreSQL，支持 `reset`、`watch`、`report`
- `03_redis_check.sh`：检查 Redis 基本状态与可能的热点问题
- `04_tomcat_check.sh`：抓取 Java/Tomcat 线程与栈信息
- `05_io_diagnose.sh`：采集磁盘 IO 指标，判断是否有 IO 瓶颈
- `06_net_conn.sh`：检查网络连接、连接堆积、`TIME_WAIT` 等问题
- `07_longterm_monitor.sh`：做长期趋势采样与汇总
- `08_misc_check.sh`：补充检查异常配置、软中断、透明大页等杂项
- `09_discover_services.sh`：自动发现额外部署组件，辅助扩展排查
- `run_remote.sh`：统一远程执行入口

## 结果输出

所有脚本结果默认会落到本地 `results/<日期>/` 目录下。

建议在诊断结束后整理一份报告，至少包括：

- 结论：CPU 高占用的最可能根因
- 证据链：每条结论来自哪个脚本、哪类输出
- 修复建议：SQL、配置或代码层面的可执行动作
- 复测方法：修改后如何验证问题是否解决

## 使用建议

- 先分型，再深挖，不要一开始就假设一定是数据库问题
- 有复现场景时，优先在高负载当下抓证据
- 先看 CPU 类型：`us`、`sy`、`wa`、`st` 各自含义不同
- 先用固定脚本建立证据链，再决定是否补充 adhoc 脚本

## 安全与注意事项

- 默认以只读采集为主，不应擅自重启服务或修改生产配置
- `scripts/config.env` 应保留为模板，不建议提交真实密码
- `02_pg_diagnose.sh reset` 会清理 `pg_stat_statements` 累积统计，执行前应确认影响
- `07_longterm_monitor.sh` 为后台采样可能会在远端写入临时凭据缓存，结束后务必执行 `clean`
- Windows 环境建议通过 `Git Bash` 或 `WSL` 执行，避免直接用 PowerShell 跑 `bash` 脚本时出现兼容问题

## 后续可补充

- 增加示例诊断报告
- 增加常见问题与故障案例
- 增加英文版 README

