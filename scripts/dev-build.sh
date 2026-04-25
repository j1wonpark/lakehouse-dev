#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Incremental dev build: compile a single Spark module and hot-reload into
# the running Spark Connect pod.
#
# Usage:
#   ./scripts/dev-build.sh [--module <maven-module>] [--no-restart]
#
# Examples:
#   ./scripts/dev-build.sh                            # default: connect/server
#   ./scripts/dev-build.sh --module sql/core
#   ./scripts/dev-build.sh --module connect/server,connect/common
#   ./scripts/dev-build.sh --no-restart               # build only, skip pod restart
# ---------------------------------------------------------------------------

SPARK_HOME="${SPARK_HOME:-$HOME/Workspace/spark}"
SPARK_JARS_DIR="${SPARK_HOME}/assembly/target/scala-2.13/jars"
SPARK_NAMESPACE="${SPARK_NAMESPACE:-spark}"
MODULE="${MODULE:-sql/connect/server}"
RESTART=true

for arg in "$@"; do
  case $arg in
    --module) shift; MODULE="$1" ;;
    --module=*) MODULE="${arg#*=}" ;;
    --no-restart) RESTART=false ;;
  esac
done

echo "==> Module:    ${MODULE}"
echo "==> Spark jars: ${SPARK_JARS_DIR}"

# --- Build -------------------------------------------------------------------
echo ""
echo "==> Building ${MODULE}..."
cd "${SPARK_HOME}"
export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
./build/mvn package -pl "${MODULE}" -DskipTests -am -T 2

# --- Copy changed jars into assembly dir -------------------------------------
echo ""
echo "==> Copying jars to ${SPARK_JARS_DIR}..."

if [ ! -d "${SPARK_JARS_DIR}" ]; then
  echo "ERROR: ${SPARK_JARS_DIR} not found. Run full build first: make spark-image"
  exit 1
fi

IFS=',' read -ra MODULES <<< "${MODULE}"
for MOD in "${MODULES[@]}"; do
  MOD_DIR="${SPARK_HOME}/${MOD}/target"
  if [ -d "${MOD_DIR}" ]; then
    find "${MOD_DIR}" -maxdepth 1 -name "*.jar" \
      ! -name "*-tests.jar" \
      ! -name "*-sources.jar" \
      ! -name "*-javadoc.jar" \
      ! -name "original-*.jar" \
      -exec cp -v {} "${SPARK_JARS_DIR}/" \;
  fi
done

# --- Restart pod -------------------------------------------------------------
if [ "${RESTART}" = true ]; then
  echo ""
  echo "==> Restarting Spark Connect pod..."
  kubectl delete pod -n "${SPARK_NAMESPACE}" \
    -l spark-role=driver --ignore-not-found
  echo "==> Pod restarted. Watch with: make spark-connect-status"
fi
