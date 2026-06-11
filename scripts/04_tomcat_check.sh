# 04 Tomcat/Java 检查:高CPU线程 -> 对应Java栈、GC状况。只读(降级方案 kill -3 无害)。
# 压测进行中执行才有意义。

detect_java_pid || { echo "未发现 java 进程"; exit 1; }
echo "目标 java 进程: PID=$TOMCAT_PID"
ps -o pid,pcpu,pmem,etime -p "$TOMCAT_PID"

section "该进程内 CPU Top15 线程 (TID为十进制)"
top -H -b -n 1 -p "$TOMCAT_PID" | awk 'NR>7' | sort -k9 -rn | head -15

# 取CPU最高的10个线程TID,转十六进制(jstack里的nid是hex)
TIDS=$(top -H -b -n 1 -p "$TOMCAT_PID" | awk 'NR>7' | sort -k9 -rn | head -10 | awk '{print $1}')

if detect_java_tools; then
  DUMP=/tmp/cpu_diag_jstack_$$.txt
  "$JAVA_BIN_DIR/jstack" "$TOMCAT_PID" > "$DUMP" 2>&1 || \
    "$JAVA_BIN_DIR/jstack" -F "$TOMCAT_PID" > "$DUMP" 2>&1

  section "高CPU线程对应的Java栈 (看栈顶在哪个业务类;GC task thread=GC占CPU)"
  for tid in $TIDS; do
    hex=$(printf '%x' "$tid")
    echo "--- TID=$tid nid=0x$hex ---"
    grep -A 20 "nid=0x$hex" "$DUMP" | head -22
    echo
  done

  section "线程状态统计 (大量BLOCKED=锁竞争; 总数过大=线程池配置过大)"
  grep -oE 'java.lang.Thread.State: [A-Z_]+' "$DUMP" | sort | uniq -c | sort -rn
  echo "总线程数: $(grep -c 'nid=0x' "$DUMP")"
  rm -f "$DUMP"

  if [ -x "$JAVA_BIN_DIR/jstat" ]; then
    section "GC 状况 jstat -gcutil 1秒x5 (FGC增长快或GCT占比高=内存不足/泄漏)"
    "$JAVA_BIN_DIR/jstat" -gcutil "$TOMCAT_PID" 1000 5 2>&1
  fi
else
  section "jstack 不可用,降级: kill -3 触发线程dump(输出在 catalina.out,无害)"
  kill -3 "$TOMCAT_PID"
  sleep 2
  CATOUT=$(ls -t /proc/$TOMCAT_PID/cwd/../logs/catalina.out 2>/dev/null || \
           find /opt /usr/local /var/log -name catalina.out 2>/dev/null | head -1)
  if [ -n "$CATOUT" ]; then
    echo "dump 已写入: $CATOUT (取最后800行)"
    tail -800 "$CATOUT"
    echo ">> 高CPU线程TID(十进制->十六进制对照,在dump里搜 nid=0x<hex>):"
    for tid in $TIDS; do printf 'TID=%s -> nid=0x%x\n' "$tid" "$tid"; done
  else
    echo "未找到 catalina.out,请手动确认 Tomcat 日志路径"
  fi
fi
