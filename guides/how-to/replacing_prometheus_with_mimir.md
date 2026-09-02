# How to Replace Prometheus with Mimir

> **This PR delivers a Mimir that can be configured and scraped — not a Mimir that can be
> provisioned end to end.** The `mimir_db` role, the `grafana_alloy` metrics pipeline
> (`prometheus.scrape` + `prometheus.remote_write`), and the Grafana Mimir datasource are
> all here. The Terraform work that gives a `mimir_db` node a real `/data` volume is a
> separate, not-yet-landed item — see "What this branch does not include" below.

`mimir_db` is a **push-model** metrics backend: every node that runs Grafana Alloy scrapes
only itself (`node_exporter` on `:9100`, plus the app on `alloy_app_metrics_port` —
default `4050` — where one runs) and pushes those series to Mimir via
`prometheus.remote_write`. There is no central scraper and no `ec2_sd` on the Mimir side.
Alloy labels its pushed series `job="nodes"` / `job="apps"` and attaches
`instance`/`instance_id`, matching Prometheus's own EC2-derived labels, so a shared rule
set keyed on those labels (`NoNodesDiscovered`, `NoAppsDiscovered`, `TargetDown`) stays
meaningful against either backend.

This is additive: **Prometheus keeps running untouched by this port** — nothing here
removes or modifies the `prometheus_db` role. Alloy's Loki pipeline is untouched too
(byte-identical, aside from one pre-existing guard on `app_name`); the Mimir metrics
pipeline is new content appended behind `{% if grafana_mimir_url is defined %}`, so a
node whose `group_vars` never sets `grafana_mimir_url` renders exactly the logs-only
Alloy config it rendered before this PR.

## Stack Overview

| Component | Purpose |
|-----------|---------|
| `mimir_db` | Push-based metrics TSDB + ruler (monolithic mode) — **new in this PR** |
| `prometheus_db` | Pull-based metrics TSDB — unchanged, still scraping |
| `grafana_alloy` (every node with `grafana_mimir_url` set) | Tails the journal (Loki) **and** scrapes+pushes local metrics (Mimir) |

`grafana_mimir_url` and `grafana_prometheus_url` are both plain `group_vars` values on
this branch — there is no `--no-mimir` build flag and no `.eex`-templated conditional
role line on `grafana_ui.yaml` / `loki_log_aggregator.yaml` / `prometheus_db.yaml` (see
`priv/ansible/setup/Agents.md` for why). A node picks up the Mimir pipeline by having
`grafana_mimir_url` defined in its rendered `group_vars/all.yaml` and the `grafana_alloy`
role in its playbook.

## What this branch does not include

There is no Terraform wiring in this PR — no block volume, no `mimir_db` instance
definition, no changes to `terraform.build.ex` or `priv_renderer.ex`. That is deliberate:
those files diverge heavily between the OCI and AWS lines and reconciling them is a
separate decision.

**The `mimir_db` role will refuse to install without a real `/data` mount, and that is
intended behaviour, not a gap.** `roles/mimir_db/tasks/main.yaml` opens with:

```yaml
- name: Assert /data is a mounted filesystem before writing Mimir data there
  assert:
    that: ansible_facts.mounts | selectattr('mount', 'equalto', '/data') | list | length > 0
    fail_msg: "/data is not a mounted filesystem — Mimir must not write TSDB/blocks/rules to the root volume"
```

and `mimir_systemd.service.j2` carries `RequiresMountsFor=/data` as a second, systemd-level
gate. Every path in `mimir-config.yaml.j2` — `common.storage`, `blocks_storage`, `tsdb`,
`compactor`, `ruler`, `alertmanager` — lives under `/data/mimir/*` with no fallback to the
root volume. opgg's OCI module has no cloud-init and no block volume today (its own
README calls AWS's `cloud_init_data.yaml.tftpl` "not ported"), and the only `/data`
opgg's ansible creates is a bare directory for redis (`file: path: /data state:
directory`) — that does **not** appear in `ansible_facts.mounts`. Running
`mix ansible.setup --only mimir_db` against an OCI node today will abort at the assert.
**Do not weaken the assert to work around this** — provision a real `/data` mount (via
the forthcoming Terraform work) instead.

## Trying it locally

1. Set `grafana_mimir_url` and `grafana_prometheus_url` in `deploys/ansible/group_vars/all.yaml`.
2. Roll `mix ansible.build` so `grafana_ui`'s and `mimir_db`'s setup playbooks pick up the
   role changes (role files sync on every `ansible.build` run).
3. Query Mimir's Prometheus-compatible API once a `mimir_db` node exists and is running:
   ```bash
   curl "http://<mimir_db private ip>:8080/prometheus/api/v1/query?query=up"
   curl "http://<mimir_db private ip>:8080/prometheus/api/v1/rules"
   ```
4. In Grafana, the datasource list now includes "Mimir Metrics" (`type: prometheus`,
   `url: {{ grafana_mimir_url }}/prometheus`) alongside "Loki Logs" and, when
   `grafana_prometheus_url` is set, "Prometheus Metrics". Nothing sets `isDefault` on
   either Prometheus-type datasource — pick one from the Grafana UI.

## Troubleshooting

- **Mimir ruler shows no rule groups** — confirm `/data/mimir/rules/anonymous/rules.yaml`
  exists on the `mimir_db` node and matches `mimir_db/templates/prometheus-rules.yaml.j2`
  byte for byte. Also confirm `mimir-config.yaml.j2`'s `ruler_storage.backend` is `local`,
  not `filesystem` — `filesystem` is a blocks-storage-only backend name and the ruler
  silently serves zero rule groups against it.
- **Play aborts with `AnsibleUndefinedVariable` on a monitoring node** — the Alloy journal
  relabel rule guards `app_name` with `| default('')` specifically because
  monitoring-node plays never set it; keep that guard if you customize
  `alloy_config.alloy.j2`.
- **A node isn't pushing metrics** — check `grafana_mimir_url` is defined in
  `deploys/ansible/group_vars/all.yaml` and that the node's `alloy.service` is running.
- **App nodes missing from Mimir** — the app-port scrape only renders when `app_name` is
  set in the play (app playbooks); monitoring nodes don't run an app on that port.
- **`/data is not a mounted filesystem` on mimir_db setup** — expected until the
  Terraform work for a real block volume lands; see "What this branch does not include"
  above.

See also: [Monitoring](monitoring.md)
