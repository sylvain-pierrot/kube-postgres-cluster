#!/bin/bash
set -ex

ascii_primary() {
    cat <<- 'EOF'
  _____      _                               _____                          
|  __ \    (_)                             / ____|                         
| |__) | __ _ _ __ ___   __ _ _ __ _   _  | (___   ___ _ ____   _____ _ __ 
|  ___/ '__| | '_ ` _ \ / _` | '__| | | |  \___ \ / _ \ '__\ \ / / _ \ '__|
| |   | |  | | | | | | | (_| | |  | |_| |  ____) |  __/ |   \ V /  __/ |   
|_|   |_|  |_|_| |_| |_|\__,_|_|   \__, | |_____/ \___|_|    \_/ \___|_|   
                                    __/ |                                  
                                    |___/                                                            
EOF
}

ascii_standby() {
    cat <<- 'EOF'
  _____ _                  _ _              _____                          
 / ____| |                | | |            / ____|                         
| (___ | |_ __ _ _ __   __| | |__  _   _  | (___   ___ _ ____   _____ _ __ 
 \___ \| __/ _` | '_ \ / _` | '_ \| | | |  \___ \ / _ \ '__\ \ / / _ \ '__|
 ____) | || (_| | | | | (_| | |_) | |_| |  ____) |  __/ |   \ V /  __/ |   
|_____/ \__\__,_|_| |_|\__,_|_.__/ \__, | |_____/ \___|_|    \_/ \___|_|   
                                    __/ |                                  
                                    |___/                                                                                             
EOF
}

wait_for_postgres() {
  local start_time=$(date +%s)
  local end_time=$((start_time + 30))
  until pg_isready -h postgres-cluster-0.postgres-cluster.postgres.svc.cluster.local -p 5433 -q &>/dev/null; do
    echo "Waiting for PostgreSQL to be ready..."
    sleep 5
    local current_time=$(date +%s)
    if [[ $current_time -gt $end_time ]]; then
        echo "Timed out waiting for PostgreSQL."
        return 1
    fi
  done
  echo "PostgreSQL is ready."
  return 0
}

get_ordinal() {
  if [[ $(hostname) =~ -([0-9]+)$ ]]; then
      echo "${BASH_REMATCH[1]}"
  else
      exit 1
  fi
}

configure_primary() {
  ascii_primary

  psql -p 5433 -c "CREATE ROLE repluser WITH REPLICATION PASSWORD 'replication' LOGIN;"
  psql -p 5433 -c "SELECT * FROM pg_create_physical_replication_slot('pg1_slot');"
  psql -p 5433 -c "SELECT slot_name FROM pg_replication_slots;"

  cat << EOF >> /etc/postgresql/15/$HOSTNAME/postgresql.conf
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
wal_sender_timeout = '60s'
max_replication_slots = 10
EOF
  echo "host replication repluser 10.244.0.0/16 md5" | tee -a /etc/postgresql/15/$HOSTNAME/pg_hba.conf
}

configure_replica() {
  ascii_standby
  
  wait_for_postgres

  #psql -p 5433 -c "SELECT * FROM pg_create_physical_replication_slot('pg0_slot');"
  #service postgresql restart

  cat << EOF >> /etc/postgresql/15/$HOSTNAME/postgresql.conf
primary_conninfo = 'host=postgres-cluster-0.postgres-cluster.postgres.svc.cluster.local port=5433 user=repluser password=replication sslmode=prefer sslcompression=1'
primary_slot_name = 'pg1_slot'
hot_standby = on
wal_receiver_timeout = '60s'
EOF

  #echo "host replication repluser 10.244.0.0/16 md5" | tee -a /etc/postgresql/15/$HOSTNAME/pg_hba.conf

  service postgresql stop

  rm -rf /var/lib/postgresql/15/$HOSTNAME/*
  pg_basebackup -h postgres-cluster-0.postgres-cluster.postgres.svc.cluster.local -p 5433 -D /var/lib/postgresql/15/$HOSTNAME/ -U repluser -v -P -X stream -c fast
    
  touch /var/lib/postgresql/15/$HOSTNAME/standby.signal
}

# Main script starts here

pg_createcluster -p 5433 15 $HOSTNAME
pg_ctlcluster 15 $HOSTNAME start
pg_ctlcluster 15 $HOSTNAME status

ordinal=$(get_ordinal)

if [[ $ordinal -eq 0 ]]; then
  configure_primary
else
  configure_replica
fi

service postgresql restart