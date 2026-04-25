#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Initialize Polaris catalog with MinIO storage backend
# Waits for Polaris to be ready, obtains OAuth token, creates catalog + namespace
# ---------------------------------------------------------------------------

POLARIS_HOST="${POLARIS_HOST:-http://localhost:8181}"
POLARIS_MGMT="${POLARIS_MGMT:-http://localhost:8182}"
REALM="POLARIS"
CLIENT_ID="${POLARIS_CLIENT_ID:-root}"
CLIENT_SECRET="${POLARIS_CLIENT_SECRET:-s3cr3t}"

MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio.minio.svc.cluster.local:9000}"
MINIO_BUCKET="${MINIO_BUCKET:-warehouse}"
CATALOG_NAME="${CATALOG_NAME:-spark_catalog}"

echo "==> Polaris: ${POLARIS_HOST}"
echo "==> Catalog: ${CATALOG_NAME}"
echo "==> MinIO:   ${MINIO_ENDPOINT}"

# --- Wait for Polaris to be ready -------------------------------------------
echo "==> Waiting for Polaris to be ready..."
for i in $(seq 1 60); do
  if curl -sf "${POLARIS_MGMT}/q/health/ready" > /dev/null 2>&1; then
    echo "==> Polaris is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "ERROR: Polaris did not become ready within 60s"
    exit 1
  fi
  sleep 1
done

# --- Get OAuth token ---------------------------------------------------------
echo "==> Obtaining OAuth token..."
TOKEN=$(curl -sf -X POST "${POLARIS_HOST}/api/catalog/v1/oauth/tokens" \
  --user "${CLIENT_ID}:${CLIENT_SECRET}" \
  -d "grant_type=client_credentials" \
  -d "scope=PRINCIPAL_ROLE:ALL" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

if [ -z "${TOKEN}" ]; then
  echo "ERROR: Failed to obtain OAuth token"
  exit 1
fi
echo "==> Token obtained."

# --- Create catalog ----------------------------------------------------------
echo "==> Creating catalog '${CATALOG_NAME}'..."
HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${POLARIS_HOST}/api/management/v1/catalogs" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"catalog\": {
      \"name\": \"${CATALOG_NAME}\",
      \"type\": \"INTERNAL\",
      \"readOnly\": false,
      \"properties\": {
        \"default-base-location\": \"s3://${MINIO_BUCKET}\"
      },
      \"storageConfigInfo\": {
        \"storageType\": \"S3\",
        \"allowedLocations\": [\"s3://${MINIO_BUCKET}\"],
        \"s3.endpoint\": \"${MINIO_ENDPOINT}\",
        \"s3.path-style-access\": \"true\",
        \"s3.region\": \"us-east-1\"
      }
    }
  }" 2>/dev/null || echo "000")

case "${HTTP_CODE}" in
  201|200) echo "==> Catalog '${CATALOG_NAME}' created." ;;
  409)     echo "==> Catalog '${CATALOG_NAME}' already exists." ;;
  000)     echo "==> Catalog creation request sent (could not parse response code)." ;;
  *)       echo "WARNING: Unexpected response code: ${HTTP_CODE}"; ;;
esac

# --- Create catalog role + grant ---------------------------------------------
echo "==> Granting catalog admin role..."
# Create a catalog role
curl -sf -X POST "${POLARIS_HOST}/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"catalogRole": {"name": "admin"}}' > /dev/null 2>&1 || true

# Grant all privileges
for PRIV in CATALOG_MANAGE_CONTENT TABLE_CREATE TABLE_DROP TABLE_READ_DATA TABLE_WRITE_DATA TABLE_LIST NAMESPACE_CREATE NAMESPACE_LIST; do
  curl -sf -X PUT "${POLARIS_HOST}/api/management/v1/catalogs/${CATALOG_NAME}/catalog-roles/admin/grants" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"grant\": {\"type\": \"catalog\", \"privilege\": \"${PRIV}\"}}" > /dev/null 2>&1 || true
done

# Assign catalog role to service_admin principal role
curl -sf -X PUT "${POLARIS_HOST}/api/management/v1/principal-roles/service_admin/catalog-roles/${CATALOG_NAME}" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"catalogRole": {"name": "admin"}}' > /dev/null 2>&1 || true

echo "==> Catalog admin role granted."

# --- Create default namespace ------------------------------------------------
echo "==> Creating default namespace 'default'..."
curl -sf -X POST "${POLARIS_HOST}/api/catalog/v1/${CATALOG_NAME}/namespaces" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"namespace": ["default"]}' > /dev/null 2>&1 || true

echo "==> Namespace 'default' created."
echo ""
echo "==> Polaris catalog initialization complete!"
