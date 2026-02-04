#!/bin/bash
set -e

VARS_FILE="tpcds_variables.sh"
FUNCTIONS_FILE="functions.sh"

# shellcheck source=tpcds_variables.sh
source ./${VARS_FILE}
# shellcheck source=functions.sh
source ./${FUNCTIONS_FILE}

# Handle single step execution: ./tpcds.sh step <step_name>
# This overrides variables without modifying the file
if [[ "$1" == "step" && -n "$2" ]]; then
    # Disable ALL steps first
    export RUN_COMPILE_TPCDS="false"
    export RUN_GEN_DATA="false"
    export RUN_INIT="false"
    export RUN_DDL="false"
    export RUN_LOAD="false"
    export RUN_ANALYZE="false"
    export RUN_SQL="false"
    export RUN_SINGLE_USER_REPORTS="false"
    export RUN_MULTI_USER="false"
    export RUN_MULTI_USER_REPORTS="false"
    export RUN_SCORE="false"

    # Enable ONLY the requested step
    step_name="$2"
    case $step_name in
        compile)    export RUN_COMPILE_TPCDS="true" ;;
        gen_data)   export RUN_GEN_DATA="true" ;;
        init)       export RUN_INIT="true" ;;
        ddl)        export RUN_DDL="true" ;;
        load)       export RUN_LOAD="true" ;;
        analyze)    export RUN_ANALYZE="true" ;;
        sql)        export RUN_SQL="true" ;;
        reports)    export RUN_SINGLE_USER_REPORTS="true" ;;
        multi)      export RUN_MULTI_USER="true" ;;
        multi_reports) export RUN_MULTI_USER_REPORTS="true" ;;
        score)      export RUN_SCORE="true" ;;
        *)
            echo "Unknown step: $step_name"
            echo "Valid steps: compile, gen_data, init, ddl, load, analyze, sql, reports, multi, multi_reports, score"
            exit 1
            ;;
    esac
    echo "Running single step: $step_name"
fi

# Auto-detect architecture and setup TPC-DS tools
TOOLS_DIR="$(dirname "${BASH_SOURCE[0]}")/00_compile_tpcds/tools"
if [[ -d "$TOOLS_DIR" ]]; then
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  SUFFIX="x86" ;;
        aarch64) SUFFIX="arm" ;;
        arm64)   SUFFIX="arm" ;;
        *)       SUFFIX="x86" ;;  # Default to x86
    esac

    # Setup dsdgen if not already done
    if [[ ! -x "$TOOLS_DIR/dsdgen" && -f "$TOOLS_DIR/dsdgen.${SUFFIX}" ]]; then
        cp "$TOOLS_DIR/dsdgen.${SUFFIX}" "$TOOLS_DIR/dsdgen"
        chmod +x "$TOOLS_DIR/dsdgen"
        echo "Setup: dsdgen (${ARCH})"
    fi

    # Setup dsqgen if not already done
    if [[ ! -x "$TOOLS_DIR/dsqgen" && -f "$TOOLS_DIR/dsqgen.${SUFFIX}" ]]; then
        cp "$TOOLS_DIR/dsqgen.${SUFFIX}" "$TOOLS_DIR/dsqgen"
        chmod +x "$TOOLS_DIR/dsqgen"
        echo "Setup: dsqgen (${ARCH})"
    fi
fi

TPC_DS_DIR=$(get_pwd ${BASH_SOURCE[0]})
export TPC_DS_DIR

log_time "TPC-DS test started"
log_time "TPC-DS toolkit version is: V2.4_dev20251204"

# Check that pertinent variables are set in the variable file.
check_variables
# Make sure this is being run as gpadmin
check_admin_user
# Output admin user and multi-user count to standard out
print_header
# Output the version of the database
get_version
export DB_VERSION=${VERSION}
export DB_VERSION_FULL=${VERSION_FULL}
log_time "Current database is: ${DB_VERSION}"
log_time "Current database version is:\n${DB_VERSION_FULL}"

if [ "${DB_CURRENT_USER}" != "${BENCH_ROLE}" ]; then
  if [ "${BENCH_ROLE}" == "gpadmin" ]; then
    log_time "Cannot use gpadmin as bench role if not connected as gpadmin."
    exit 1
  fi
fi

if [ "${DB_VERSION}" == "postgresql" ]; then
  export RUN_MODEL="cloud"
fi

if [ "${DB_VERSION}" == "hashdata_enterprise_4" ]; then
  export RUN_MODEL="cloud"
fi

log_time "Running TPC-DS in ${RUN_MODEL} mode for ${DB_VERSION}."

if [ "${RUN_MODEL}" != "cloud" ]; then
  source_bashrc
fi

if [ "${RUN_MODEL}" != "local" ]; then
  export CUSTOM_GEN_PATH="$(echo "${CUSTOM_GEN_PATH}" | tr '[:upper:]' '[:lower:]')"

  IFS=' ' read -ra GEN_PATHS <<< "${CUSTOM_GEN_PATH}"
  
  TOTAL_PATHS=${#GEN_PATHS[@]}
  if [ ${TOTAL_PATHS} -eq 0 ]; then
    log_time "ERROR: CUSTOM_GEN_PATH is empty or not set"
    exit 1
  fi
  # Check for duplicate directories in CUSTOM_GEN_PATH and remove them
  if [ "${LOG_DEBUG}" == "true" ]; then
    log_time "Checking for duplicate directories in CUSTOM_GEN_PATH..."
  fi
  # Using string method instead of associative array for better compatibility
  declare -a UNIQUE_GEN_PATHS
  duplicates_found=false
  
  for path in "${GEN_PATHS[@]}"; do
    # Check if path is already in the unique paths array (compatible with all Bash versions)
    is_duplicate=false
    for unique_path in "${UNIQUE_GEN_PATHS[@]}"; do
      if [ "$unique_path" = "$path" ]; then
        is_duplicate=true
        break
      fi
    done
    
    if [ "$is_duplicate" = false ]; then
      # Add path to unique paths array
      UNIQUE_GEN_PATHS+=("$path")
    else
      duplicates_found=true
      if [ "${LOG_DEBUG}" == "true" ]; then
        log_time "Warning: Duplicate directory found and will be removed: $path"
      fi
    fi
  done
  
  if [ "$duplicates_found" = true ]; then
    if [ "${LOG_DEBUG}" == "true" ]; then
      log_time "Duplicate directories removed. Using unique paths only."
    fi
  fi
  GEN_PATHS=("${UNIQUE_GEN_PATHS[@]}")
  
  # Reconstruct the path string and export
  CUSTOM_GEN_PATH=$(IFS=' '; echo "${GEN_PATHS[*]}")
  export CUSTOM_GEN_PATH
  if [ "${LOG_DEBUG}" == "true" ]; then
    log_time "CUSTOM_GEN_PATH set to: ${CUSTOM_GEN_PATH}"
  fi
else
  create_hosts_file
fi

# Get a random port for gpfdist
get_gpfdist_port
if [ "${LOG_DEBUG}" == "true" ]; then
  log_time "gpfdist port set to: ${GPFDIST_PORT}"
fi
echo ""

# run the benchmark
./rollout.sh
