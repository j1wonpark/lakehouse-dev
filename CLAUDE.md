# lakehouse-dev

Kind(로컬 Kubernetes) 위에서 Spark on Kubernetes + Apache Iceberg 통합 개발 환경을 구성하는 프로젝트.

## 아키텍처

```
Spark Connect 클라이언트 (Python/Scala)
    ↓ gRPC (sc://localhost:15002)
Spark Connect Server (SparkApplication on Kind)
    ↓
Polaris REST Catalog  ←→  PostgreSQL (메타데이터)
    ↓
Iceberg Tables
    ↓
MinIO (S3 호환 오브젝트 스토리지)
```

## 사전 요구사항

다음 도구들이 로컬에 설치되어 있어야 한다:

| 도구 | 용도 |
|------|------|
| `kind` | 로컬 Kubernetes 클러스터 |
| `kubectl` | Kubernetes CLI |
| `helm` | Helm 차트 배포 |
| `podman` | 컨테이너 이미지 빌드 |
| `envsubst` | kind-config.yaml 템플릿 치환 |
| `python3` | init-polaris-catalog.sh 내 JSON 파싱 |
| Java 17 | Spark/Iceberg 빌드 |

## 소스 레포 준비

`make all` 실행 전에 Spark, Iceberg 소스가 반드시 준비되어 있어야 한다.
기본 경로는 이 레포와 같은 디렉토리에 위치한다고 가정한다 (`../spark`, `../iceberg`).

```bash
# Spark (branch-4.1)
git clone https://github.com/apache/spark ../spark
git -C ../spark checkout branch-4.1

# Iceberg (1.10.1)
git clone https://github.com/apache/iceberg ../iceberg
git -C ../iceberg checkout apache-iceberg-1.10.1
```

경로가 다를 경우 `.env.local`로 오버라이드:

```bash
cp .env.default .env.local
# .env.local에서 SPARK_HOME, ICEBERG_HOME 수정
```

## 버전

| 컴포넌트 | 버전 |
|----------|------|
| Spark | branch-4.1 (4.1.2-SNAPSHOT) |
| Iceberg | main |
| Scala | 2.13 |
| Java | 17 |

## 디렉토리 구조

```
lakehouse-dev/
├── Makefile                           # 모든 자동화 진입점
├── kind-config.yaml.tmpl              # Kind 클러스터 설정 템플릿 (envsubst → kind-config.yaml)
├── .env.default                       # 기본 경로 변수 (커밋됨)
├── .env.local                         # 머신별 경로 오버라이드 (gitignore)
├── helm/
│   ├── minio-values.yaml              # MinIO Helm values (Ingress 포함)
│   ├── polaris-values.yaml            # Polaris Helm values (Ingress 포함)
│   ├── postgresql-values.yaml         # PostgreSQL Helm values (Polaris용)
│   └── spark-operator-values.yaml     # Spark Kubernetes Operator Helm values
├── manifests/
│   ├── spark-connect.yaml             # SparkApplication CR (Spark Connect 서버)
│   ├── polaris-postgres-secret.yaml   # PostgreSQL 접속 정보 Secret
│   ├── ingress-spark-connect-tcp.yaml # Spark Connect gRPC TCP ConfigMap (포트 15002)
│   └── ingress-spark-ui.yaml          # Spark UI Ingress
└── scripts/
    ├── build-iceberg.sh               # Iceberg 소스 빌드
    ├── build-spark-image.sh           # Spark 이미지 빌드 → Kind 로드
    ├── dev-build.sh                   # Spark 모듈 증분 빌드 + 핫리로드
    └── init-polaris-catalog.sh        # Polaris 카탈로그 REST API 초기화
```

## Kind 클러스터 구성

단일 control-plane 노드.

| 포트 매핑 | 용도 |
|-----------|------|
| 80 / 443 | ingress-nginx HTTP/HTTPS |
| 15002 | Spark Connect gRPC (TCP passthrough) |

호스트 경로 마운트:
- `$SPARK_HOME/assembly/target/scala-2.13/jars` → `/opt/spark/jars` (컨테이너 내부)

`kind-config.yaml`은 gitignore되어 있으며, `make cluster` 시 `envsubst < kind-config.yaml.tmpl`으로 생성된다.

## 설치 컴포넌트

| 컴포넌트 | 배포 방식 | 네임스페이스 |
|----------|-----------|-------------|
| ingress-nginx | kubectl apply | ingress-nginx |
| MinIO | Helm (minio/minio) | minio |
| PostgreSQL | Helm (bitnami/postgresql) | polaris |
| Apache Polaris | Helm (apache/polaris) | polaris |
| Spark Kubernetes Operator | Helm (apache/spark-kubernetes-operator) | spark-operator |
| Spark Connect Server | kubectl apply (SparkApplication CR) | spark |

- PostgreSQL은 Polaris 메타데이터 전용이다.
- Spark Connect gRPC는 Ingress 리소스가 아닌 ingress-nginx TCP passthrough(ConfigMap 방식)를 사용한다.
- MinIO와 Polaris Ingress는 Helm values에 포함되어 있다 (별도 manifest 없음).
- `infra` 타겟은 반드시 `deploy-ingress` 먼저 실행한다 (MinIO/Polaris Ingress가 ingress-nginx에 의존하기 때문).

## 접근 URL

| 서비스 | URL |
|--------|-----|
| MinIO Console | http://minio.localhost |
| MinIO API | http://minio-api.localhost |
| Polaris API | http://polaris.localhost |
| Polaris Mgmt | http://polaris-mgmt.localhost |
| Spark UI | http://spark.localhost |
| Spark Connect | sc://localhost:15002 |

## 크리덴셜

| 서비스 | 계정 | 비밀번호 |
|--------|------|----------|
| MinIO | minioadmin | minioadmin |
| PostgreSQL (Polaris용) | polaris | polaris |
| Polaris OAuth | root | s3cr3t |

## 빌드 프로세스

### Iceberg 빌드가 Spark 이미지 빌드보다 반드시 먼저여야 한다

Spark 이미지는 `$SPARK_HOME/assembly/target/scala-2.13/jars/`에 있는 Iceberg JAR를 번들링한다.
해당 경로에 Iceberg JAR가 없으면 `make spark-image`가 에러로 중단된다.

### 1단계: Iceberg 소스 빌드

```bash
make dev-build-iceberg
```

- `$ICEBERG_HOME`에서 Gradle 빌드 실행
- 빌드 대상: `iceberg-spark-runtime-4.1_2.13`, `iceberg-aws-bundle`
- 출력: `$SPARK_HOME/assembly/target/scala-2.13/jars/`에 JAR 복사

### 2단계: Spark 이미지 빌드

```bash
make spark-image
```

- Maven 빌드 (`-Pkubernetes -Phadoop-cloud` 프로파일)
- Iceberg JAR 존재 확인 (없으면 에러)
- Podman으로 컨테이너 이미지 빌드 (`docker-image-tool.sh`)
- Kind 클러스터에 로드: `localhost/spark-dev:latest`

### 3단계: 증분 빌드 (핫리로드)

풀 빌드 이후 특정 모듈만 수정할 때 사용한다.

```bash
make dev-build MODULE=sql/connect/server    # 기본값
make dev-build MODULE=sql/core              # 다른 모듈
make dev-build MODULE=sql/core,sql/catalyst # 복수 모듈
```

- 지정한 Maven 모듈만 컴파일
- 출력 JAR를 `assembly/jars/`에 복사 (Kind 마운트 경로와 동일)
- Driver Pod 자동 재시작 → 이미지 재빌드 없이 반영

## 전체 셋업

```bash
make all
```

내부 실행 순서:

```
make cluster          # Kind 클러스터 생성
    ↓
make infra            # deploy-ingress → deploy-minio → deploy-polaris → deploy-spark-operator
    ↓
make dev-build-iceberg
    ↓
make spark-image
    ↓
make spark-connect    # SparkApplication 배포
    ↓
make init-catalog     # Polaris 카탈로그 초기화
```

### init-catalog 동작

`init-polaris-catalog.sh`가 다음을 순서대로 수행한다:

1. Polaris 헬스체크 대기 (최대 60초)
2. OAuth 토큰 발급 (`root:s3cr3t`)
3. `spark_catalog` 카탈로그 생성 (MinIO `s3://warehouse` 백엔드)
4. 카탈로그 역할(admin) 생성 및 권한 부여
5. `default` 네임스페이스 생성

## 주요 커맨드

```bash
make status                  # 전체 Pod 상태 확인
make spark-connect-status    # SparkApplication + Pod 상태
make spark-connect-logs      # Spark Connect 드라이버 로그 스트리밍
make init-catalog            # Polaris 카탈로그 (재)초기화
make clean                   # 배포 전체 제거 (클러스터 유지)
make clean-all               # 클러스터까지 전체 제거
make help                    # 전체 타겟 목록
```
