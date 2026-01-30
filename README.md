# Go Apps Infrastructure

Kubernetes (K3s) manifests and monitoring configurations.

## Structure

```
goapps-infra/
├── k3s/
│   ├── staging/
│   │   ├── apps/           # Application deployments
│   │   ├── databases/
│   │   │   ├── postgresql/
│   │   │   └── minio/
│   │   └── namespaces/
│   └── production/
│       ├── apps/
│       ├── databases/
│       │   ├── postgresql/
│       │   └── minio/
│       └── namespaces/
├── monitoring/
│   ├── grafana/
│   │   ├── dashboards/
│   │   └── datasources/
│   ├── prometheus/
│   │   └── rules/
│   └── loki/
│       └── config/
└── README.md
```

## Components

- **K3s**: Lightweight Kubernetes
- **PostgreSQL**: Primary database
- **MinIO**: S3-compatible object storage
- **Grafana**: Dashboards and visualization
- **Prometheus**: Metrics collection
- **Loki**: Log aggregation
