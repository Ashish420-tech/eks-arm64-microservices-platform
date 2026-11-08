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
