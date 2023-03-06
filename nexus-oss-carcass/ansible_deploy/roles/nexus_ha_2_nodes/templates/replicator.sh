#!/bin/bash

# PREREQUISITS CHECK
if [[ ! -d "/etc/carcass/" ]]; then
  echo -e "Config directory /etc/carcass/ does not exist for carcass cluster controller!"
  exit 1
elif [[ ! -f "/etc/carcass/carcass.conf" ]]; then
  echo -e "Config for carcass cluster controller does not exist in path /etc/carcass/!"
  exit 1
else
source /etc/carcass/carcass.conf
fi

# Variables of the logical state
echo -e "\n$INFO_MESSAGE Set variables of the nexus cluster state" >> "$CURRENT_REPLICATION_LOG_FILE"
unset MASTER_CHECK BACKUP_CHECK DO_I_HAVE_A_VIP 
MASTER_CHECK=$(grep "state MASTER" /etc/keepalived/keepalived.conf | awk '{ print $2 }')
BACKUP_CHECK=$(grep "state BACKUP" /etc/keepalived/keepalived.conf | awk '{ print $2 }')
DO_I_HAVE_A_VIP=$(ip a | grep secondary | awk '{print $2}' | sed "s|\/.*||g")

if [[ "$MASTER_CHECK" = "MASTER" ]]; then
  CURRENT_NODE_ADDR=$NODE_1_ADDR
  OTHER_NODE_ADDR=$NODE_2_ADDR
  CURRENT_NODE_SSH_OPTS=$AUTH_1_NODE_OPTS
  OTHER_NODE_SSH_OPTS=$AUTH_2_NODE_OPTS
elif [[ "$BACKUP_CHECK" = "BACKUP" ]]; then 
  CURRENT_NODE_ADDR=$NODE_2_ADDR
  OTHER_NODE_ADDR=$NODE_1_ADDR
  CURRENT_NODE_SSH_OPTS=$AUTH_2_NODE_OPTS
  OTHER_NODE_SSH_OPTS=$AUTH_1_NODE_OPTS
fi

# MASTER/BACKUP ROLE CHECK
echo -e "$INFO_MESSAGE Starting role check" >> "$CURRENT_REPLICATION_LOG_FILE"
if ! [[ -z "$DO_I_HAVE_A_VIP" ]]; then
  unset PIDS
  echo -e "$INFO_MESSAGE This node is the ACTIVE MASTER" >> "$CURRENT_REPLICATION_LOG_FILE"
  echo -e "$INFO_MESSAGE Seems what i'm ACTIVE MASTER node with VIP - $DO_I_HAVE_A_VIP" >> "$CURRENT_REPLICATION_LOG_FILE"
  echo -e "$INFO_MESSAGE Starting check of Replica network availabillity" >> "$CURRENT_REPLICATION_LOG_FILE"
    if [[ -z $($OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo ls /) ]]; then
      echo -e "$ERROR_MESSAGE Replica's network is not available - SSH CHECK false" >> "$CURRENT_REPLICATION_LOG_FILE"
      echo -e "$NOTICE_MESSAGE Let's ping confidiant server" >> "$CURRENT_REPLICATION_LOG_FILE"
        if [[ $(ping -c "$PING_PACKAGE_COUNT" -W "$PING_TIMEOUT" -q "$CONFIDANT_ADDR" | grep received | awk '{print $4,$5}' | sed 's|,||') = "0 received" ]]; then
          echo -e "$CRITICAL_MESSAGE Confidiant server $CONFIDANT_ADDR is not available. Looks like a splitbrain. I'm alone! Stopping my nexus-oss container! Exit 1!" >> "$CURRENT_REPLICATION_LOG_FILE"
          docker-compose -f "$DOCKER_COMPOSE_FILE_PATH" down 
          exit 1
        else
          echo -e "$NOTICE_MESSAGE Confidiant server $CONFIDANT_ADDR is available! Looks like Replica goes down. Stop handling of replication logic. Waiting replica. Exit 0." >> "$CURRENT_REPLICATION_LOG_FILE"          
          exit 0
        fi
    else
      echo -e "$SUCCESS_MESSAGE Check of Replica network availabillity done - available!" >> "$CURRENT_REPLICATION_LOG_FILE"  
    fi

  echo -e "$INFO_MESSAGE Starting check activity time of "$CURRENT_NODE_ADDR"" >> "$CURRENT_REPLICATION_LOG_FILE"
  MASTER_FIX_DAYS_VALUE=$(cat "$TIME_FIXATION_FILE_PATH" | awk '{print $4}')     
  MASTER_FIX_HOURS_VALUE=$(cat "$TIME_FIXATION_FILE_PATH" | awk '{print $6}')     
  MASTER_FIX_MINUTES_VALUE=$(cat "$TIME_FIXATION_FILE_PATH" | awk '{print $8}')
  echo -e "$INFO_MESSAGE Master activity of "$CURRENT_NODE_ADDR": $MASTER_FIX_MINUTES_VALUE minutes" >> "$CURRENT_REPLICATION_LOG_FILE"
  echo -e "$INFO_MESSAGE Starting check activity time of "$OTHER_NODE_ADDR"" >> "$CURRENT_REPLICATION_LOG_FILE"
  $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo test -f "$TIME_FIXATION_FILE_PATH"
  TIME_FIX_PATH_EXIST=($?)
    if [[ "$TIME_FIX_PATH_EXIST" -eq 0 ]]; then 
      REPLICA_FIX_DAYS_VALUE=$($OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo cat "$TIME_FIXATION_FILE_PATH" | awk '{print $4}')     
      REPLICA_FIX_HOURS_VALUE=$($OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo cat "$TIME_FIXATION_FILE_PATH" | awk '{print $6}')     
      REPLICA_FIX_MINUTES_VALUE=$($OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo cat "$TIME_FIXATION_FILE_PATH" | awk '{print $8}')
      echo -e "$INFO_MESSAGE Master activity of "$OTHER_NODE_ADDR": $REPLICA_FIX_MINUTES_VALUE minutes" >> "$CURRENT_REPLICATION_LOG_FILE"
    else
      echo -e "$INFO_MESSAGE Master activity check file of "$OTHER_NODE_ADDR" does not exist" >> "$CURRENT_REPLICATION_LOG_FILE"
    fi
  echo -e "$INFO_MESSAGE Starting check of emergency file on other node "$OTHER_NODE_ADDR"" >> "$CURRENT_REPLICATION_LOG_FILE"
  $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo test -f "$BAD_STATE_FILE_PATH"
  BAD_STATE_PATH_EXIST=($?)
    if [[ "$BAD_STATE_PATH_EXIST" -eq 0 ]]; then 
      echo -e "$INFO_MESSAGE Emergency file in path $BAD_STATE_FILE_PATH on "$OTHER_NODE_ADDR" exist" >> "$CURRENT_REPLICATION_LOG_FILE"
    else
      echo -e "$INFO_MESSAGE Emergency file in path $BAD_STATE_FILE_PATH on "$OTHER_NODE_ADDR" not exist" >> "$CURRENT_REPLICATION_LOG_FILE"
    fi

    if [[ "$MASTER_FIX_MINUTES_VALUE" -lt "$NODE_MASTER_STATE_UPTIME_MINUTES_LIMITER" ]]; then
      echo -e "$INFO_MESSAGE Current master activity time not greater than $NODE_MASTER_STATE_UPTIME_MINUTES_LIMITER minutes. Replication tasks cannot start. Exit with code 0." >> "$CURRENT_REPLICATION_LOG_FILE"
      exit 0
    fi

  echo -e "$INFO_MESSAGE Starting check disk space of "$CURRENT_NODE_ADDR" in the background mode" >> "$CURRENT_REPLICATION_LOG_FILE"
  du -shm "$NEXUS_OSS_STORE_PATH" > "$CURRENT_REPLICATION_MASTER_CHECK_FILE" &
  PIDS+=($!)
  echo -e "$INFO_MESSAGE Write pid in PIDS variable" >> "$CURRENT_REPLICATION_LOG_FILE"
  echo -e "$INFO_MESSAGE Starting check disk space of "$OTHER_NODE_ADDR" in the background mode" >> "$CURRENT_REPLICATION_LOG_FILE" 
  $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo du -shm "$NEXUS_OSS_STORE_PATH" > "$CURRENT_REPLICATION_BACKUP_CHECK_FILE" &
  PIDS+=($!)
  echo -e "$INFO_MESSAGE Write pid in PIDS variable" >> "$CURRENT_REPLICATION_LOG_FILE"
   echo -e "$INFO_MESSAGE Starting waiting pids" >> "$CURRENT_REPLICATION_LOG_FILE"
    for pid in "${PIDS[@]}"; do
      echo -e "$INFO_MESSAGE PID - ${pid} waiting for complete" >> "$CURRENT_REPLICATION_LOG_FILE"
      unset STATUS
      wait ${pid}
      STATUS=($?)
      echo -e "$SUCCESS_MESSAGE PID - ${pid} completed" >> "$CURRENT_REPLICATION_LOG_FILE"
        if ! [[ "$STATUS" -eq 0 ]]; then 
          echo -e "$ERROR_MESSAGE PID - ${pid}, is not complete successfully. Return code - "$STATUS". Exit with code 1!" >> "$CURRENT_REPLICATION_LOG_FILE"
          exit 1
        else
          echo -e "$SUCCESS_MESSAGE PID - ${pid}, complete successfully."
        fi
    done
  echo -e "$INFO_MESSAGE Fixing used disk space on Master and Backup" >> "$CURRENT_REPLICATION_LOG_FILE"
  CHECK_MASTER_REPL_STATUS=$(awk '{print $1}' "$CURRENT_REPLICATION_MASTER_CHECK_FILE")
  echo -e "$INFO_MESSAGE Master used volume space status: "$CHECK_MASTER_REPL_STATUS"" >> "$CURRENT_REPLICATION_LOG_FILE"  
  CHECK_BACKUP_REPL_STATUS=$(awk '{print $1}' "$CURRENT_REPLICATION_BACKUP_CHECK_FILE")
  echo -e "$INFO_MESSAGE Backup used volume space status: "$CHECK_BACKUP_REPL_STATUS"" >> "$CURRENT_REPLICATION_LOG_FILE"
    if [[ "$CHECK_MASTER_REPL_STATUS" -gt "CHECK_BACKUP_REPL_STATUS" ]]; then 
      NODE_SIZE_VARIETY=$(echo "$CHECK_MASTER_REPL_STATUS-$CHECK_BACKUP_REPL_STATUS" | bc)
      echo -e "$INFO_MESSAGE Node size variety: "$NODE_SIZE_VARIETY" MiB. Master is bigger then replica" >> "$CURRENT_REPLICATION_LOG_FILE"
      echo -e "$INFO_MESSAGE Value of Safety node size variety limiter set on: "$SAFETY_NODE_SIZE_VARIETY_LIMITER" MiB." >> "$CURRENT_REPLICATION_LOG_FILE"
    elif [[ "$CHECK_MASTER_REPL_STATUS" -lt "CHECK_BACKUP_REPL_STATUS" ]]; then 
      NODE_SIZE_VARIETY=$(echo "$CHECK_BACKUP_REPL_STATUS-$CHECK_MASTER_REPL_STATUS" | bc)
      echo -e "$INFO_MESSAGE Node size variety: "$NODE_SIZE_VARIETY" MiB. Replica is bigger then master" >> "$CURRENT_REPLICATION_LOG_FILE"
      echo -e "$INFO_MESSAGE Value of Safety node size variety limiter set on: "$SAFETY_NODE_SIZE_VARIETY_LIMITER" MiB. Before limiter is not exceed - don't worry :)" >> "$CURRENT_REPLICATION_LOG_FILE"
     fi

  echo -e "$INFO_MESSAGE Value of Node size variety limiter set on: "$NODE_SIZE_VARIETY_LIMITER" MiB. Replication will starting when limiter value exceed and other conditions complete." >> "$CURRENT_REPLICATION_LOG_FILE"
  echo -e "$NOTICE_MESSAGE Starting check of master unconsistant state" >> "$CURRENT_REPLICATION_LOG_FILE"
  
    if [[ "$CHECK_MASTER_REPL_STATUS" -lt "CHECK_BACKUP_REPL_STATUS" ]] && ! [[ "$TIME_FIX_PATH_EXIST" -eq 0 ]] &&
     [[ "$NODE_SIZE_VARIETY" -ge "$SAFETY_NODE_SIZE_VARIETY_LIMITER" ]]; then
       echo -e "$INFO_MESSAGE Replication from master to backup was started by condition when replica was not be a master" >> "$CURRENT_REPLICATION_LOG_FILE"
       echo -e "$INFO_MESSAGE Creating replication tag file on Replica on path: $REPLICATION_CHECK_FILE_PATH" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo touch "$REPLICATION_CHECK_FILE_PATH"
       echo -e "$INFO_MESSAGE Down nexus containers on replica" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo docker-compose -f "$DOCKER_COMPOSE_FILE_PATH" down 
       echo -e "$INFO_MESSAGE Running rsync replication process" >> "$CURRENT_REPLICATION_LOG_FILE"
       rsync -ahH --delete --exclude=karaf.pid --contimeout="$RSYNC_TIMEOUT" --stats --password-file=/etc/rsync_cli_p.scrt "$NEXUS_OSS_STORE_PATH" rsync://nobody@"$OTHER_NODE_ADDR"/nexus-oss &>> "$CURRENT_REPLICATION_LOG_FILE" 
       echo -e "$SUCCESS_MESSAGE Replication from master to backup was end" >> "$CURRENT_REPLICATION_LOG_FILE"
       echo -e "$INFO_MESSAGE Up nexus containers on replica " >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo docker-compose -f "$DOCKER_COMPOSE_FILE_PATH" up -d 
       echo -e "$INFO_MESSAGE Removing replication tag file on Replica on path: $REPLICATION_CHECK_FILE_PATH" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo rm -f "$REPLICATION_CHECK_FILE_PATH"
    elif [[ "$CHECK_MASTER_REPL_STATUS" -lt "CHECK_BACKUP_REPL_STATUS" ]] && [[ "$TIME_FIX_PATH_EXIST" -eq 0 ]] &&
     [[ "$NODE_SIZE_VARIETY" -ge "$SAFETY_NODE_SIZE_VARIETY_LIMITER" ]] && ! [[ -z $(find "$LOG_DIR" -mmin -480 -type f -name "$TIME_FIXATION_FILE_NAME") ]] &&
     [[ "$BAD_STATE_PATH_EXIST" -eq 0 ]]; then
       echo -e "$INFO_MESSAGE Replication from master to backup was started by condition when replica bigger than master and master_activity_file exist, but she state is broken" >> "$CURRENT_REPLICATION_LOG_FILE"
       echo -e "$INFO_MESSAGE Creating replication tag file on Replica on path: $REPLICATION_CHECK_FILE_PATH" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo touch "$REPLICATION_CHECK_FILE_PATH"
       echo -e "$INFO_MESSAGE Down nexus containers on replica" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo docker-compose -f "$DOCKER_COMPOSE_FILE_PATH" down 
       echo -e "$INFO_MESSAGE Running rsync replication process" >> "$CURRENT_REPLICATION_LOG_FILE"
       rsync -ahH --delete --exclude=karaf.pid --contimeout="$RSYNC_TIMEOUT" --stats --password-file=/etc/rsync_cli_p.scrt "$NEXUS_OSS_STORE_PATH" rsync://nobody@"$OTHER_NODE_ADDR"/nexus-oss &>> "$CURRENT_REPLICATION_LOG_FILE" 
       echo -e "$SUCCESS_MESSAGE Replication from master to backup was end" >> "$CURRENT_REPLICATION_LOG_FILE"
       echo -e "$INFO_MESSAGE Up nexus containers on replica " >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo docker-compose -f "$DOCKER_COMPOSE_FILE_PATH" up -d 
       echo -e "$INFO_MESSAGE Removing replication tag file on Replica on path: $REPLICATION_CHECK_FILE_PATH" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo rm -f "$REPLICATION_CHECK_FILE_PATH"
       echo -e "$INFO_MESSAGE Removing time fixation file on Replica on path: $TIME_FIXATION_FILE_PATH" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo rm -f "$TIME_FIXATION_FILE_PATH"
    elif [[ "$CHECK_MASTER_REPL_STATUS" -lt "CHECK_BACKUP_REPL_STATUS" ]] && [[ "$TIME_FIX_PATH_EXIST" -eq 0 ]] &&
     [[ "$NODE_SIZE_VARIETY" -ge "$SAFETY_NODE_SIZE_VARIETY_LIMITER" ]] && ! [[ -z $(find "$LOG_DIR" -mmin -480 -type f -name "$TIME_FIXATION_FILE_NAME") ]] &&
     ! [[ "$BAD_STATE_PATH_EXIST" -eq 0 ]]; then
       echo -e "$CRITICAL_MESSAGE Current MASTER $CURRENT_NODE_ADDR node volume size less than REPLICA! Safety Limiter value has been exceed!" >> "$CURRENT_REPLICATION_LOG_FILE"
       echo -e "$CRITICAL_MESSAGE SW-OVER PROCESS HAS BEEN STARTING IMMEDIATELY!!!" >> "$CURRENT_REPLICATION_LOG_FILE"
       echo -e "$CRITICAL_MESSAGE Down nexus through docker compose file!" >> "$CURRENT_REPLICATION_LOG_FILE"
       docker-compose -f "$DOCKER_COMPOSE_FILE_PATH" down 
       echo -e "$NOTICE_MESSAGE Replica should do synchronize data between cluster members. When replica do it, new election of the master started. Exit code 1." >> "$CURRENT_REPLICATION_LOG_FILE"
       exit 1
    fi    

    if [[ "$CHECK_MASTER_REPL_STATUS" -gt "CHECK_BACKUP_REPL_STATUS" ]] && ! [[ "$TIME_FIX_PATH_EXIST" -eq 0 ]] &&
     [[ "$NODE_SIZE_VARIETY" -ge "$NODE_SIZE_VARIETY_LIMITER" ]]; then
       echo -e "$INFO_MESSAGE Replication from master to backup was started by condition when replica was not be a master" >> "$CURRENT_REPLICATION_LOG_FILE"
       echo -e "$INFO_MESSAGE Creating replication tag file on Replica on path: $REPLICATION_CHECK_FILE_PATH" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo touch "$REPLICATION_CHECK_FILE_PATH"
       echo -e "$INFO_MESSAGE Down nexus containers on replica" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo docker-compose -f "$DOCKER_COMPOSE_FILE_PATH" down 
       echo -e "$INFO_MESSAGE Running rsync replication process" >> "$CURRENT_REPLICATION_LOG_FILE"
       rsync -ahH --delete --exclude=karaf.pid --contimeout="$RSYNC_TIMEOUT" --stats --password-file=/etc/rsync_cli_p.scrt "$NEXUS_OSS_STORE_PATH" rsync://nobody@"$OTHER_NODE_ADDR"/nexus-oss &>> "$CURRENT_REPLICATION_LOG_FILE" 
       echo -e "$SUCCESS_MESSAGE Replication from master to backup was end" >> "$CURRENT_REPLICATION_LOG_FILE"
       echo -e "$INFO_MESSAGE Up nexus containers on replica " >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo docker-compose -f "$DOCKER_COMPOSE_FILE_PATH" up -d 
       echo -e "$INFO_MESSAGE Removing replication tag file on Replica on path: $REPLICATION_CHECK_FILE_PATH" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo rm -f "$REPLICATION_CHECK_FILE_PATH"       
    else
       echo -e "$INFO_MESSAGE Replication from master to backup by condition when replica was not be a master was not started - mismatch" >> "$CURRENT_REPLICATION_LOG_FILE"
    fi    

    if [[ "$CHECK_MASTER_REPL_STATUS" -gt "CHECK_BACKUP_REPL_STATUS" ]] && [[ "$TIME_FIX_PATH_EXIST" -eq 0 ]] &&
     [[ "$NODE_SIZE_VARIETY" -ge "$SAFETY_NODE_SIZE_VARIETY_LIMITER" ]]; then
       echo -e "$INFO_MESSAGE Replication from master to backup was started by condition when replica was be a master and current master uptime greater than $NODE_MASTER_STATE_UPTIME_MINUTES_LIMITER mins" >> "$CURRENT_REPLICATION_LOG_FILE"
       echo -e "$INFO_MESSAGE Creating replication tag file on Replica on path: $REPLICATION_CHECK_FILE_PATH" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo touch "$REPLICATION_CHECK_FILE_PATH"
       echo -e "$INFO_MESSAGE Down nexus containers on replica" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo docker-compose -f "$DOCKER_COMPOSE_FILE_PATH" down 
       echo -e "$INFO_MESSAGE Running rsync replication process" >> "$CURRENT_REPLICATION_LOG_FILE"
       rsync -ahH --delete --exclude=karaf.pid --contimeout="$RSYNC_TIMEOUT" --stats --password-file=/etc/rsync_cli_p.scrt "$NEXUS_OSS_STORE_PATH" rsync://nobody@"$OTHER_NODE_ADDR"/nexus-oss &>> "$CURRENT_REPLICATION_LOG_FILE" 
       echo -e "$SUCCESS_MESSAGE Replication from master to backup was end" >> "$CURRENT_REPLICATION_LOG_FILE"
       echo -e "$INFO_MESSAGE Up nexus containers on replica " >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo docker-compose -f "$DOCKER_COMPOSE_FILE_PATH" up -d 
       echo -e "$INFO_MESSAGE Removing replication tag file on Replica on path: $REPLICATION_CHECK_FILE_PATH" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo rm -f "$REPLICATION_CHECK_FILE_PATH"       
       echo -e "$INFO_MESSAGE Removing time fixation file on Replica on path: $TIME_FIXATION_FILE_PATH" >> "$CURRENT_REPLICATION_LOG_FILE"
       $OTHER_NODE_SSH_OPTS@$OTHER_NODE_ADDR sudo rm -f "$TIME_FIXATION_FILE_PATH" 
    else   
       echo -e "$INFO_MESSAGE Replication from master to backup by condition when replica was be a master and current safety counter greater than $SAFETY_NODE_SIZE_VARIETY_LIMITER MiB - mismatch" >> "$CURRENT_REPLICATION_LOG_FILE"
    fi
#    echo -e "$SUCCESS_MESSAGE Check of master unconsistant state - false. Master consistent" >> "$CURRENT_REPLICATION_LOG_FILE"
    echo -e "$INFO_MESSAGE All tasks done." >> "$CURRENT_REPLICATION_LOG_FILE"
else
  echo -e "$INFO_MESSAGE Seems what i'm not ACTIVE MASTER NODE" >> "$CURRENT_REPLICATION_LOG_FILE"   
  echo -e "$INFO_MESSAGE All tasks done." >> "$CURRENT_REPLICATION_LOG_FILE"
fi