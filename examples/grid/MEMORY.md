# MEMORY.md - Long-Term Memory

*Last updated: 2026-04-05*

## Cluster Topology (OVH, admin@truelist-cluster-1)
- **Nodes:** talos-node-2, talos-node-4, talos-mysql-primary-new, talos-mysql-replica-new (4 nodes)
- **Backend:** 5 pods (truelist-backend-deploy)
- **Sidekiq:** 20 workers + 1 maintenance
- **Browser validators:** 8 workers + 1 controller
- **MySQL:** primary + replica (statefulsets)
- **Redis:** cache + sidekiq (statefulsets)
- **Websockets:** 1 pod

## Key Metrics (Prometheus)
- `ruby_batch_validation_rate_per_second` — per-batch throughput (normal: 200-400 emails/sec)
- `ruby_email_validation_total` — total validations
- `ruby_sidekiq_dead_jobs_total` — dead jobs
- `ruby_sidekiq_failed_jobs_total` — failed jobs

## Lessons Learned
- **Grafana dashboards may render empty in headless browser** — use the Grafana API directly (`/api/datasources/proxy/...`) to verify data
- **Prometheus runs on the homelab k3s cluster, NOT the OVH production cluster** — don't kubectl the wrong context
