#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHART="helm/applications/microservices-platform"
mkdir -p "$CHART/templates" docs

echo "===== CREATING HELM CHART ====="

cat > "$CHART/Chart.yaml" <<'EOF'
apiVersion: v2
name: microservices-platform
description: ARM64 EKS Node.js microservices platform with PostgreSQL
type: application
version: 1.0.0
appVersion: "1.0.0"
EOF

cat > "$CHART/values.yaml" <<'EOF'
global:
  environment: production

nodeSelector:
  kubernetes.io/arch: arm64

secrets:
  name: platform-secrets

services:
  api-gateway:
    enabled: true
    image:
      repository: 924408032261.dkr.ecr.ap-south-1.amazonaws.com/eks-arm64-platform/api-gateway
      tag: dev
      pullPolicy: IfNotPresent
    replicas: 1
    servicePort: 3000
    readinessPath: /health
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 384Mi

  auth-service:
    enabled: true
    image:
      repository: 924408032261.dkr.ecr.ap-south-1.amazonaws.com/eks-arm64-platform/auth-service
      tag: dev
      pullPolicy: IfNotPresent
    replicas: 1
    servicePort: 3000
    readinessPath: /ready
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 384Mi

  employee-service:
    enabled: true
    image:
      repository: 924408032261.dkr.ecr.ap-south-1.amazonaws.com/eks-arm64-platform/employee-service
      tag: dev
      pullPolicy: IfNotPresent
    replicas: 1
    servicePort: 3000
    readinessPath: /ready
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 384Mi

  product-service:
    enabled: true
    image:
      repository: 924408032261.dkr.ecr.ap-south-1.amazonaws.com/eks-arm64-platform/product-service
      tag: dev
      pullPolicy: IfNotPresent
    replicas: 1
    servicePort: 3000
    readinessPath: /ready
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 384Mi

  order-service:
    enabled: true
    image:
      repository: 924408032261.dkr.ecr.ap-south-1.amazonaws.com/eks-arm64-platform/order-service
      tag: dev
      pullPolicy: IfNotPresent
    replicas: 1
    servicePort: 3000
    readinessPath: /ready
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 384Mi

postgres:
  enabled: true
  image:
    repository: postgres
    tag: "17-alpine"
  replicas: 1
  persistence:
    enabled: true
    size: 8Gi
    storageClass: ""
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
EOF

cat > "$CHART/templates/serviceaccount.yaml" <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: microservices
  labels:
    app.kubernetes.io/part-of: microservices-platform
automountServiceAccountToken: false
EOF

cat > "$CHART/templates/configmap.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: microservices-config
data:
  NODE_ENV: production
  AUTH_SERVICE_URL: http://auth-service:3000
  EMPLOYEE_SERVICE_URL: http://employee-service:3000
  PRODUCT_SERVICE_URL: http://product-service:3000
  ORDER_SERVICE_URL: http://order-service:3000
EOF

cat > "$CHART/templates/deployments.yaml" <<'EOF'
{{- range $name, $svc := .Values.services }}
{{- if $svc.enabled }}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $name }}
  labels:
    app.kubernetes.io/name: {{ $name }}
    app.kubernetes.io/part-of: microservices-platform
spec:
  replicas: {{ $svc.replicas }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ $name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ $name }}
        app.kubernetes.io/part-of: microservices-platform
    spec:
      serviceAccountName: microservices
      automountServiceAccountToken: false
      nodeSelector:
{{ toYaml $.Values.nodeSelector | indent 8 }}
      securityContext:
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: {{ $name }}
          image: "{{ $svc.image.repository }}:{{ $svc.image.tag }}"
          imagePullPolicy: {{ $svc.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 3000
              protocol: TCP
          envFrom:
            - configMapRef:
                name: microservices-config
          env:
            - name: PORT
              value: "3000"
{{- if ne $name "api-gateway" }}
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: {{ $.Values.secrets.name }}
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ $.Values.secrets.name }}
                  key: POSTGRES_PASSWORD
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: {{ $.Values.secrets.name }}
                  key: POSTGRES_DB
            - name: DATABASE_URL
              value: "postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@postgres:5432/$(POSTGRES_DB)"
            - name: JWT_SECRET
              valueFrom:
                secretKeyRef:
                  name: {{ $.Values.secrets.name }}
                  key: JWT_SECRET
{{- end }}
          startupProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 5
            failureThreshold: 30
            timeoutSeconds: 5
          readinessProbe:
            httpGet:
              path: {{ $svc.readinessPath }}
              port: http
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 3
          resources:
{{ toYaml $svc.resources | indent 12 }}
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 64Mi
{{- end }}
{{- end }}
EOF

cat > "$CHART/templates/services.yaml" <<'EOF'
{{- range $name, $svc := .Values.services }}
{{- if $svc.enabled }}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $name }}
  labels:
    app.kubernetes.io/name: {{ $name }}
    app.kubernetes.io/part-of: microservices-platform
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: {{ $name }}
  ports:
    - name: http
      port: {{ $svc.servicePort }}
      targetPort: 3000
      protocol: TCP
{{- end }}
{{- end }}
EOF

cat > "$CHART/templates/postgres.yaml" <<'EOF'
{{- if .Values.postgres.enabled }}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-headless
spec:
  clusterIP: None
  selector:
    app.kubernetes.io/name: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  labels:
    app.kubernetes.io/name: postgres
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  labels:
    app.kubernetes.io/name: postgres
    app.kubernetes.io/part-of: microservices-platform
spec:
  serviceName: postgres-headless
  replicas: {{ .Values.postgres.replicas }}
  selector:
    matchLabels:
      app.kubernetes.io/name: postgres
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postgres
        app.kubernetes.io/part-of: microservices-platform
    spec:
      nodeSelector:
{{ toYaml .Values.nodeSelector | indent 8 }}
      securityContext:
        fsGroup: 999
        fsGroupChangePolicy: OnRootMismatch
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: postgres
          image: "{{ .Values.postgres.image.repository }}:{{ .Values.postgres.image.tag }}"
          ports:
            - name: postgres
              containerPort: 5432
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secrets.name }}
                  key: POSTGRES_USER
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secrets.name }}
                  key: POSTGRES_PASSWORD
            - name: POSTGRES_DB
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.secrets.name }}
                  key: POSTGRES_DB
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          livenessProbe:
            exec:
              command:
                - /bin/sh
                - -c
                - pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
            periodSeconds: 20
            timeoutSeconds: 5
            failureThreshold: 6
          resources:
{{ toYaml .Values.postgres.resources | indent 12 }}
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes:
          - ReadWriteOnce
{{- if .Values.postgres.persistence.storageClass }}
        storageClassName: {{ .Values.postgres.persistence.storageClass | quote }}
{{- end }}
        resources:
          requests:
            storage: {{ .Values.postgres.persistence.size }}
{{- end }}
EOF

cat > "$CHART/.helmignore" <<'EOF'
.git/
.gitignore
*.swp
*.bak
*.tmp
.DS_Store
EOF

echo "===== CREATING VALIDATION SCRIPT ====="

cat > scripts/validate-helm-platform.sh <<'VALIDATE'
#!/usr/bin/env bash
set -Eeuo pipefail

CHART="helm/applications/microservices-platform"
OUTPUT="/tmp/microservices-platform-rendered.yaml"

command -v helm >/dev/null || {
  echo "ERROR: Helm is not installed."
  exit 1
}

echo "===== HELM LINT ====="
helm lint "$CHART"

echo
echo "===== RENDERING KUBERNETES MANIFESTS ====="
helm template microservices-platform "$CHART" \
  --namespace microservices > "$OUTPUT"

echo "Rendered manifest: $OUTPUT"

echo
echo "===== RESOURCE COUNTS ====="
printf "Deployments: "
grep -c '^kind: Deployment$' "$OUTPUT"

printf "Services: "
grep -c '^kind: Service$' "$OUTPUT"

printf "StatefulSets: "
grep -c '^kind: StatefulSet$' "$OUTPUT"

printf "ARM64 node selectors: "
grep -c 'kubernetes.io/arch: arm64' "$OUTPUT"

echo
echo "===== EXPECTED SERVICE CHECK ====="
for service in api-gateway auth-service employee-service product-service order-service; do
  if grep -q "name: $service" "$OUTPUT"; then
    echo "OK: $service"
  else
    echo "ERROR: $service missing"
    exit 1
  fi
done

grep -q 'name: postgres' "$OUTPUT" || {
  echo "ERROR: PostgreSQL StatefulSet missing"
  exit 1
}

echo
echo "===== HELM VALIDATION PASSED ====="
VALIDATE

chmod +x scripts/validate-helm-platform.sh

echo "===== DOCUMENTING CHART ====="

cat > docs/kubernetes-helm-deployment.md <<'EOF'
# Kubernetes and Helm Deployment

## Chart

`helm/applications/microservices-platform`

## Workloads

- API Gateway
- Auth Service
- Employee Service
- Product Service
- Order Service
- PostgreSQL StatefulSet

## Platform characteristics

- ARM64 node selection using `kubernetes.io/arch: arm64`
- ClusterIP service discovery
- Startup, readiness and liveness probes
- CPU and memory requests and limits
- Non-root application containers
- Dropped Linux capabilities
- PostgreSQL persistent volume claim
- Kubernetes Secret references for database credentials and JWT secret

## Secret prerequisite

Create a Kubernetes Secret named `platform-secrets` in the `microservices`
namespace with these keys:

- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `POSTGRES_DB`
- `JWT_SECRET`

Do not commit secret values to Git.

## Validation

```bash
helm lint helm/applications/microservices-platform

helm template microservices-platform \
  helm/applications/microservices-platform \
  --namespace microservices
```

## Deployment

Deploy only after ECR images have been published, the secret has been
created, the target StorageClass is verified, and ARM64 node capacity is ready.

```bash
helm upgrade --install microservices-platform \
  helm/applications/microservices-platform \
  --namespace microservices \
  --create-namespace \
  --wait
```

This chart's PostgreSQL StatefulSet is a lab deployment. For production,
prefer a managed database such as Amazon RDS with backups and multi-AZ
availability.
EOF

echo
echo "===== VALIDATING HELM CHART ====="
./scripts/validate-helm-platform.sh

echo
echo "HELM PLATFORM CHART CREATED SUCCESSFULLY"
