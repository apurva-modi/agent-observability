-- ─────────────────────────────────────────────────────────────────────────────
-- RouteIQ SLO Schema
--
-- Cadence: the materialized view (routeiq_slo_hourly_mv) fires on every INSERT
-- into otel_traces. The OTel collector batches every 5 s / 1 000 spans, so the
-- table is updated continuously with no external scheduler. AggregatingMergeTree
-- merges states in the background; always query with FINAL for accurate results.
--
-- SLO thresholds (enforced at query / dashboard layer):
--   success_rate  ≥ 95 %
--   p95_latency   ≤ 30 s
--   avg_cost      ≤ $1.00 / task
--   escalation    ≤ 20 % of tasks with > 3 human turns
-- ─────────────────────────────────────────────────────────────────────────────

-- ── 1. Destination table ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS routeiq_slo_hourly
(
    window_start      DateTime,
    agent_id          LowCardinality(String),

    -- task counts  (SimpleAggregateFunction → sum-combinable across merges)
    total_tasks       SimpleAggregateFunction(sum, UInt64),
    success_count     SimpleAggregateFunction(sum, UInt64),
    failure_count     SimpleAggregateFunction(sum, UInt64),

    -- cost
    total_cost_usd    SimpleAggregateFunction(sum, Float64),

    -- escalation
    total_human_turns SimpleAggregateFunction(sum, UInt64),
    heavily_escalated SimpleAggregateFunction(sum, UInt64),  -- tasks with >3 human turns

    -- quantile states  (require quantileMerge(0.95) at query time)
    latency_state     AggregateFunction(quantile(0.95), Float64),
    cost_state        AggregateFunction(quantile(0.95), Float64)
)
ENGINE = AggregatingMergeTree()
ORDER BY (window_start, agent_id);


-- ── 2. Materialized view — populates automatically on every otel_traces INSERT ─
--
-- Covers all frameworks:
--   RouteIQ SDK  → SpanName LIKE 'task:%' AND ParentSpanId = ''
--                  success: routeiq.task.completion_status = '1'
--   Claude Code  → SpanName = 'session:summary'
--   Strands      → SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = ''
--   LangChain    → SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = ''
CREATE MATERIALIZED VIEW IF NOT EXISTS routeiq_slo_hourly_mv
TO routeiq_slo_hourly
AS
SELECT
    toStartOfHour(Timestamp)                                              AS window_start,
    coalesce(
        nullIf(SpanAttributes['routeiq.agent.id'], ''),
        nullIf(SpanAttributes['agent.id'], ''),
        nullIf(ResourceAttributes['routeiq.agent_id'], ''),
        ServiceName
    )                                                                     AS agent_id,

    count()                                                               AS total_tasks,

    -- RouteIQ SDK uses completion_status '1'=success; others use StatusCode
    countIf(if(
        SpanName LIKE 'task:%',
        SpanAttributes['routeiq.task.completion_status'] = '1',
        StatusCode != 'STATUS_CODE_ERROR'
    ))                                                                    AS success_count,
    countIf(if(
        SpanName LIKE 'task:%',
        SpanAttributes['routeiq.task.completion_status'] != '1',
        StatusCode  = 'STATUS_CODE_ERROR'
    ))                                                                    AS failure_count,

    sum(toFloat64OrDefault(SpanAttributes['session.cost_usd']))          AS total_cost_usd,

    sum(toInt64OrDefault(SpanAttributes['session.human_turns']))         AS total_human_turns,
    countIf(toInt64OrDefault(SpanAttributes['session.human_turns']) > 3) AS heavily_escalated,

    -- latency: Claude Code uses session.duration_s; all others use Duration
    quantileState(0.95)(if(
        SpanName = 'session:summary',
        toFloat64OrDefault(SpanAttributes['session.duration_s']),
        Duration / 1e9
    ))                                                                    AS latency_state,

    quantileState(0.95)(toFloat64OrDefault(SpanAttributes['session.cost_usd'])) AS cost_state

FROM otel_traces
WHERE
    (SpanName LIKE 'task:%'    AND ParentSpanId = '')
    OR SpanName = 'session:summary'
    OR (SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = '')
    OR (SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = '')
GROUP BY window_start, agent_id;


-- ── 3. One-time backfill — run once to seed historical data ───────────────────
INSERT INTO routeiq_slo_hourly
SELECT
    toStartOfHour(Timestamp)                                              AS window_start,
    coalesce(
        nullIf(SpanAttributes['routeiq.agent.id'], ''),
        nullIf(SpanAttributes['agent.id'], ''),
        nullIf(ResourceAttributes['routeiq.agent_id'], ''),
        ServiceName
    )                                                                     AS agent_id,

    count()                                                               AS total_tasks,

    countIf(if(
        SpanName LIKE 'task:%',
        SpanAttributes['routeiq.task.completion_status'] = '1',
        StatusCode != 'STATUS_CODE_ERROR'
    ))                                                                    AS success_count,
    countIf(if(
        SpanName LIKE 'task:%',
        SpanAttributes['routeiq.task.completion_status'] != '1',
        StatusCode  = 'STATUS_CODE_ERROR'
    ))                                                                    AS failure_count,

    sum(toFloat64OrDefault(SpanAttributes['session.cost_usd']))          AS total_cost_usd,

    sum(toInt64OrDefault(SpanAttributes['session.human_turns']))         AS total_human_turns,
    countIf(toInt64OrDefault(SpanAttributes['session.human_turns']) > 3) AS heavily_escalated,

    quantileState(0.95)(if(
        SpanName = 'session:summary',
        toFloat64OrDefault(SpanAttributes['session.duration_s']),
        Duration / 1e9
    ))                                                                    AS latency_state,

    quantileState(0.95)(toFloat64OrDefault(SpanAttributes['session.cost_usd'])) AS cost_state

FROM otel_traces
WHERE
    (SpanName LIKE 'task:%'    AND ParentSpanId = '')
    OR SpanName = 'session:summary'
    OR (SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = '')
    OR (SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = '')
GROUP BY window_start, agent_id;


-- ── 4. Reference SELECT queries (used verbatim in Grafana panels) ─────────────

-- 4a. SLO Scorecard — current 24 h status per agent
SELECT
    agent_id,
    sum(total_tasks)                                                       AS tasks,
    round(100.0 * sum(success_count) / sum(total_tasks), 1)               AS success_rate_pct,
    if(sum(success_count) / sum(total_tasks) >= 0.95, 1, 0)               AS slo_success_ok,
    round(quantileMerge(0.95)(latency_state), 2)                          AS p95_latency_s,
    if(quantileMerge(0.95)(latency_state) <= 30, 1, 0)                   AS slo_latency_ok,
    round(if(sum(total_tasks) > 0,
        sum(total_cost_usd) / sum(total_tasks), 0), 4)                    AS avg_cost_usd,
    if(sum(total_cost_usd) / sum(total_tasks) <= 1.0, 1, 0)              AS slo_cost_ok,
    round(100.0 * sum(heavily_escalated) / sum(total_tasks), 1)           AS escalation_rate_pct,
    if(sum(heavily_escalated) / sum(total_tasks) <= 0.2, 1, 0)           AS slo_escalation_ok
FROM routeiq_slo_hourly FINAL
WHERE window_start >= now() - INTERVAL 24 HOUR
GROUP BY agent_id
ORDER BY tasks DESC;

-- 4b. Success rate over time (Grafana time series — use $__timeFilter macro)
SELECT
    window_start                                                           AS time,
    agent_id,
    round(100.0 * sum(success_count) / sum(total_tasks), 2)               AS success_rate_pct
FROM routeiq_slo_hourly FINAL
WHERE $__timeFilter(window_start)
GROUP BY time, agent_id
ORDER BY time;

-- 4c. P95 latency over time
SELECT
    window_start                                                           AS time,
    agent_id,
    round(quantileMerge(0.95)(latency_state), 2)                          AS p95_latency_s
FROM routeiq_slo_hourly FINAL
WHERE $__timeFilter(window_start)
GROUP BY time, agent_id
ORDER BY time;

-- 4d. Avg cost per task over time
SELECT
    window_start                                                           AS time,
    agent_id,
    round(if(sum(total_tasks) > 0,
        sum(total_cost_usd) / sum(total_tasks), 0), 4)                    AS avg_cost_usd
FROM routeiq_slo_hourly FINAL
WHERE $__timeFilter(window_start)
GROUP BY time, agent_id
ORDER BY time;

-- 4e. Escalation rate over time
SELECT
    window_start                                                           AS time,
    agent_id,
    round(100.0 * sum(heavily_escalated) / sum(total_tasks), 2)           AS escalation_rate_pct
FROM routeiq_slo_hourly FINAL
WHERE $__timeFilter(window_start)
GROUP BY time, agent_id
ORDER BY time;
