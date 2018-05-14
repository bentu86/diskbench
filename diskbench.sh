#!/bin/bash

## global settings##
ioengine=libaio
direct=1

##custom settings##
devices=""
bs=""
rw=""
rwmixread=50
iodepth=1
size=0
runtime=120
profile=""
data_dir=""
interval=1
long_output=0
zero_write=0
time_based=0
numjobs=1
offset=0
quietly=0

function usage()
{
    echo "Usage: $0: [OPTIONS]"
    echo "  -d devices      : Device list(sep with space) or file contains device,one device per line"
    echo "  -s size         : Test file size (default: 4G)"
    echo "  -i iodepth      : I/O depth (used by fio) (default: 1)" 
    echo "  -b bs           : Block size (used by fio) (default: 8K)"
    echo "  -m rw           : rw model (used by fio) (default : read)"
    echo "  -x rwmixread    : rwmixread (used by fio) (default : 50)"
    echo "  -t runtime      : Set the runtime for indiviual FIO test (default: 120 seconds)"
    echo "  -o offset       : Set offset for FIO"
    echo "  -c              : timebase,ignore size param"
    echo "  -j              : numjobs,default is 1"
    echo "  -p profile      : use profile contais fio params"
    echo "  -l              : long output format"
    echo "  -a data dir     : analyze data dir only"
    echo "  -n interval     : interval of iostat (default : 2 seconds)"
    echo "  -q              : quietly,hide log messages"
    echo "  -z              : init write disk"
    echo ""
    echo "Example:"
    echo "  $0 -d /dev/xvde -b 1M -m write -t 3600"
    exit 1
}

function log()
{
  if [ ${quietly} -eq 1 ];then
    echo "[$(date +%H:%M:%S)] [INFO] $1" | tee -a ${output_dir}/output.log > /dev/null
  else
    echo "[$(date +%H:%M:%S)] [INFO] $1" | tee -a ${output_dir}/output.log >&2
  fi
}

sysinfo()
{
  mkdir -p ${output_dir}/sysinfo

  for proc in cpuinfo meminfo mounts modules version
  do
    cat /proc/$proc > ${output_dir}/sysinfo/$proc
  done

  for cmd in dmesg env lscpu lsmod lspci dmidecode free
  do
    $cmd > ${output_dir}/sysinfo/$cmd
  done
  
  for device in ${devices}
  do
    device_name=$(echo ${device} | awk -F '/' '{print $NF}')
    device_file=${output_dir}/sysinfo/${device_name}
    touch ${device_file}
    for param in max_segments max_segment_size max_sectors_kb nr_requests scheduler
    do
      printf "%20s\t" "${param}" >> ${device_file}
      cat /sys/block/${device_name}/queue/${param} >> ${device_file}
    done
  done
}

function toMBps()
{
  if [ $# != 2 ];then
    return
  fi
  value=$1
  unit=$2
  if [ "${unit}" == "B/s" ];then
    value=$(echo ${value} | awk '{printf ("%.2f",$1/1024/1024)}')
  elif [ "${unit}" == "KB/s" ];then
    value=$(echo ${value} | awk '{printf ("%.2f",$1/1024)}')
  elif [ "${unit}" == "GB/s" ];then
    value=$(echo ${value} | awk '{printf ("%.2f",$1*1024)}')
  elif [ -n "${unit}" -a "${unit}" != "MB/s" ];then
    log "Error unknown bw unit:${unit}"
  fi
  echo ${value}
}

function toMsec()
{
  if [ $# != 2 ];then
    return 
  fi
  value=$1
  unit=$2
  if [ "${unit}" == "usec" ];then
    value=$(echo $value | awk '{printf ("%.2f",$1/1000)}')
  elif [ "${unit}" == "sec" ];then
    value=$(echo $value | awk '{printf ("%.2f",$1*1000)}')
  elif [ -n "${unit}" -a "${unit}" != "msec" ];then
    log "Error unknown lat unit:${unit}"
  fi
  echo ${value}
}

function print_header()
{
  if [ ${long_output} -eq 1 ];then
    printf "%20s\t%10s\t%10s\t%10s\t%12s\t%12s\t%12s\t%10s\t%10s\t%10s\t%12s\t%12s\t%12s\n" "Name" "Read IOPS" "Read BW" "Read Lat" "Min Read Lat" "Max Read Lat" "90th Read Lat" "Write IOPS" "Write BW" "Write Lat" "Min Write Lat" "Max Write Lat" "90th Write Lat"
  else
    printf "%20s\t%10s\t%10s\t%10s\t%10s\t%10s\t%10s\n" "Name" "IOPS" "BW" "Lat" "Min Lat" "Max Lat" "90th Lat"
  fi
}

function parse_fio()
{
 filename=$1
 filename=${filename##*/}
 #parse configuration lines
 config_line=$(cat $1 | grep rw | grep iodepth)
 starting=$(cat $1 | grep Starting)
 if [ -z "${starting}" -o -z "${config_line}" ];then
  return
 fi
 name=$(echo ${config_line} | awk -F ':' '{print $1}')
 rw=$(echo ${config_line} | awk -F 'rw=' '{print $2}' | awk -F ',' '{print $1}')
 bs=$(echo ${config_line} | awk -F 'bs=' '{print $2}' | awk -F ',' '{print $1}' | awk -F '-' '{print $1}')
 iodepth=$(echo ${config_line} | awk -F 'iodepth=' '{print $2}')

 #parse read result lines
 read_result=$(cat $1 | grep read | grep iops)
 read_bw=$(echo ${read_result} | awk -F 'bw=' '{print $2}' | awk -F ',' '{print $1}')
 read_bw_value=$(echo ${read_bw} | awk -F '[KMG]B' '{print $1}')
 read_bw_unit=$(echo ${read_bw} | grep -o '[KMG]B/s')
 read_bw_value=$(toMBps ${read_bw_value} ${read_bw_unit})
 read_iops=$(echo ${read_result} | awk -F 'iops=' '{print $2}' | awk -F ',' '{print $1}')
 
 read_lat=""
 min_read_lat=""
 max_read_lat=""
 read_lat_90=""
 if [ "${rw}" == "read" -o "${rw}" == "randread" -o "${rw}" == "rw" -o "${rw}" == "randrw" ];then
  read_lat_result=$(cat $1 | egrep ' lat ' | grep avg | head -n 1)
  read_lat_unit=$(echo ${read_lat_result} | awk -F '(' '{print $2}' | awk -F ')' '{print $1}' | tr -d ' ')
  read_lat=$(echo ${read_lat_result} | awk -F 'avg=' '{print $2}' | awk -F ',' '{print $1}')
  read_lat=$(toMsec ${read_lat} ${read_lat_unit})
  min_read_lat=$(echo ${read_lat_result} | awk -F 'min=' '{print $2}' | awk -F ',' '{print $1}')
  min_read_lat=$(toMsec ${min_read_lat} ${read_lat_unit})
  max_read_lat=$(echo ${read_lat_result} | awk -F 'max=' '{print $2}' | awk -F ',' '{print $1}')
  max_read_lat=$(toMsec ${max_read_lat} ${read_lat_unit})
  
  read_clat_unit=$(cat $1 | grep 'clat percentiles' | head -n 1 | awk -F '(' '{print $2}' | awk -F ')' '{print $1}' | tr -d ' ')
  read_lat_90=$(cat $1 | grep '90\.00th' | head -n 1 | awk -F '90\\.00th=' '{print $2}' | awk -F ',' '{print $1}' | tr -d '[\[\] ]')
  read_lat_90=$(toMsec ${read_lat_90} ${read_clat_unit})
 fi

 #parse write result lines
 write_result=$(cat $1 | grep write | grep iops)
 write_bw=$(echo ${write_result} | awk -F 'bw=' '{print $2}' | awk -F ',' '{print $1}')
 write_bw_value=$(echo ${write_bw} | awk -F '[KMG]B/s' '{print $1}')
 write_bw_unit=$(echo ${write_bw} | grep -o '[KMG]B/s')
 write_bw_value=$(toMBps ${write_bw_value} ${write_bw_unit})
 write_iops=$(echo ${write_result} | awk -F 'iops=' '{print $2}' | awk -F ',' '{print $1}')
 
 write_lat=""
 min_write_lat=""
 max_write_lat=""
 write_lat_90=""
 if [ "${rw}" == "write" -o "${rw}" == "randwrite" -o "${rw}" == "rw" -o "${rw}" == "randrw" ];then
   write_lat_result=$(cat $1 | grep ' lat ' | grep avg | tail -n 1)
   write_lat_unit=$(echo ${write_lat_result} | awk -F '(' '{print $2}' | awk -F ')' '{print $1}' | tr -d ' ')
   write_lat=$(echo ${write_lat_result} | awk -F 'avg=' '{print $2}' | awk -F ',' '{print $1}')
   write_lat=$(toMsec ${write_lat} ${write_lat_unit})
   min_write_lat=$(echo ${write_lat_result} | awk -F 'min=' '{print $2}' | awk -F ',' '{print $1}')
   min_write_lat=$(toMsec ${min_write_lat} ${write_lat_unit})
   max_write_lat=$(echo ${write_lat_result} | awk -F 'max=' '{print $2}' | awk -F ',' '{print $1}')
   max_write_lat=$(toMsec ${max_write_lat} ${write_lat_unit})

  write_clat_unit=$(cat $1 | grep 'clat percentiles' | tail -n 1 | awk -F '(' '{print $2}' | awk -F ')' '{print $1}' | tr -d ' ')
  write_lat_90=$(cat $1 | grep '90\.00th' | tail -n 1 | awk -F '90\\.00th=' '{print $2}' | awk -F ',' '{print $1}' | tr -d '[\[\] ]')
  write_lat_90=$(toMsec ${write_lat_90} ${write_clat_unit})
 fi

 total_iops=$(echo "${read_iops} ${write_iops}" | awk '{print $1+$2}')
 total_bw=$(echo "${read_bw_value} ${write_bw_value}" | awk '{print $1+$2}')
 total_avg_lat=$(echo "${read_lat} ${write_lat}" | awk '{if($1==NULL) print $2;else if($2==NULL) print $1;else printf ("%.2f",($1+$2)/2);}')
 total_min_lat=$(echo "${min_read_lat} ${min_write_lat}" | awk '{if($1==NULL) print $2;else if($2==NULL) print $1;else print ($1>$2?$2:$1);}')
 total_max_lat=$(echo "${max_read_lat} ${max_write_lat}" | awk '{if($1==NULL) print $2;else if($2==NULL) print $1;else print ($1>$2?$1:$2);}')
 total_lat_90=$(echo "${read_lat_90} ${write_lat_90}" | awk '{if($1==NULL) print $2;else if($2==NULL) print $1;else printf ("%.2f",($1+$2)/2);}')

 if [ ${long_output} -eq 1 ];then
   printf "%20s\t%10s\t%10s\t%10s\t%12s\t%12s\t%12s\t%10s\t%10s\t%10s\t%12s\t%12s\t%12s\n" "${name}" "${read_iops}" "${read_bw_value}" "${read_lat}" "${min_read_lat}" "${max_read_lat}" "${read_lat_90}" "${write_iops}" "${write_bw_value}" "${write_lat}" "${min_write_lat}" "${max_write_lat}" "${write_lat_90}"
 else
   #print result
   printf "%20s\t%10s\t%10s\t%10s\t%10s\t%10s\t%10s\n" "${name}" "${total_iops}" "${total_bw}" "${total_avg_lat}" "${total_min_lat}" "${total_max_lat}" "${total_lat_90}"
 fi
}

function parse_dir()
{
  if [ -f "$1" ];then
    parse_fio $1
    return
  fi
  if [ ! -d "$1" ];then
    return
  fi
  for file in $(ls $1)
  do
    if [ -d $1"/"$file ]
    then
      parse_dir $1"/"$file
    else
      parse_fio $1"/"$file
    fi
  done
}

function launch_fio()
{
  model_name="${bs}_${iodepth}_${numjobs}_${rw}"
  if [ "${rw}" == "rw" -o "${rw}" == "randrw" ];then
    model_name="${model_name}_${rwmixread}"
  fi
  model_dir=${output_dir}/${model_name}
  mkdir -p ${model_dir}

  #iostat_file=${model_dir}/iostat.log
  #log "Start collect iostat-->${iostat_file}"
  #iostat -xmt ${devices} ${interval} > ${iostat_file} &
  sh perfmon.sh -o ${model_dir}
  #pid_iostat=$!
  fio_global_params="-ioengine=${ioengine} -direct=${direct} -group_reporting -numjobs=${numjobs} -bs=${bs} -iodepth=${iodepth} -runtime=${runtime}"
  if [ "${size}" != "0" -a "${size}" != "0G" -a "${size}" != "0g" ];then
    fio_global_params="${fio_global_params} -size=${size}"
  fi
  if [ "${offset}" != "0" -a "${offset}" != "0G" -a "${offset}" != "0g" ];then
    fio_global_params="${fio_global_params} -offset=${offset}"
  fi
  if [ ${time_based} -eq 1 ];then
    fio_global_params="${fio_global_params} -time_based"
  fi

  for device in ${devices}
  do
    device_name=$(echo ${device} | awk -F '/' '{print $NF}')
    name="${device_name}_${model_name}"
    output_file="${model_dir}/${name}.log" 
    log "FIO TESTS ${device}->${output_file}"

    fio_params="${fio_global_params} -filename=${device} -name=${name} -output=${output_file}"
    if [ "${rw}" == "rw" -o "${rw}" == "randrw" ];then
      fio_params="${fio_params} -rw=${rw} -rwmixread=${rwmixread}"
    else
      fio_params="${fio_params} -rw=${rw}"
    fi
    log "FIO Params: ${fio_params}"
    fio ${fio_params} &
  done
  log "WAITING FOR FIO Test Complete..."
  while [ -n "$(pidof fio)" ] 
  do
    sleep 5
  done
  #kill -9 ${pid_iostat} > /dev/null 2>&1
  sh perfmon.sh -o ${model_dir} -s
  log "FIO Test ${model_name} Complete"
}

function init_write()
{
  init_write_dir="init_write"
  mkdir -p ${init_write_dir}
  fio_global_params="-ioengine=libaio -direct=1 -group_reporting -numjobs=1 -thread -iodepth=32 -bs=${bs} -rw=write"
  
  log "Init Write"
  for device in ${devices}
  do
    device_name=$(echo ${device} | awk -F '/' '{print $NF}')
    device_size=$(cat /sys/block/${device_name}/size | awk '{print $1*512}')
    init_write_file=${init_write_dir}/${device_name}.log
    fio_params="${fio_global_params} -size ${device_size} -filename=${device} -name ${device_name}_init_write -output ${init_write_file}"
    log "FIO Params: ${fio_params}"
    fio ${fio_params} &
  done
  log "WAITING FOR FIO Init Write Complete..."
  while [ -n "$(pidof fio)" ] 
  do
    sleep 5
  done
  log "Init Write Complete"
}
function check_apps()
{
  for app in fio dmidecode
  do
    if [ ! "`which $app`" ]; then
        echo "ERROR: '$app' application is required."
        EXIT=1
    fi
  done  
}
function my_exit()
{
  log "received ctrl+c....exiting"
  #ps -ef | grep iostat | grep -v grep | awk '{print $2}' | while read pid
  #do
  #  kill -9 ${pid}
  #done
}


while getopts "a:d:s:i:b:m:o:n:x:t:p:j:zhlcq" OPTION
do
    case ${OPTION} in
    a)  export data_dir="${OPTARG}"
        ;;
    d)
        if [ -f "${OPTARG}" ];then
          export devices=$(cat ${OPTARG} | tr -s '[\r\n]' ' ')
        else
          export devices=$(echo "${OPTARG}" | sed 's/,/ /g')
        fi
        ;;
    s)
        export size="${OPTARG}"
        ;;
    i)
        export iodepth="${OPTARG}"
        ;;
    b)
        export bs="${OPTARG}"
        ;;
    m)
        export rw="${OPTARG}"
        ;;
    o)
        export offset="${OPTARG}"
        ;;
    x)
        export rwmixread="${OPTARG}"
        ;;
    t)
        export runtime="${OPTARG}"
        ;;
    c)
        export time_based=1
        ;;
    j)
        export numjobs="${OPTARG}"
        ;;
    p)
        export profile="${OPTARG}"
        ;;
    l)
        export long_output=1
        ;;
    q)
        export quietly=1
        ;;
    n)
        export interval="${OPTARG}"
        ;;
    z)
        export zero_write=1
        ;;
    h)
        usage
        ;;
    ?)
        usage
        ;;
    esac
done
if [ ${zero_write} == 1 ];then
  if [ -z "${bs}" ];then
    bs=1M
  fi
  if [ -z "${rw}" ];then
    rw="write"
  fi
else
  if [ -z "${bs}" ];then
    bs=8k
  fi
  if [ -z "${rw}" ];then
    rw="read"
  fi
fi

# mandatory parameters

#analyze data only
if [ -d "${data_dir}" -o -f "${data_dir}" ];then
  print_header
  parse_dir ${data_dir}
  exit 0
fi

# first, check that all applications are installed on the system
check_apps

#check devices
if [ -z "${devices}" ];then
  log "require devices"
  usage
fi

#init write only
if [ ${zero_write} -eq 1 ];then
  init_write
  exit 0
fi

#init
export output_dir="$(dirname $0)/fio_result"
if [ -d "${output_dir}" ];then
  rm -R "${output_dir}"
fi
mkdir -p ${output_dir}

# collect system information
sysinfo

# start the tests
log "Test Start"
trap "my_exit" 2 3 9 15
if [ -f "${profile}" ];then
  log "FIO Test With profile ${profile}"
  cat ${profile} | tail -n +2 | egrep -v "^[ \t]*$" | grep -v "^#" | while read bs iodepth size runtime time_based numjobs offset rw rwmixread
  do
    launch_fio
  done
else
  launch_fio
fi
result_file="${output_dir}/result.csv"
print_header > ${result_file}
if [ -f "${profile}" ];then
  cat ${profile} | tail -n +2 | egrep -v "^[ \t]*$" | grep -v "^#" | while read bs iodepth size runtime time_based numjobs offset rw rwmixread
  do
    model_name="${bs}_${iodepth}_${numjobs}_${rw}"
    if [ "${rw}" == "rw" -o "${rw}" == "randrw" ];then
      model_name="${model_name}_${rwmixread}"
    fi
    model_dir=${output_dir}/${model_name}
    parse_dir ${model_dir} >> ${result_file}
  done
else
  model_name="${bs}_${iodepth}_${numjobs}_${rw}"
  if [ "${rw}" == "rw" -o "${rw}" == "randrw" ];then
    model_name="${model_name}_${rwmixread}"
  fi
    model_dir=${output_dir}/${model_name}
    parse_dir ${model_dir} >> ${result_file}
fi
summary_file="${output_dir}/summary.csv"
print_header | tee ${summary_file}
cat ${result_file} | tail -n +2 | awk '{print $1}' | sed s'/[a-zA-Z]*_//' | uniq | while read model
do
  cat ${result_file} | grep "_${model}" | awk -v model="${model}" 'BEGIN{minLat=10000;maxLat=0}{iops+=$2;bw+=$3;lat+=$4;minLat=$5<minLat?$5:minLat;maxLat=$6>maxLat?$6:maxLat;lat90+=$7}END{printf("%20s\t%10d\t%10.2f\t%10.2f\t%10.2f\t%10.2f\t%10.2f\n",model,iops,bw,lat/NR,minLat,maxLat,lat90/NR)}' | tee -a ${summary_file}
done
#parse_dir ${output_dir}
log "Test Done"

# prepare the result tar.gz
#results
date_time=$(date +%Y%m%d_%H%M)
fio_result_file="fio_result_${date_time}.tar.gz"
tar -czf "${fio_result_file}" ${output_dir}/
log "FIO Result: ${fio_result_file}"
exit 0
