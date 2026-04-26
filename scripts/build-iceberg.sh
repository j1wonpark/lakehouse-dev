#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Build Iceberg Spark runtime jar from source and copy to dev-jars.
#
# Usage:
#   ./scripts/build-iceberg.sh [--iceberg-home <path>]
# ---------------------------------------------------------------------------

ICEBERG_HOME="${ICEBERG_HOME:-$HOME/Workspace/iceberg}"
SPARK_HOME="${SPARK_HOME:-$HOME/Workspace/data-platform/spark}"
SPARK_JARS_DIR="${SPARK_HOME}/dist/jars"
SPARK_COMPAT="${SPARK_COMPAT:-4.1}"
SCALA_VERSION="${SCALA_VERSION:-2.13}"

for arg in "$@"; do
  case $arg in
    --iceberg-home=*) ICEBERG_HOME="${arg#*=}" ;;
  esac
done

echo "==> Iceberg home:  ${ICEBERG_HOME}"
echo "==> Spark compat:  ${SPARK_COMPAT}"
echo "==> Spark jars:    ${SPARK_JARS_DIR}"

if [ ! -d "${ICEBERG_HOME}" ]; then
  echo "ERROR: Iceberg home not found at ${ICEBERG_HOME}"
  echo "       Clone with: git clone https://github.com/apache/iceberg ${ICEBERG_HOME}"
  exit 1
fi

echo ""
echo "==> Building Iceberg Spark ${SPARK_COMPAT} runtime + aws-bundle..."
cd "${ICEBERG_HOME}"
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"

./gradlew \
  :iceberg-spark:iceberg-spark-runtime-${SPARK_COMPAT}_${SCALA_VERSION}:build \
  :iceberg-aws-bundle:build \
  -x test -PscalaVersion=${SCALA_VERSION}

# --- Copy jars into Spark assembly dir ---------------------------------------
echo ""
echo "==> Copying Iceberg jars to ${SPARK_JARS_DIR}..."

if [ ! -d "${SPARK_JARS_DIR}" ]; then
  echo "ERROR: ${SPARK_JARS_DIR} not found. Run full Spark build first: make spark-image"
  exit 1
fi

RUNTIME_JAR=$(find "${ICEBERG_HOME}/spark/v${SPARK_COMPAT}/spark-runtime/build/libs" \
  -name "iceberg-spark-runtime-${SPARK_COMPAT}_${SCALA_VERSION}-*.jar" \
  ! -name "*-sources.jar" ! -name "*-javadoc.jar" | head -1)

AWS_BUNDLE_JAR=$(find "${ICEBERG_HOME}/aws-bundle/build/libs" \
  -name "iceberg-aws-bundle-*.jar" \
  ! -name "*-sources.jar" ! -name "*-javadoc.jar" | head -1)

[ -z "${RUNTIME_JAR}" ]    && echo "ERROR: iceberg-spark-runtime jar not found" && exit 1
[ -z "${AWS_BUNDLE_JAR}" ] && echo "ERROR: iceberg-aws-bundle jar not found" && exit 1

cp -v "${RUNTIME_JAR}" "${SPARK_JARS_DIR}/"
cp -v "${AWS_BUNDLE_JAR}" "${SPARK_JARS_DIR}/"

echo "==> Done."
