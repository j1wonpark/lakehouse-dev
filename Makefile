# ===========================================================================
# Spark Connect + Iceberg + Polaris on kind (podman)
# ===========================================================================

REPO_ROOT := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

-include $(REPO_ROOT).env.local
include $(REPO_ROOT).env.default

export SPARK_HOME ICEBERG_HOME DEV_JARS_DIR SPARK_IMAGE SPARK_TAG KIND_CLUSTER
export KIND_EXPERIMENTAL_PROVIDER=podman
export JAVA_HOME := $(shell /usr/libexec/java_home -v 17)

# ---------------------------------------------------------------------------
# Top-level targets
# ---------------------------------------------------------------------------

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

.PHONY: all
all: cluster infra spark-image spark-connect init-catalog ## Setup everything end-to-end

.PHONY: infra
infra: deploy-minio deploy-polaris deploy-spark-operator deploy-ingress ## Deploy all infrastructure (MinIO + Polaris + Spark Operator + Ingress)

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

.PHONY: cluster
cluster: ## Create kind cluster (skip if exists)
	@envsubst < kind-config.yaml.tmpl > kind-config.yaml
	@if ! kind get clusters 2>&1 | grep -q "$(KIND_CLUSTER)"; then \
		echo "==> Creating kind cluster '$(KIND_CLUSTER)'..."; \
		kind create cluster --name $(KIND_CLUSTER) --config kind-config.yaml; \
	else \
		echo "==> Cluster '$(KIND_CLUSTER)' already exists."; \
	fi

.PHONY: cluster-delete
cluster-delete: ## Delete kind cluster
	kind delete cluster --name $(KIND_CLUSTER)

# ---------------------------------------------------------------------------
# Dev build (incremental)
# ---------------------------------------------------------------------------

.PHONY: dev-build
dev-build: ## Build Spark module and hot-reload (MODULE=connect/server)
	MODULE=$(MODULE) ./scripts/dev-build.sh

.PHONY: dev-build-iceberg
dev-build-iceberg: ## Build Iceberg Spark runtime jar and copy to dev-jars
	./scripts/build-iceberg.sh

# ---------------------------------------------------------------------------
# Spark image build (legacy full build)
# ---------------------------------------------------------------------------

.PHONY: spark-image
spark-image: ## Build Spark image from source and load into kind
	./scripts/build-spark-image.sh

.PHONY: spark-image-load
spark-image-load: ## Load existing Spark image into kind (skip build)
	./scripts/build-spark-image.sh --skip-build

# ---------------------------------------------------------------------------
# Ingress
# ---------------------------------------------------------------------------

.PHONY: deploy-ingress
deploy-ingress: ## Deploy ingress-nginx + MinIO/Spark-Connect ingress resources
	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
	kubectl wait --namespace ingress-nginx --for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller --timeout=120s
	kubectl patch deployment ingress-nginx-controller -n ingress-nginx \
		--type=json \
		-p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--tcp-services-configmap=ingress-nginx/tcp-services"}]'
	kubectl patch service ingress-nginx-controller -n ingress-nginx \
		--type=json \
		-p='[{"op":"add","path":"/spec/ports/-","value":{"name":"spark-connect","port":15002,"targetPort":15002,"protocol":"TCP"}}]'
	kubectl wait --namespace ingress-nginx --for=condition=ready pod \
		--selector=app.kubernetes.io/component=controller --timeout=120s
	kubectl apply -f manifests/ingress-minio.yaml
	kubectl apply -f manifests/ingress-spark-connect-tcp.yaml
	kubectl apply -f manifests/ingress-spark-ui.yaml 2>/dev/null || true

.PHONY: undeploy-ingress
undeploy-ingress: ## Remove ingress-nginx
	kubectl delete -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml || true

# ---------------------------------------------------------------------------
# Helm repos
# ---------------------------------------------------------------------------

.PHONY: helm-repos
helm-repos: ## Add/update required Helm repositories
	helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
	helm repo add minio https://charts.min.io 2>/dev/null || true
	helm repo add polaris https://downloads.apache.org/incubator/polaris/helm-chart 2>/dev/null || true
	helm repo add spark https://apache.github.io/spark-kubernetes-operator 2>/dev/null || true
	helm repo update

# ---------------------------------------------------------------------------
# MinIO
# ---------------------------------------------------------------------------

.PHONY: deploy-minio
deploy-minio: helm-repos ## Deploy MinIO
	kubectl create namespace $(MINIO_NAMESPACE) 2>/dev/null || true
	helm upgrade --install minio minio/minio \
		--namespace $(MINIO_NAMESPACE) \
		-f helm/minio-values.yaml \
		--wait --timeout 120s

.PHONY: undeploy-minio
undeploy-minio: ## Remove MinIO
	helm uninstall minio --namespace $(MINIO_NAMESPACE) || true
	kubectl delete namespace $(MINIO_NAMESPACE) || true

# ---------------------------------------------------------------------------
# Polaris
# ---------------------------------------------------------------------------

.PHONY: deploy-postgresql
deploy-postgresql: helm-repos ## Deploy PostgreSQL for Polaris
	kubectl create namespace $(POLARIS_NAMESPACE) 2>/dev/null || true
	helm upgrade --install polaris-postgresql bitnami/postgresql \
		--namespace $(POLARIS_NAMESPACE) \
		-f helm/postgresql-values.yaml \
		--wait --timeout 120s

.PHONY: bootstrap-polaris
bootstrap-polaris: deploy-postgresql ## Bootstrap Polaris DB schema
	kubectl apply -f manifests/polaris-postgres-secret.yaml
	@echo "==> Bootstrapping Polaris DB schema..."
	kubectl run polaris-bootstrap \
		-n $(POLARIS_NAMESPACE) \
		--image=apache/polaris-admin-tool:latest \
		--restart=Never --rm -i \
		--env="quarkus.datasource.jdbc.url=jdbc:postgresql://polaris-postgresql.$(POLARIS_NAMESPACE).svc.cluster.local:5432/polaris" \
		--env="quarkus.datasource.username=polaris" \
		--env="quarkus.datasource.password=polaris" \
		-- bootstrap -r POLARIS -c POLARIS,root,s3cr3t -p || true

.PHONY: deploy-polaris
deploy-polaris: bootstrap-polaris ## Deploy Polaris
	helm upgrade --install polaris polaris/polaris \
		--namespace $(POLARIS_NAMESPACE) \
		-f helm/polaris-values.yaml \
		--devel \
		--wait --timeout 180s

.PHONY: undeploy-polaris
undeploy-polaris: ## Remove Polaris + PostgreSQL
	helm uninstall polaris --namespace $(POLARIS_NAMESPACE) || true
	helm uninstall polaris-postgresql --namespace $(POLARIS_NAMESPACE) || true
	kubectl delete namespace $(POLARIS_NAMESPACE) || true

# ---------------------------------------------------------------------------
# Spark Operator
# ---------------------------------------------------------------------------

.PHONY: deploy-spark-operator
deploy-spark-operator: helm-repos ## Deploy Spark Kubernetes Operator
	helm upgrade --install spark-operator spark/spark-kubernetes-operator \
		--namespace spark-operator --create-namespace \
		-f helm/spark-operator-values.yaml \
		--wait --timeout 120s

.PHONY: undeploy-spark-operator
undeploy-spark-operator: ## Remove Spark Operator
	helm uninstall spark-operator --namespace spark-operator || true

# ---------------------------------------------------------------------------
# Spark Connect Server
# ---------------------------------------------------------------------------

.PHONY: spark-connect
spark-connect: ## Deploy Spark Connect server (SparkApplication)
	kubectl apply -f manifests/spark-connect.yaml

.PHONY: spark-connect-delete
spark-connect-delete: ## Remove Spark Connect server
	kubectl delete -f manifests/spark-connect.yaml || true

.PHONY: spark-connect-status
spark-connect-status: ## Show Spark Connect server status
	kubectl get sparkapplication -n $(SPARK_NAMESPACE)
	@echo "---"
	kubectl get pods -n $(SPARK_NAMESPACE) -l spark-role

.PHONY: spark-connect-logs
spark-connect-logs: ## Tail Spark Connect driver logs
	kubectl logs -n $(SPARK_NAMESPACE) -l spark-role=driver -f --tail=100

# ---------------------------------------------------------------------------
# Polaris catalog init
# ---------------------------------------------------------------------------

.PHONY: init-catalog
init-catalog: ## Initialize Polaris catalog (port-forward + create catalog)
	@echo "==> Port-forwarding Polaris (API: 8181, Mgmt: 8182)..."
	@kubectl port-forward -n $(POLARIS_NAMESPACE) svc/polaris 8181:8181 &
	@kubectl port-forward -n $(POLARIS_NAMESPACE) svc/polaris-mgmt 8182:8182 &
	@sleep 2; \
	POLARIS_HOST=http://localhost:8181 POLARIS_MGMT=http://localhost:8182 ./scripts/init-polaris-catalog.sh; \
	kill %1 %2 2>/dev/null || true

# ---------------------------------------------------------------------------
# Port-forward helpers
# ---------------------------------------------------------------------------

.PHONY: port-forward-minio
port-forward-minio: ## Port-forward MinIO (API: 9000, Console: 9001)
	@echo "MinIO API:     http://localhost:9000"
	@echo "MinIO Console: http://localhost:9001  (minioadmin/minioadmin)"
	kubectl port-forward -n $(MINIO_NAMESPACE) svc/minio 9000:9000 &
	kubectl port-forward -n $(MINIO_NAMESPACE) svc/minio-console 9001:9001

.PHONY: port-forward-polaris
port-forward-polaris: ## Port-forward Polaris API (8181)
	@echo "Polaris API: http://localhost:8181"
	kubectl port-forward -n $(POLARIS_NAMESPACE) svc/polaris 8181:8181

.PHONY: port-forward-spark-connect
port-forward-spark-connect: ## Port-forward Spark Connect (15002)
	@echo "Spark Connect: sc://localhost:15002"
	kubectl port-forward -n $(SPARK_NAMESPACE) svc/spark-connect-server-svc 15002:15002

# ---------------------------------------------------------------------------
# Status / debug
# ---------------------------------------------------------------------------

.PHONY: status
status: ## Show all pod status
	@echo "=== MinIO ==="
	@kubectl get pods -n $(MINIO_NAMESPACE) 2>/dev/null || echo "  (not deployed)"
	@echo ""
	@echo "=== Polaris ==="
	@kubectl get pods -n $(POLARIS_NAMESPACE) 2>/dev/null || echo "  (not deployed)"
	@echo ""
	@echo "=== Spark Operator ==="
	@kubectl get pods -n spark-operator 2>/dev/null || echo "  (not deployed)"
	@echo ""
	@echo "=== Spark ==="
	@kubectl get pods -n $(SPARK_NAMESPACE) 2>/dev/null || echo "  (not deployed)"
	@kubectl get sparkapplication -n $(SPARK_NAMESPACE) 2>/dev/null || true

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

.PHONY: clean
clean: spark-connect-delete undeploy-spark-operator undeploy-polaris undeploy-minio ## Remove all deployments (keep cluster)

.PHONY: clean-all
clean-all: clean cluster-delete ## Remove everything including cluster
