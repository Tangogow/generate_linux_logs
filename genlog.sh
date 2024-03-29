#!/bin/bash

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo -e "Usage: $0 <number_of_logs> <logs_per_second> <log_size> <log_path> [<remote_server>]\n"
  echo "logs_per_second: in seconds (minimum 1)"
  echo "log_size: in bytes for each log entry"
  echo "log_path: the path of your log file. By default use /var/log/messages"
  echo "remote_server: forward your logs to a remote syslog server ip:port ie: 192.168.0.1:514 (optional)"
  echo "You may be restricted by the number of logs per second, depending on your OS and disk IO's"
  exit 1
fi

# trap Ctrl+C to display report
trap ctrl_c INT

number_of_logs=$1
logs_per_second=$2
log_size=$3
log_path=$4
remote_server=$5 # format ip:port
logs_generated=0
include_ip=true # include IP at the beginning of the log
result_path="/var/log/gll/" 

if [ ! -f "$log_path" ]; then
  touch $log_path
fi
if [[ -z $CONTAINER_NAME ]]; then
  export CONTAINER_NAME="gll"
fi
rm /var/log/gll/$CONTAINER_NAME.log 2> /dev/null
if [ ! -f "$result_path/$CONTAINER_NAME.log" ]; then
  mkdir $result_path
  touch $CONTAINER_NAME.log
fi
if [ -z "$remote_server" ]; then # copying FAKE logs to the provided path
  echo -e "if \$programname == 'FAKE' then $log_path\n& stop" > /etc/rsyslog.d/01-logger.conf
else
  echo -e "if \$programname == 'FAKE' then $log_path\nif \$programname == 'FAKE' then @@$remote_server& stop" > /etc/rsyslog.d/01-logger.conf
fi
#logger -f $log_path

# force restart with a random PID to not overlap since systemctl, service and lsof don't work
rsyslogd -i $((RANDOM % (65000 - 30000 + 1) + 30000)) 2> /dev/null



function report {
  duration=$(($end_time - $start_time))
  duration_secs=$duration
  if [ $duration -lt 60 ]; then
    duration=$duration" secs"
  elif [ $duration -lt 3600 ]; then
    duration=$(($duration / 60))" mins"
  else
    duration=$(($duration / 3600))" hours"
  fi
  estimated_duration=$(($logs_generated / $logs_per_second))
  real_logs_per_second=$(($logs_generated / $duration_secs))
  total_size=$(($logs_generated * $log_size))
  total_size_bytes=$total_size
  if [ $total_size -lt 1024 ]; then
    total_size=$total_size" B"
  elif [ $total_size -lt 1048576 ]; then
    total_size=$(($total_size / 1024))" KB"
  elif [ $total_size -lt 1073741824 ]; then
    total_size=$(($total_size / 1048576))" MB"
  else
    total_size=$(($total_size / 1073741824))" GB"
  fi

  echo "===FAKE LOGS REPORT==="
  echo "Logs generated     " $logs_generated
  echo "Wanted logs/s      " $logs_per_second
  echo "Real logs/s        " $real_logs_per_second
  echo "Total size         " $total_size
  echo "Estimated Duration " $estimated_duration
  echo "Real Duration      " $duration

  local result="$logs_generated,$logs_per_second,$real_logs_per_second,$total_size_bytes,$estimated_duration,$duration_secs"
  echo $result > /var/log/gll/$CONTAINER_NAME.log 2> /dev/null
  exit 0
}

function ctrl_c {
  end_time=$(date +%s)
  report
}

start_time=$(date +%s)

function generate_message {
  message=""
  if [[ $include_ip == true ]]; then
    message="$(hostname -I) "
  fi
  message="$message "$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w $log_size | head -n 1)

  logger -t FAKE -p user.info "$message"
  if ! [[ -z "$remote_server" ]]; then
    IFS=':' read -r ip port <<< "$remote_server" # split ip:port string in half
    logger -t FAKE -p user.info -n $ip -P $port -T "$message"
  fi
}

function generate_log {
  sleep_duration=$(awk "BEGIN {print 1/$logs_per_second}")

  # Generate logs until the desired number is reached
  echo "Generating logs..."
  while [[ "$logs_generated" -lt "$number_of_logs" ]]; do
    generate_message
    logs_generated=$((logs_generated + 1))
    logs_per_second_count=$((logs_per_second_count + 1))

    echo "Log n°" $logs_generated
    if [[ "$logs_per_second_count" -eq "$logs_per_second" ]]; then
      echo "Generated $logs_per_second_count logs"
      logs_per_second_count=0
    fi
    #echo "Logs/s: " `awk -v d1="$(date --date='-1 second' +'%b %d %H:%M:%S')" -v d2="$(date +'%b %d %H:%M:%S')" \
    #'$0 > d1 && $0 < d2 || $0 ~ d2' $log_path | wc -l`
    sleep "$sleep_duration"
  done

  end_time=$(date +%s)
  report
}

generate_log