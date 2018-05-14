#!/bin/bash
pids=""
data_dir=perlog
runtime=0
interval=5
quietly=0
is_stop=0
force_stop=0
analyze_data_dir=""
devices_param=""
nics_param=""

function usage()
{
  echo "Usage: $0: [OPTIONS]"
  echo "  -a data_dir     : analyze data"
  echo "  -i interval     : collect interval,default is 5 seconds"
  echo "  -t runtime      : Set the runtime for collect,0 means run wihtout stop,default is 0"
  echo "  -o output dir   : Set the output data dir,default is perlog at current working directory"
  echo "  -d device file  : filter device name by device file"
  echo "  -n nic file     : filter nic name by nic file"
  echo "  -s              : Stop current collect"
  echo "  -f              : Force stop all collect command"
  echo "  -q              : Run quietly"
  echo ""
  echo "Example:"
  echo "  $0 -i 5 -t 120"
  exit 1
}

function log()
{
  if [ ${quietly} -eq 1 ];then
    echo "[$(date +%H:%M:%S)] [INFO] $1" | tee -a ${data_dir}/output.log > /dev/null 2>&1
  else
    echo "[$(date +%H:%M:%S)] [INFO] $1" | tee -a ${data_dir}/output.log
  fi
}

sysinfo()
{
  mkdir -p ${data_dir}/sysinfo

  for proc in cpuinfo meminfo mounts modules version
  do
    cat /proc/$proc > ${data_dir}/sysinfo/$proc
  done

  for cmd in dmesg env lscpu lsmod lspci dmidecode free
  do
    $cmd > ${data_dir}/sysinfo/$cmd
  done
  
  all_devices=$(ls /sys/block/ | tr -s ' ' '\n' | grep -v loop | grep -v sr) 
  for device in ${all_devices}
  do
    if [ -z "${device}" ];then
      continue
    fi
    device_file=${data_dir}/sysinfo/${device}
    touch ${device_file}
    for param in max_segments max_segment_size max_sectors_kb nr_requests scheduler
    do
      printf "%20s\t" "${param}" >> ${device_file}
      cat /sys/block/${device}/queue/${param} >> ${device_file}
    done
  done
}

function analyze_collect()
{
  if [ ! -d "$1" ];then
    log "data directory not exist:$1"
    return 
  fi
  analysis_dir=$1/analysis
  log "analyzing $1->${analysis_dir}"
  rm -rf ${analysis_dir}
  mkdir ${analysis_dir}
  cat ${data_dir}/mpstat.log | grep all | awk '{print $1}' > ${analysis_dir}/time.txt
  cat ${data_dir}/mpstat.log | grep all | awk '{print 100-$NF}' > ${analysis_dir}/cpu.txt
  cat ${data_dir}/sarmem.log | tail -n +4 | awk '{print $5}'  > ${analysis_dir}/memory.txt
  
  disk_dir=${analysis_dir}/disk
  mkdir ${disk_dir}
  devices=""
  if [ -f "${devices_param}" ];then
    devices=$(cat ${devices_param})
  elif [ -n "${devices_param}" ];then
    devices="${devices_param}"
  else
    devices=$(ls /sys/block/ | tr -s ' ' '\n' | grep -v loop | grep -v sr)
  fi
  log "disks : $(echo ${devices} | tr -s '\n' ' ')"
  for device in ${devices}
  do
    cat ${data_dir}/iostat.log | grep "${device} " | awk '{print $4+$5,$6+$7}' > ${disk_dir}/${device}.txt
  done
  paste ${disk_dir}/* | awk '{iops=0;bw=0;for(i=1;i<=NF;i++){if(i%2) iops+=$i;else bw+=$i;};print iops,bw}' > ${analysis_dir}/disk.txt
  
  network_dir=${analysis_dir}/network
  mkdir ${network_dir}
  nics=""
  if [ -f "${nics_param}" ];then
    nics=$(cat ${nics_param})
  elif [ -n "${nics_param}" ];then
    nics="${nics_param}"
  else
    nics=$(sar -n DEV 1 1  | grep Average | grep -v IFACE | grep -v lo | awk '{print $2}' | sort | uniq)
  fi
  log "nics : $(echo ${nics} | tr -s '\n' ' ')"
  for nic in ${nics}
  do
    cat ${data_dir}/sarnet.log | grep "${nic} " | awk '{print $6,$7}' > ${network_dir}/${nic}.txt
  done
  paste ${network_dir}/* | awk '{rx=0;tx=0;for(i=1;i<=NF;i++){if(i%2) rx+=$i;else tx+=$i;};print rx,tx}' > ${analysis_dir}/network.txt
  printf "%12s%10s%10s%10s%10s%10s%10s\n" "Time" "CPU(%)" "memory(%)" "IOPS" "BW(MB/s)" "rx(KB/s)" "tx(KB/s)" > ${data_dir}/summary.txt
  
  files=""
  for file in network.txt disk.txt memory.txt cpu.txt time.txt
  do
    files="${analysis_dir}/${file} ${files}"
  done
  log "analysis files : ${files}"
  min_row_num=0
  for file in ${files}
  do
    row_num=$(cat ${file} | wc -l)
    if [ ${min_row_num} -eq 0 -o ${min_row_num} -gt ${row_num} ];then
      min_row_num=${row_num}
    fi
  done
  paste ${files} | head -n ${min_row_num} | awk 'BEGIN{cpu=0;memory=0;iops=0;bw=0;rx=0;tx=0;}{cpu+=$2;memory+=$3;iops+=$4;bw+=$5;rx+=$6;tx+=$7;printf("%12s%10.2f%10.2f%10.2f%10.2f%10.2f%10.2f\n",$1,$2,$3,$4,$5,$6,$7)}END{printf("%12s%10.2f%10.2f%10.2f%10.2f%10.2f%10.2f\n","Average",cpu/NR,memory/NR,iops/NR,bw/NR,rx/NR,tx/NR)}' >> ${data_dir}/summary.txt
  log "analyze complete."
}

function launch_collect
{
  pid_file=${data_dir}/pids.txt
  log "Collecting sysinfo"
  sysinfo
  log "Collecting perlog..."
  iostat -xmt ${interval} > ${data_dir}/iostat.log &
  echo "iostat  $!" > ${pid_file} 
  top -b -d ${interval} > ${data_dir}/top.log &
  echo "top     $!" >> ${pid_file} 
  sar -n DEV ${interval} >${data_dir}/sarnet.log &
  echo "sarnet  $!" >> ${pid_file} 
  sar -P ALL ${interval} >${data_dir}/sarcpu.log &
  echo "sarcpu  $!" >> ${pid_file} 
  sar -r ${interval} > ${data_dir}/sarmem.log &
  echo "sarmem  $!" >> ${pid_file} 
  mpstat -P ALL ${interval} > ${data_dir}/mpstat.log &
  echo "mpstat  $!" >> ${pid_file} 
  while read  name pid
  do
    log "${name} ${pid}"
  done < ${pid_file}
}

function stop_collect
{
  pid_file=${data_dir}/pids.txt
  if [ -f "${pid_file}" ];then
    log "Killing collect pids"
    cat ${pid_file} | awk '{print $NF}' | while read pid
    do
      kill -9 ${pid}
    done
    rm -f ${pid_file}
    #log "Aaalyze Collected Data"
    #analyze_collect "${data_dir}"
    #collect_result_file="${data_dir}/perlog.tar.gz"
    #log "Collect Result: ${collect_result_file}"
    #tar -czf "${collect_result_file}" ${data_dir}/
  else
    log "no collect is running"
  fi
}

function force_stop_collect
{
  ps -ef | grep -e "iostat -xmt" -e "top -b" -e "sar n DEV" -e "sar -P ALL" -e "sar -r" -e "mpstat -P ALL" | grep -v grep | awk '{print $2}' | while read pid
  do
    kill -9 ${pid}
  done
}

function my_exit()
{
  log "exit signal received..."
}

while getopts "a:t:i:o:d:n:hqsf" OPTION
do
  case ${OPTION} in
  a)
    export analyze_data_dir="${OPTARG}"
    ;;
  i)
    export interval="${OPTARG}"
    ;;
  t)
    export runtime="${OPTARG}"
    ;;
  o)
    export data_dir="${OPTARG}"
    ;;
  d)
    export devices_param="${OPTARG}"
    ;;
  n)
    export nics_param="${OPTARG}"
    ;;
  q)
    export quietly=1
    ;;
  s)
    export is_stop=1
    ;;
  f)
    export force_stop=1
    ;;
  h)
    usage
    ;;
  ?)
    usage
    ;;
  esac
done

if [ ${force_stop} -eq 1 ];then
  force_stop_collect
  exit 0
fi
if [ ${is_stop} -eq 1 ];then
  stop_collect
  exit 0
fi
if [ -d "${analyze_data_dir}" ];then
  analyze_collect "${analyze_data_dir}"
  exit 0
fi

pid_file=${data_dir}/pids.txt
if [ -f "${pid_file}" ];then
  log "collect is running,please stop first,use sh startdc.sh -s"
  exit -1
fi
rm -r -f ${data_dir}
mkdir ${data_dir}
launch_collect

if [ ${runtime} -gt 0 ];then
  trap "my_exit" 2 3 9 15
  log "waiting for ${runtime} seconds..."
  sleep ${runtime}
  stop_collect
else
  log "please stop collect manually"
fi

exit 0
