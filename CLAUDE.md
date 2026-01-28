# TPC-DS Toolkit - Project Context

## Overview

TPC-DS benchmarking toolkit (v2.4) for PostgreSQL-compatible MPP databases. Supports Apache Cloudberry (Incubating), Greenplum, HashData, SynxDB MPP (physical/VM), SynxDB Cloud (K8s), and PostgreSQL.

---

## SynxDB Cloud (K8s) Usage Guide

### Architecture Comparison

| Aspect | SynxDB MPP | SynxDB Cloud (K8s) |
|--------|------------|---------------------|
| Deployment | Coordinator + Segments on VMs | DBaaS + Warehouse compute pods |
| Storage | Local EBS per segment | S3 (shared/remote) |
| SSH access | Yes (to segments) | No |
| Data loading | gpfdist (parallel) | COPY command |
| Data generation | On segment nodes | On client machine |
| Toolkit mode | `local` | `cloud` (required) |

**Reference benchmark (TPC-DS 100GB):**

| Deployment | Infrastructure | Cost | Query Time |
|------------|----------------|------|------------|
| SynxDB MPP | 5× m5a.2xlarge (8 vCPU/32GB), 1TB EBS each | ~$1,700/mo | 1619s |
| SynxDB Cloud | 4× t4g.medium + 9× m6i.xlarge, S3 storage | ~$1,600/mo | 1717s |

**Must use `cloud` mode** because SynxDB Cloud uses compute-storage separation:
- No SSH access to compute pods
- No local segment data directories (data lives in S3)
- gpfdist requires segment host access which doesn't exist in K8s

---

### Configuration for SynxDB Cloud K8s

Edit `tpcds_variables.sh`:

```bash
# =============================================================================
# SynxDB Cloud K8s Configuration
# =============================================================================

# CRITICAL: Must be "cloud" for K8s
export RUN_MODEL="cloud"
export ADMIN_USER="$(whoami)"
export BENCH_ROLE="dsbench"

# Connection - Use K8s service endpoint
export PSQL_OPTIONS="-h <synxdb-coordinator-service> -p 5432 -U dsbench -d synxdb"

# Scale factor (GB of data)
export GEN_DATA_SCALE="100"

# Data generation - Local paths on client machine
# Multiple paths distribute I/O across disks for faster generation
# Total parallelism = number_of_paths × GEN_DATA_PARALLEL
export CUSTOM_GEN_PATH="/data/tpcds"           # Single disk example
# export CUSTOM_GEN_PATH="/ssd1/tpcds /ssd2/tpcds"  # Multi-disk example
export GEN_DATA_PARALLEL="4"

# Schema
export DB_SCHEMA_NAME="tpcds"

# =============================================================================
# Storage Options - Optimized for SynxDB Cloud (K8s)
# =============================================================================

# PAX format recommended (columnar with vectorization)
export TABLE_ACCESS_METHOD="USING PAX"
export TABLE_STORAGE_OPTIONS="compresstype=zstd, compresslevel=5"

# RANDOM distribution recommended (no segment affinity)
export RANDOM_DISTRIBUTION="true"

# Partitioning for large fact tables
export TABLE_USE_PARTITION="true"

# =============================================================================
# Memory Settings - Adjust based on cluster size
# =============================================================================
export STATEMENT_MEM="2GB"
export STATEMENT_MEM_MULTI_USER="1GB"

# Vectorization (SynxDB Cloud supports this)
export ENABLE_VECTORIZATION="on"

# =============================================================================
# Step Control
# =============================================================================
export RUN_COMPILE_TPCDS="true"
export RUN_GEN_DATA="true"
export GEN_NEW_DATA="true"
export RUN_INIT="true"
export RUN_DDL="true"
export DROP_EXISTING_TABLES="true"
export RUN_LOAD="true"
export TRUNCATE_TABLES="true"
export LOAD_PARALLEL="4"
export RUN_ANALYZE="true"
export RUN_ANALYZE_PARALLEL="5"
export RUN_SQL="true"
export RUN_SINGLE_USER_REPORTS="true"
export RUN_MULTI_USER="false"
export RUN_MULTI_USER_REPORTS="false"
export RUN_SCORE="false"

# =============================================================================
# Misc
# =============================================================================
export ON_ERROR_STOP="0"
export UNIFY_QGEN_SEED="true"
export SINGLE_USER_ITERATIONS="1"
export EXPLAIN_ANALYZE="false"
export LOG_DEBUG="false"
```

---

### Data Flow in Cloud Mode

```
CLIENT MACHINE (where you run the toolkit)
  dsdgen ──▶ /data/tpcds/dsgendata_tpcds/*/*.dat
                         │
                         │ \COPY command (psql)
                         ▼
SYNXDB CLOUD (K8s)
  DBaaS Layer (t4g.medium pods)
       │
       ▼
  Warehouse Compute (m6i.xlarge pods) ──▶ S3 Storage
```

---

### Prerequisites

```bash
# Install compilation dependencies
sudo yum install -y gcc make byacc flex unzip  # RHEL/CentOS

# Configure passwordless DB access
cat >> ~/.pgpass << EOF
<synxdb-host>:5432:*:dsbench:<password>
EOF
chmod 600 ~/.pgpass

# Verify connection
psql -h <synxdb-host> -p 5432 -U dsbench -d synxdb -c "SELECT version();"

# Prepare data directories (need ~1.2x scale factor in GB)
# Single disk:
sudo mkdir -p /data/tpcds && sudo chown $(whoami):$(whoami) /data/tpcds
# Multi-disk (optional, for faster generation):
# sudo mkdir -p /ssd1/tpcds /ssd2/tpcds
# sudo chown $(whoami):$(whoami) /ssd1/tpcds /ssd2/tpcds
```

---

### Execution

```bash
cd TPC-DS-Toolkit
./run.sh
# Logs: tpcds_YYYYMMDD_HHMMSS.log
```

---

### Monitoring

```bash
# Watch main log
tail -f tpcds_*.log

# Check data generation progress
ls -la /data/tpcds/dsgendata_tpcds/*/

# Check loading progress
psql $PSQL_OPTIONS -c "SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname='tpcds';"

# Check query progress
psql $PSQL_OPTIONS -c "SELECT * FROM tpcds_reports.sql ORDER BY id DESC LIMIT 10;"
```

---

### Re-running Queries Only

Skip data generation/loading for subsequent runs:

```bash
export RUN_COMPILE_TPCDS="false"
export RUN_GEN_DATA="false"
export GEN_NEW_DATA="false"
export RUN_INIT="false"
export RUN_DDL="false"
export RUN_LOAD="false"
export RUN_ANALYZE="false"
export RUN_SQL="true"
export RUN_SINGLE_USER_REPORTS="true"
```

---

### Key Differences: SynxDB MPP vs SynxDB Cloud

| Step | SynxDB MPP (local mode) | SynxDB Cloud (cloud mode) |
|------|-------------------------|---------------------------|
| 01_gen_data | SSH to segments, dsdgen there | dsdgen locally on client |
| 02_init | gpconfig to set GUCs | Skipped (no gpconfig) |
| 04_load | gpfdist → external tables | `\COPY` from local files |
| Memory tuning | gpconfig | Session-level SET only |

---

### Performance Considerations

1. **Data Generation**: Runs on client machine, not database cluster
   - Use multiple `CUSTOM_GEN_PATH` directories on separate disks to parallelize I/O
   - Total workers = `number_of_paths × GEN_DATA_PARALLEL`

2. **Data Loading Bottleneck**: COPY is single-threaded per table
   - Increase `LOAD_PARALLEL` for more parallel COPY operations

3. **Statement Memory**: Set per-session (no gpconfig access)
   - Verify: `SHOW max_statement_mem;`

4. **Storage Format**: PAX optimal for compute-storage separation
   - Columnar format for analytics workloads
   - Vectorized execution support
   - Efficient on S3-backed shared storage

---

### Future Optimization: S3-based Parallel Loading

**Current limitation**: Cloud mode uses `\COPY` which is single-threaded per table.

**Potential optimization**: Use `datalake_fdw` to load from S3, enabling parallel reads across warehouse nodes.

```
Current (COPY):     Client ──▶ Coordinator ──▶ Storage     (single stream)
S3-based (FDW):     Client ──▶ S3 ◀── All Warehouse Nodes  (parallel)
```

**Open question - FDW parallel execution and data duplication**:

When using `datalake_fdw` with `mpp_execute 'all segments'`, each segment reads from S3. Coordination mechanism to prevent duplicate loading is unclear:

| Scenario | Behavior | Result |
|----------|----------|--------|
| Coordinated | Each segment reads distinct files/rows | Correct |
| Uncoordinated | Each segment reads ALL files | N× duplication |

**Verification before implementation**:

```sql
-- Create test foreign table pointing to S3 directory
CREATE FOREIGN TABLE test_s3 (id int, val text)
  SERVER s3_server
  OPTIONS (filePath '/bucket/test/', format 'text');

-- Check if row count matches expected (not N× expected)
SELECT COUNT(*) FROM test_s3;
```

**Safe implementation options**:

1. **Coordinator-only FDW**: No duplication, but no parallelism
2. **Iceberg format**: Built-in parallel coordination via manifests
3. **Segment-specific paths**: Generate files per segment count

---

### Troubleshooting

| Issue | Cause | Mitigation |
|-------|-------|------------|
| Slow data loading | Single COPY stream | Increase `LOAD_PARALLEL`, use SSDs |
| Connection timeout | Large COPY operations | Adjust `statement_timeout` |
| Out of disk space | Data generation | Need ~1.2x scale factor in GB |
| Memory errors | STATEMENT_MEM too high | Check `max_statement_mem` |
| SynxDB not detected | Version string mismatch | Verify `SELECT version()` contains "synxdb" |

---

## Repository Structure

```
TPC-DS-Toolkit/
├── 00_compile_tpcds/      # Compile TPC-DS tools (dsdgen, dsqgen)
├── 01_gen_data/           # Generate benchmark data
├── 02_init/               # Initialize cluster settings
├── 03_ddl/                # Schema definitions (24 tables)
├── 04_load/               # Data loading scripts
├── 05_analyze/            # Statistics computation
├── 06_sql/                # Query generation and execution
├── 07_single_user_reports/# Power test reporting
├── 08_multi_user/         # Throughput test
├── 09_multi_user_reports/ # Throughput reporting
├── 10_score/              # TPC-DS score calculation
├── tpcds_tools/           # Utilities and documentation
├── tpcds_variables.sh     # Main configuration
├── functions.sh           # Shared utilities
├── tpcds.sh               # Main coordinator
├── rollout.sh             # Step orchestrator
└── run.sh                 # Background launcher
```

---

## Supported Databases

Detected via `functions.sh:148-187`:

- Greenplum 4.3, 5, 6, 7
- Apache Cloudberry (Incubating)
- HashData Lightning / Enterprise 4
- SynxDB MPP (physical/VM) → uses `local` mode
- SynxDB Cloud (K8s) → uses `cloud` mode
- PostgreSQL

---

## Known Issues

- Cloud mode: No gpconfig access, GUCs must be set at session level
- Data maintenance tests (TDM) not implemented; v3.2.0 scores are simulated
