#!/bin/bash
set -e

if [ "$(alias | grep -wc grep)" -gt 0 ]; then
  unalias grep
fi
if [ "$(alias | grep -wc ls)" -gt 0 ]; then
  unalias ls
fi

################################################################################
####  Unexported functions  ####################################################
################################################################################

function check_variables() {
  if [ "${LOG_DEBUG}" == "true" ]; then
    log_time "Sourcing ${VARS_FILE}"
  fi
  # shellcheck source=tpcds_variables.sh
  source ./${VARS_FILE} 2> /dev/null
  if [ $? -ne 0 ]; then
    log_time "./${VARS_FILE} does not exist. Please ensure that this file exists before running TPC-DS. Exiting."
    exit 1
  fi

  # Extract all exported variable names from non-commented lines
  local missing_vars=()
  local var_names
  var_names=$(grep -E '^[[:space:]]*export[[:space:]]+' ./${VARS_FILE} | grep -v '^[[:space:]]*#' | awk '{print $2}' | cut -d= -f1)

  for var in $var_names; do
    if [ "$var" = "PSQL_OPTIONS" ]; then
      # Allow PSQL_OPTIONS to be empty
      continue
    fi
    if [ -z "${!var}" ]; then
      log_time "ERROR: Variable '$var' is not set or is empty in ${VARS_FILE}."
      missing_vars+=("$var")
    fi
  done

  if [ ${#missing_vars[@]} -ne 0 ]; then
    log_time "The following required variables are missing or empty: ${missing_vars[*]}"
    log_time "Please check the ${VARS_FILE}, verify that the database is up and running and psql can connect to the database."
    exit 1
  fi
}

function check_admin_user() {
  if [ "${LOG_DEBUG}" == "true" ]; then
    log_time "Ensure ${ADMIN_USER} is executing this script."
  fi
  if [ "$(whoami)" != "${ADMIN_USER}" ]; then
    log_time "Script must be executed as ${ADMIN_USER}!"
    exit 1
  fi
}

function print_header() {
  log_time "ADMIN_USER: ${ADMIN_USER}"
  log_time "BENCH_ROLE: ${BENCH_ROLE}"
  log_time "PSQL_OPTIONS: ${PSQL_OPTIONS}"
  log_time "RUN_MODEL: ${RUN_MODEL}"
  log_time "LOG_DEBUG: ${LOG_DEBUG}"
  log_time "GEN_DATA_SCALE: ${GEN_DATA_SCALE}"
  log_time "MULTI_USER_COUNT: ${MULTI_USER_COUNT}"
  log_time "DB_SCHEMA_NAME: ${DB_SCHEMA_NAME}"
}

# we need to declare this outside, otherwise, the declare will wipe out the
# value within a function
declare startup_file
startup_file=${HOME}/.bashrc
function source_bashrc() {
  if [ -f ${startup_file} ]; then
    # don't fail if an error is happening in the admin's profile
    # shellcheck disable=SC1090
    source ${startup_file} || true
    # Check if GPHOME is set and not empty
    if [ -z "$GPHOME" ]; then
      log_time "Error: \$GPHOME is not found. Please set .bashrc correctly for ${ADMIN_USER} to source the database environment.Exiting."
      exit 1
    fi
  else
    log_time "Error: ${startup_file} does not exist. Please ensure that this file is correctly set before running TPC-DS. Exiting."
    exit 1
  fi
}

################################################################################
####  Exported functions  ######################################################
################################################################################
function get_pwd() {
  # Handle relative vs absolute path
  [ ${1:0:1} == '/' ] && x=${1} || x=$PWD/${1}
  # Change to dirname of x
  cd ${x%/*}
  # Combine new pwd with basename of x
  echo "$(dirname "$(pwd -P)/${x##*/}")"
  cd ${OLDPWD}
}
export -f get_pwd

function get_gpfdist_port() {
  
  if [ "$RUN_MODEL" = "local" ]; then
    # Attempt to get port information with error handling
    if all_ports=$(psql ${PSQL_OPTIONS} -t -A -c "select min(case when role = 'p' then port else 999999 end), min(case when role = 'm' then port else 999999 end) from gp_segment_configuration where content >= 0"); then
      # Extract the first digit of port numbers and validate if they are numeric
      primary_base=$(echo ${all_ports} | awk -F '|' '{print $1}' | head -c1)
      mirror_base=$(echo $all_ports | awk -F '|' '{print $2}' | head -c1)
      
      # Validate if extracted values are numeric
      if ! [[ "$primary_base" =~ ^[0-9]$ ]] || ! [[ "$mirror_base" =~ ^[0-9]$ ]]; then
        # Use default values if not numeric
        primary_base=6
        mirror_base=6
      fi

      # Flag to track if a usable port is found
      port_found=false
      for i in $(seq 3 5); do
        if [ "${primary_base}" -ne "${i}" ] && [ "${mirror_base}" -ne "${i}" ]; then
          GPFDIST_PORT="${i}$(echo $(( $RANDOM % 1000 )) | awk '{printf "%03d", $1}')"
          port_found=true
          break
        fi
      done
      
      # Use default port range if no usable port is found
      if [ "$port_found" = false ]; then
        GPFDIST_PORT="3$(echo $(( $RANDOM % 1000 )) | awk '{printf "%03d", $1}')"
      fi
      
      export GPFDIST_PORT
    else
      # Use default port if database query fails
      GPFDIST_PORT="3$(echo $(( $RANDOM % 1000 )) | awk '{printf "%03d", $1}')"
      export GPFDIST_PORT
    fi
  else
    GPFDIST_PORT="3$(echo $(( $RANDOM % 1000 )) | awk '{printf "%03d", $1}')"
    export GPFDIST_PORT # Also need to export in non-local mode
  fi
}
export -f get_gpfdist_port

function get_version() {
  # Note: Call source_bashrc first to ensure environment is set up

  VERSION=$(psql ${PSQL_OPTIONS} -v ON_ERROR_STOP=1 -t -A -c "
    SELECT 
      CASE 
        WHEN POSITION('greenplum database 4.3' IN version) > 0 THEN 'gpdb_4_3'
        WHEN POSITION('greenplum database 5' IN version) > 0 AND 
             POSITION('synxdb' IN version) = 0 THEN 'gpdb_5'
        WHEN POSITION('greenplum database 6' IN version) > 0 AND
             POSITION('synxdb' IN version) = 0 THEN 'gpdb_6'
        WHEN POSITION('greenplum database 7' IN version) > 0 AND
             POSITION('synxdb' IN version) = 0 THEN 'gpdb_7'
        WHEN POSITION('greenplum database 5' IN version) > 0 AND 
             POSITION('synxdb' IN version) > 0 THEN 'synxdb_1'
        WHEN POSITION('greenplum database 6' IN version) > 0 AND
             POSITION('synxdb' IN version) > 0 THEN 'synxdb_2'
        WHEN POSITION('greenplum database 7' IN version) > 0 AND
             POSITION('synxdb' IN version) > 0 THEN 'synxdb_3'
        WHEN POSITION('cloudberry' IN version) > 0 AND 
             POSITION('lightning' IN version) > 0 THEN 'lightning'
        WHEN POSITION('cloudberry' IN version) > 0 AND 
             POSITION('hashdata enterprise 4' IN version) > 0 THEN 'hashdata_enterprise_4'
        WHEN POSITION('cloudberry' IN version) > 0 AND 
             POSITION('synxdb' IN version) > 0 THEN 'synxdb_4'
        WHEN POSITION('cloudberry' IN version) > 0 AND
             POSITION('synxdb' IN version) = 0 AND 
             POSITION('lightning' IN version) = 0 THEN 'cbdb'
        WHEN POSITION('postgresql' IN version) > 0 AND 
             POSITION('greenplum' IN version) = 0 AND 
             POSITION('cloudberry' IN version) = 0 AND
             POSITION('lightning' IN version) = 0 AND
             POSITION('synxdb' IN version) = 0 THEN 'postgresql'
        ELSE 'unknown'
      END 
    FROM lower(version()) as version;
  ")
  
  VERSION_FULL=$(psql ${PSQL_OPTIONS} -v ON_ERROR_STOP=1 -t -A -c "SELECT version();")
}
export -f get_version


function init_log() {
  logfile=rollout_${1}.log
  rm -f ${TPC_DS_DIR}/log/${logfile}
}
export -f init_log

function start_log() {
  T_START="$(date +%s)"
}
export -f start_log

# we need to declare this outside, otherwise, the declare will wipe out the
# value within a function
declare schema_name
declare table_name
function print_log() {
  #duration
  T_END="$(date +%s)"
  T_DURATION="$((T_END - T_START))"
  S_DURATION=${T_DURATION}

  #this is done for steps that don't have id values
  if [ "${id}" == "" ]; then
    id="1"
  else
    id=$(basename ${i} | awk -F '.' '{print $1}')
  fi

  tuples=${1}
  if [ "${tuples}" == "" ]; then
    tuples="0"
  fi

  # calling function adds schema_name and table_name
  printf "%s|%s.%s|%s|%02d:%02d:%02d|%d|%d\n" ${id} ${schema_name} ${table_name} ${tuples} "$((S_DURATION / 3600 % 24))" "$((S_DURATION / 60 % 60))" "$((S_DURATION % 60))" "${T_START}" "${T_END}" >> ${TPC_DS_DIR}/log/${logfile}
}
export -f print_log

function end_step() {
  local logfile=end_${1}.log
  touch ${TPC_DS_DIR}/log/${logfile}
}
export -f end_step

function log_time() {
  printf "[%s] %b\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$1"
}
export -f log_time

function create_hosts_file() {
  # not used for this function
  # get_version

  if [ "$RUN_MODEL" == "local" ]; then
    SQL_QUERY="SELECT DISTINCT hostname FROM gp_segment_configuration WHERE role = '${GPFDIST_LOCATION}' AND content >= 0 ORDER BY 1"
    psql ${PSQL_OPTIONS} -v ON_ERROR_STOP=1 -t -A -c "${SQL_QUERY}" -o ${TPC_DS_DIR}/segment_hosts.txt
  fi
}
export -f create_hosts_file

################################################################################
####  SynxDB Cloud Functions (kubectl-based)  ##################################
################################################################################

# Get segment pod names for the current warehouse
# Returns: space-separated list of pod names (e.g., "wh-1-segment-0 wh-1-segment-1")
function get_segment_pods() {
  if [ -z "${SYNXDB_NAMESPACE}" ]; then
    log_time "ERROR: SYNXDB_NAMESPACE is not set"
    return 1
  fi

  local warehouse="${SYNXDB_WAREHOUSE:-wh-1}"
  kubectl get pods -n "${SYNXDB_NAMESPACE}" \
    -l "enterprise.dbaas/component=warehouse,enterprise.dbaas/name=${warehouse}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
}
export -f get_segment_pods

# Get the number of segment pods
function get_segment_count() {
  local pods=$(get_segment_pods)
  echo "${pods}" | wc -w | tr -d ' '
}
export -f get_segment_count

# Execute a command on a specific segment pod
# Usage: kubectl_exec_segment <pod_name> <command>
function kubectl_exec_segment() {
  local pod_name=$1
  shift
  local cmd="$@"

  if [ -z "${SYNXDB_NAMESPACE}" ]; then
    log_time "ERROR: SYNXDB_NAMESPACE is not set"
    return 1
  fi

  kubectl exec -n "${SYNXDB_NAMESPACE}" "${pod_name}" -c segment -- \
    bash -c "source /usr/local/elastic-database/cluster_env.sh && ${cmd}"
}
export -f kubectl_exec_segment

# Execute a command on all segment pods in parallel
# Usage: kubectl_exec_all_segments <command>
function kubectl_exec_all_segments() {
  local cmd="$@"
  local pods=$(get_segment_pods)

  for pod in ${pods}; do
    kubectl_exec_segment "${pod}" "${cmd}" &
  done
  wait
}
export -f kubectl_exec_all_segments

# Copy a file to a specific segment pod
# Usage: kubectl_cp_to_segment <local_file> <pod_name> <remote_path>
function kubectl_cp_to_segment() {
  local local_file=$1
  local pod_name=$2
  local remote_path=$3

  if [ -z "${SYNXDB_NAMESPACE}" ]; then
    log_time "ERROR: SYNXDB_NAMESPACE is not set"
    return 1
  fi

  kubectl cp "${local_file}" "${SYNXDB_NAMESPACE}/${pod_name}:${remote_path}" -c segment
}
export -f kubectl_cp_to_segment

# Copy a file to all segment pods in parallel
# Usage: kubectl_cp_to_all_segments <local_file> <remote_path>
function kubectl_cp_to_all_segments() {
  local local_file=$1
  local remote_path=$2
  local pods=$(get_segment_pods)

  for pod in ${pods}; do
    kubectl_cp_to_segment "${local_file}" "${pod}" "${remote_path}" &
  done
  wait
}
export -f kubectl_cp_to_all_segments

# Create segment hosts file for synxdb-cloud mode
# Creates file with segment pod names
function create_synxdb_hosts_file() {
  local pods=$(get_segment_pods)
  echo "${pods}" | tr ' ' '\n' > ${TPC_DS_DIR}/segment_hosts.txt

  if [ "${LOG_DEBUG}" == "true" ]; then
    log_time "Created segment hosts file with $(wc -l < ${TPC_DS_DIR}/segment_hosts.txt) segments"
  fi
}
export -f create_synxdb_hosts_file

# Start gpfdist on a specific segment pod
# Usage: start_gpfdist_on_segment <pod_name> <port> <data_path>
function start_gpfdist_on_segment() {
  local pod_name=$1
  local port=$2
  local data_path=$3

  kubectl_exec_segment "${pod_name}" \
    "pkill -f 'gpfdist.*${data_path}' 2>/dev/null || true; \
     mkdir -p ${data_path}/logs; \
     nohup gpfdist -p ${port} -d ${data_path} > ${data_path}/logs/gpfdist.${port}.log 2>&1 &"
}
export -f start_gpfdist_on_segment

# Stop gpfdist on a specific segment pod
# Usage: stop_gpfdist_on_segment <pod_name> <data_path_pattern>
function stop_gpfdist_on_segment() {
  local pod_name=$1
  local data_path_pattern=$2

  kubectl_exec_segment "${pod_name}" "pkill -f 'gpfdist.*${data_path_pattern}' 2>/dev/null || true"
}
export -f stop_gpfdist_on_segment

# Stop gpfdist on all segment pods
function stop_gpfdist_all_segments() {
  local data_path_pattern=$1
  local pods=$(get_segment_pods)

  for pod in ${pods}; do
    stop_gpfdist_on_segment "${pod}" "${data_path_pattern}" &
  done
  wait
}
export -f stop_gpfdist_all_segments
