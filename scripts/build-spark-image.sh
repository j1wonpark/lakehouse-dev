#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Build Spark image from source and load into kind cluster.
#
# Build flow:
#   1. make-distribution.sh  → dist/ (official Spark distribution)
#   2. Copy Iceberg JARs     → dist/jars/
#   3. podman build          → localhost/spark-dev:latest
#   4. kind load             → Kind cluster
#
# Usage:
#   ./scripts/build-spark-image.sh [--skip-build] [--skip-load]
#
# Prerequisites:
#   - Run `make dev-build-iceberg` first to populate Iceberg JARs
# ---------------------------------------------------------------------------

SPARK_HOME="${SPARK_HOME:-$HOME/Workspace/data-platform/spark}"
ICEBERG_HOME="${ICEBERG_HOME:-$HOME/Workspace/data-platform/iceberg}"
IMAGE_NAME="${SPARK_IMAGE:-localhost/spark-dev}"
IMAGE_TAG="${SPARK_TAG:-latest}"
KIND_CLUSTER="${KIND_CLUSTER:-kind-cluster}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
SCALA_VERSION="2.13"
SPARK_JARS_DIR="${SPARK_HOME}/assembly/target/scala-${SCALA_VERSION}/jars"
DIST_DIR="${SPARK_HOME}/dist"

SKIP_BUILD=false
SKIP_LOAD=false

for arg in "$@"; do
  case $arg in
    --skip-build) SKIP_BUILD=true ;;
    --skip-load)  SKIP_LOAD=true ;;
    *)            echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

echo "==> Spark home: ${SPARK_HOME}"
echo "==> Image:      ${FULL_IMAGE}"
echo "==> Cluster:    ${KIND_CLUSTER}"

# --- Step 1: Build Spark distribution -----------------------------------------
if [ "$SKIP_BUILD" = false ]; then
  echo ""
  echo "==> Building Spark distribution via make-distribution.sh..."
  cd "${SPARK_HOME}"
  export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  export MAVEN_OPTS="-Xss128m -Xmx4g -XX:ReservedCodeCacheSize=128m"
  echo "==> JAVA_HOME: ${JAVA_HOME}"

  ./dev/make-distribution.sh \
    -Pkubernetes \
    -Phadoop-cloud \
    -pl '!connector/protobuf'
  # connector/protobuf excluded: protoc-jar-maven-plugin version incompatible
  # with protobuf-java 4.33.0 used in Spark 4.1 (test compile fails).
  # This module provides from_protobuf()/to_protobuf() SQL functions only,
  # not needed for Spark Connect + Iceberg use case.
else
  echo "==> Skipping Spark build (--skip-build)"
fi

# --- Step 2: Verify and copy Iceberg JARs into dist/ --------------------------
echo ""
echo "==> Checking Iceberg JARs in ${SPARK_JARS_DIR}..."

if [ ! -d "${SPARK_JARS_DIR}" ]; then
  echo "ERROR: ${SPARK_JARS_DIR} not found."
  echo "       Run without --skip-build first."
  exit 1
fi

ICEBERG_JARS=$(find "${SPARK_JARS_DIR}" -name "iceberg-*.jar")
if [ -z "${ICEBERG_JARS}" ]; then
  echo "ERROR: Iceberg JARs not found in ${SPARK_JARS_DIR}"
  echo "       Run: make dev-build-iceberg"
  exit 1
fi

echo "==> Copying Iceberg JARs to dist/jars/..."
echo "${ICEBERG_JARS}" | xargs -I{} cp -v {} "${DIST_DIR}/jars/"

# --- Step 3: Build container image with podman --------------------------------
echo ""
echo "==> Building container image with podman..."
cd "${SPARK_HOME}"

DOCKERFILE="${DIST_DIR}/kubernetes/dockerfiles/spark/Dockerfile"
if [ ! -f "${DOCKERFILE}" ]; then
  echo "ERROR: Dockerfile not found at ${DOCKERFILE}"
  echo "       Distribution build may have failed."
  exit 1
fi

podman build \
  -t "${FULL_IMAGE}" \
  -f "${DOCKERFILE}" \
  "${DIST_DIR}"

echo ""
echo "==> Image built: ${FULL_IMAGE}"
podman images --filter "reference=${FULL_IMAGE}" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}"

# --- Step 4: Load into kind cluster -------------------------------------------
if [ "$SKIP_LOAD" = false ]; then
  echo ""
  echo "==> Loading image into kind cluster '${KIND_CLUSTER}'..."
  KIND_EXPERIMENTAL_PROVIDER=podman kind load docker-image "${FULL_IMAGE}" --name "${KIND_CLUSTER}"
  echo "==> Image loaded successfully."
else
  echo "==> Skipping kind load (--skip-load)"
fi

echo ""
echo "==> Done! Image '${FULL_IMAGE}' is ready in cluster '${KIND_CLUSTER}'."
echo "==> Bundled Iceberg JARs:"
find "${DIST_DIR}/jars" -name "iceberg-*.jar" -exec basename {} \;
