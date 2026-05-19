# RouteIQ Grafana Dashboards

Three dashboards for visualising AI agent reliability and Claude Code usage, querying ClickHouse directly via SQL.

## Folder structure

```
grafana/
├── provisioning/
│   ├── routeiq-clickhouse-datasource.yaml   # ClickHouse datasource (env vars for creds)
│   └── routeiq-dashboards.yaml              # Tells Grafana where to find dashboard JSONs
└── dashboards/
    ├── routeiq-agent-overview.json          # Fleet-level agent health + drift detection
    ├── routeiq-session-drilldown.json       # Per-session forensics + penalty breakdown
    └── claude-code-agent.json              # Claude Code usage — cost, tokens, tool usage
```

## Requirements

- Grafana 10+ with [grafana-clickhouse-datasource](https://grafana.com/grafana/plugins/grafana-clickhouse-datasource/) plugin installed
- ClickHouse instance with `otel_traces` and `otel_logs` tables (standard OTel schema)

## Setup

### 1. Set environment variables

```bash
export CLICKHOUSE_HOST=your-instance.clickhouse.cloud
export CLICKHOUSE_PORT=8443
export CLICKHOUSE_USER=default
export CLICKHOUSE_PASSWORD=yourpassword
export CLICKHOUSE_DATABASE=default
```

### 2. Copy provisioning files into Grafana

```bash
# Datasource
cp grafana/provisioning/routeiq-clickhouse-datasource.yaml \
   /path/to/grafana/conf/provisioning/datasources/

# Dashboard loader
cp grafana/provisioning/routeiq-dashboards.yaml \
   /path/to/grafana/conf/provisioning/dashboards/

# Dashboard JSONs
mkdir -p /path/to/grafana/conf/provisioning/dashboards/routeiq
cp grafana/dashboards/*.json \
   /path/to/grafana/conf/provisioning/dashboards/routeiq/
```

**Homebrew (macOS):**
```bash
GRAFANA_PROV=/opt/homebrew/share/grafana/conf/provisioning

cp grafana/provisioning/routeiq-clickhouse-datasource.yaml $GRAFANA_PROV/datasources/
cp grafana/provisioning/routeiq-dashboards.yaml            $GRAFANA_PROV/dashboards/
mkdir -p $GRAFANA_PROV/dashboards/routeiq
cp grafana/dashboards/*.json                               $GRAFANA_PROV/dashboards/routeiq/

brew services restart grafana
```

### 3. Verify

```bash
curl -s http://localhost:3000/api/dashboards/uid/routeiq-agent-overview --user admin:admin \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['dashboard']['title'])"
```

## Dashboards

| Dashboard | UID | Data source |
|---|---|---|
| RouteIQ — Agent Overview | `routeiq-agent-overview` | `otel_traces` |
| RouteIQ — Session Drilldown | `routeiq-session-drilldown` | `otel_traces` |
| Claude Code — Agent Dashboard | `claude-code-agent` | `otel_logs` |

### Agent Overview (`otel_traces`)
Fleet-level health for RouteIQ SDK agents:
- Reliability score per agent (0–100, colour-coded)
- p95 latency, avg cost, tool failure rate, loop rate, guardrail rate
- Drift detection — last 10 sessions vs prior 10
- Agent table with drilldown link to Session Drilldown

### Session Drilldown (`otel_traces`)
Per-session forensics:
- Header stats — duration, tokens, cost, reliability score, completion reason
- Full span timeline in chronological order
- Penalty breakdown table — which reliability deductions applied and why

### Claude Code Agent Dashboard (`otel_logs`)
Claude Code usage metrics from `claude-code-otel`:
- Cost and token burn over time
- Tool usage — top tools, accept rate per tool
- Session table — cost, tokens, API calls, duration per session
- Per-session API call timeline

## Syncing after changes

Grafana auto-reloads provisioned dashboards every 10 seconds. After editing a JSON file just copy it:

```bash
cp grafana/dashboards/<file>.json /path/to/grafana/conf/provisioning/dashboards/routeiq/
# no restart needed
```
