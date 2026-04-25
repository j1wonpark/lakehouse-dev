# lakehouse-dev

Local Kubernetes development environment for Spark on Kubernetes + Apache Iceberg.

## Overview

```
Spark Connect client (Python/Scala)
    ↓ gRPC (sc://localhost:15002)
Spark Connect Server (SparkApplication on Kind)
    ↓
Polaris REST Catalog  ←→  PostgreSQL (metadata)
    ↓
Iceberg Tables
    ↓
MinIO (S3-compatible storage)
```

## Directory Structure

```
lakehouse-dev/
├── Makefile                          # All automation entrypoints
├── kind-config.yaml.tmpl             # Kind cluster config template (envsubst → kind-config.yaml)
├── .env.default                      # Default path variables (committed)
├── .env.local                        # Machine-local overrides (gitignored)
├── helm/
│   ├── minio-values.yaml             # MinIO Helm values (includes Ingress)
│   ├── polaris-values.yaml           # Polaris Helm values (includes Ingress)
│   ├── postgresql-values.yaml        # PostgreSQL Helm values (for Polaris)
│   └── spark-operator-values.yaml    # Spark Kubernetes Operator Helm values
├── manifests/
│   ├── spark-connect.yaml            # SparkApplication CR (Spark Connect Server)
│   ├── ingress-spark-connect-tcp.yaml# TCP ConfigMap for Spark Connect gRPC (port 15002)
│   └── ingress-spark-ui.yaml         # Spark UI Ingress (http://spark.localhost)
└── scripts/
    ├── build-iceberg.sh              # Build Iceberg from source
    ├── build-spark-image.sh          # Build Spark image and load into Kind
    ├── dev-build.sh                  # Incremental Spark module build + hot-reload
    └── init-polaris-catalog.sh       # Initialize Polaris catalog via REST API
```

## Kind Cluster

Single control-plane node with:

| Port mapping | Purpose |
|---|---|
| 80 / 443 | ingress-nginx HTTP/HTTPS |
| 15002 | Spark Connect gRPC (TCP passthrough) |

Host path mount:
- `$SPARK_HOME/assembly/target/scala-2.13/jars` → `/opt/spark/jars` (container)

`kind-config.yaml` is gitignored and generated at `make cluster` time via `envsubst < kind-config.yaml.tmpl`.

## Components

| Component | Deploy method | Namespace |
|---|---|---|
| ingress-nginx | kubectl apply | ingress-nginx |
| MinIO | Helm (minio/minio) | minio |
| PostgreSQL | Helm (bitnami/postgresql) | polaris |
| Apache Polaris | Helm (apache/polaris) | polaris |
| Spark Kubernetes Operator | Helm (apache/spark-kubernetes-operator) | spark-operator |
| Spark Connect Server | kubectl apply (SparkApplication CR) | spark |

PostgreSQL exists solely as Polaris metadata storage.

Spark Connect gRPC uses ingress-nginx TCP passthrough (ConfigMap-based), not an Ingress resource.

## Access URLs

| Service | URL |
|---|---|
| MinIO Console | http://minio.localhost |
| MinIO API | http://minio-api.localhost |
| Polaris API | http://polaris.localhost |
| Polaris Mgmt | http://polaris-mgmt.localhost |
| Spark UI | http://spark.localhost |
| Spark Connect | sc://localhost:15002 |

## Versions

| Component | Version |
|---|---|
| Spark | branch-4.1 (4.1.2-SNAPSHOT) |
| Iceberg | apache-iceberg-1.10.1 |
| Scala | 2.13 |
| Java | 17 |

## Configuration

Path variables are externalized. Override by copying `.env.default` to `.env.local`:

```bash
cp .env.default .env.local
# edit .env.local
```

Key variables:

| Variable | Default | Description |
|---|---|---|
| `SPARK_HOME` | `../spark` | Spark source root |
| `ICEBERG_HOME` | `../iceberg` | Iceberg source root |
| `SPARK_IMAGE` | `localhost/spark-dev` | Container image name |
| `SPARK_TAG` | `latest` | Container image tag |
| `KIND_CLUSTER` | `kind-cluster` | Kind cluster name |

## Build Process

### Prerequisites

Iceberg must be built before Spark image. The Spark image bundles Iceberg JARs from
`$SPARK_HOME/assembly/target/scala-2.13/jars/`.

### 1. Build Iceberg from source

```bash
make dev-build-iceberg
```

- Runs Gradle build in `$ICEBERG_HOME`
- Targets: `iceberg-spark-runtime-4.1_2.13`, `iceberg-aws-bundle`
- Output: JARs copied to `$SPARK_HOME/assembly/target/scala-2.13/jars/`

### 2. Build Spark image

```bash
make spark-image
```

- Maven build with `-Pkubernetes -Phadoop-cloud` profiles
- Verifies Iceberg JARs are present (errors if missing)
- Builds container image with Podman via `docker-image-tool.sh`
- Loads image into Kind cluster: `localhost/spark-dev:latest`

### 3. Incremental dev build (hot-reload)

```bash
make dev-build MODULE=sql/connect/server   # default module
make dev-build MODULE=sql/core,sql/catalyst # multiple modules
```

- Compiles only the specified Maven module(s)
- Copies output JARs to `assembly/jars/` (which is bind-mounted into Kind)
- Deletes the driver Pod to trigger restart with updated JARs
- No image rebuild needed

## Full Setup

```bash
make all
# Equivalent to:
# make cluster → make infra → make dev-build-iceberg → make spark-image
# → make spark-connect → make init-catalog
```

## Common Commands

```bash
make status                  # Show all pod status
make spark-connect-logs      # Tail Spark Connect driver logs
make spark-connect-status    # Show SparkApplication + pods
make init-catalog            # (Re-)initialize Polaris catalog
make clean                   # Remove all deployments (keep cluster)
make clean-all               # Remove everything including cluster
make help                    # List all targets
```
