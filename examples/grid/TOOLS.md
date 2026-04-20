# TOOLS.md - Local Notes

## Kubernetes
- **KUBECONFIG:** `/home/node/.openclaw/.kube/config`
- **Default context:** `local-k3s` (homelab k3s, 3 workers + controller — runs Grafana/Prometheus)
- **Production context:** `admin@truelist-cluster-1` (OVH Talos, 4 nodes — runs Truelist)
- Also available: `admin@truelist-cluster`, `admin@truelist-cluster-2`, `aws-truelist-prod`, `kind-mariadb-test`, `minikube`
- ⚠️ Always `kubectl config use-context admin@truelist-cluster-1` before production work
- ⚠️ Prometheus/Grafana run on `local-k3s`, NOT production. Don't confuse contexts.

## Production Topology (OVH, admin@truelist-cluster-1)
- **Nodes:** talos-node-2, talos-node-4, talos-mysql-primary-new, talos-mysql-replica-new
- **Backend:** 5 pods (truelist-backend-deploy)
- **Sidekiq:** 20 workers + 1 maintenance
- **Browser validators:** 8 workers + 1 controller
- **MySQL:** primary + replica (statefulsets)
- **Redis:** cache + sidekiq (statefulsets)
- **Websockets:** 1 pod

## Key Namespaces (OVH Production)
- `truelist` — main app workloads
- `truelist-admin` — admin interface
- `mariadb-system` — database
- `monitoring` — exporters/promtail
- `ingress-nginx`, `cert-manager`, `longhorn-system`, `tailscale`, `metallb-system`

## Grafana
- **URL:** https://grafana.local.grant.dev/
- **Auth:** credentials in password manager
- **Datasources:** Prometheus, Loki, MySQL (clearlist_prod), CloudWatch
- **API access:** Use `/api/datasources/proxy/...` for data — headless browser renders empty

## Prometheus Metrics (key ones)
- `ruby_batch_validation_rate_per_second` — per-batch throughput
- `ruby_email_validation_total` — total validations
- `ruby_ip_validation_total` — validations by IP
- `ruby_mx_provider_validation_total` — by mail provider
- `ruby_sidekiq_dead_jobs_total` — dead jobs
- `ruby_sidekiq_failed_jobs_total` — failed jobs

## Loki (Logs)
- Available via Grafana datasource
- Use for: log aggregation, error investigation, correlation with metrics

## Slack Channels
- #truelist-team (C0AQS7PN3EF) — inter-bot handoffs and collaboration. Scan for "@grid" mentions on heartbeat.
- #support (C054Q9GQYER) — Bugsnag alerts, engineering issues
- Grant's DM: D0AC56SRN4W

## GitHub
- **CLI:** `gh` authenticated as `gammons`
- **Key repos:**
  - `clearlist-io-backend/` — Rails backend + K8s configs
  - `clearlist-frontend/` — SvelteKit frontend
  - `email-validator/` — Core validation gem

## Production Safety Reminders
- NEVER full-scan hot tables
- NEVER run Redis KEYS *
- NEVER make infrastructure changes without Grant's explicit approval
- Always verify context before kubectl commands
- `trash` > `rm` — recoverable beats gone forever
