#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Build Spark image from source and load into kind cluster
# Includes: Iceberg runtime + hadoop-aws (S3A) jars
# Usage: ./scripts/build-spark-image.sh [--skip-build] [--skip-load]
# ---------------------------------------------------------------------------

SPARK_HOME="${SPARK_HOME:-$HOME/Workspace/spark}"
IMAGE_NAME="${SPARK_IMAGE:-localhost/spark-dev}"
IMAGE_TAG="${SPARK_TAG:-latest}"
KIND_CLUSTER="${KIND_CLUSTER:-kind-cluster}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

SCALA_VERSION="2.13"

SKIP_BUILD=false
SKIP_LOAD=false

for arg in "$@"; do
  case $arg in
    --skip-build) SKIP_BUILD=true ;;
    --skip-load)  SKIP_LOAD=true ;;
    *)            echo "Unknown arg: $arg"; exit 1 ;;
  esac
done

echo "==> Spark home:       ${SPARK_HOME}"
echo "==> Image:            ${FULL_IMAGE}"
echo "==> Cluster:          ${KIND_CLUSTER}"
echo "==> Iceberg version:  ${ICEBERG_VERSION}"

# --- Step 1: Build Spark distribution ----------------------------------------
if [ "$SKIP_BUILD" = false ]; then
  echo ""
  echo "==> Building Spark distribution (this takes a while)..."
  cd "${SPARK_HOME}"
  export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  echo "==> Using JAVA_HOME: ${JAVA_HOME}"
  ./build/mvn -T 2 -DskipTests \
    -Pkubernetes \
    -Phadoop-cloud \
    package
else
  echo "==> Skipping Spark build (--skip-build)"
fi

# --- Step 2: Check Iceberg jars (must be built via make dev-build-iceberg) ----
echo ""
SPARK_JARS_DIR="${SPARK_HOME}/assembly/target/scala-${SCALA_VERSION}/jars"
if [ ! -d "${SPARK_JARS_DIR}" ]; then
  echo "ERROR: Spark jars not found at ${SPARK_JARS_DIR}"
  echo "       Run without --skip-build first."
  exit 1
fi

ICEBERG_JAR_COUNT=$(find "${SPARK_JARS_DIR}" -name "iceberg-spark-runtime-*.jar" | wc -l | tr -d ' ')
if [ "${ICEBERG_JAR_COUNT}" -eq 0 ]; then
  echo "ERROR: Iceberg runtime jar not found in ${SPARK_JARS_DIR}"
  echo "       Run: make dev-build-iceberg"
  exit 1
fi
echo "==> Iceberg jars found (${ICEBERG_JAR_COUNT}):"
find "${SPARK_JARS_DIR}" -name "iceberg-*.jar" -exec basename {} \;

# --- Step 3: Build container image with podman --------------------------------
echo ""
echo "==> Building container image with podman..."

cd "${SPARK_HOME}"

export BUILDKIT=0
bin/docker-image-tool.sh \
  -r "${IMAGE_NAME%/*}" \
  -t "${IMAGE_TAG}" \
  -b podman \
  -p kubernetes/dockerfiles/spark/Dockerfile \
  build

# The image tool names images as: <repo>/spark:<tag>
BUILT_IMAGE="spark:${IMAGE_TAG}"
if [ "${FULL_IMAGE}" != "${BUILT_IMAGE}" ]; then
  podman tag "${BUILT_IMAGE}" "${FULL_IMAGE}" 2>/dev/null || true
fi

echo ""
echo "==> Image built: ${FULL_IMAGE}"
podman images --filter "reference=${FULL_IMAGE}" --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}"

# --- Step 5: Load into kind cluster ------------------------------------------
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
echo "==> Bundled extra jars:"
ls -1 "${EXTRA_JARS_DIR}"
