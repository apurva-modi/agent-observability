-- ─────────────────────────────────────────────────────────────────────────────
-- RouteIQ Aggregation Queries
-- Source data: otel_traces (populated by OpenTelemetry collector → ClickHouse)
--
-- Covers all agent frameworks:
--   Claude Code  → SpanName = 'session:summary'
--   Strands      → SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = ''
--   LangChain    → SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = ''
-- ─────────────────────────────────────────────────────────────────────────────


-- ── 1. Task Success & Failure Rate ────────────────────────────────────────────

-- Per-agent rollup
SELECT
    coalesce(
        nullIf(SpanAttributes['agent.id'], ''),
        nullIf(ResourceAttributes['routeiq.agent_id'], ''),
        ServiceName
    )                                                                        AS agent_id,
    count()                                                                  AS total_tasks,
    countIf(StatusCode != 'STATUS_CODE_ERROR')                              AS success_count,
    countIf(StatusCode  = 'STATUS_CODE_ERROR')                              AS failure_count,
    round(100.0 * countIf(StatusCode != 'STATUS_CODE_ERROR') / count(), 2) AS success_rate_pct,
    round(100.0 * countIf(StatusCode  = 'STATUS_CODE_ERROR') / count(), 2) AS failure_rate_pct
FROM otel_traces
WHERE
    SpanName = 'session:summary'
    OR (SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = '')
    OR (SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = '')
GROUP BY agent_id
ORDER BY total_tasks DESC;

-- Per-task detail
SELECT
    coalesce(
        nullIf(SpanAttributes['agent.id'], ''),
        nullIf(ResourceAttributes['routeiq.agent_id'], ''),
        ServiceName
    )                                                                        AS agent_id,
    coalesce(nullIf(SpanAttributes['session.id'], ''), TraceId)             AS task_id,
    SpanName                                                                 AS framework,
    if(StatusCode = 'STATUS_CODE_ERROR', 'FAILURE', 'SUCCESS')             AS outcome,
    StatusCode,
    round(Duration / 1e9, 2)                                                AS duration_s,
    Timestamp
FROM otel_traces
WHERE
    SpanName = 'session:summary'
    OR (SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = '')
    OR (SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = '')
ORDER BY agent_id, Timestamp DESC;


-- ── 2. Logs with Reason for Task Success / Failure ────────────────────────────

WITH all_tasks AS (
    SELECT
        coalesce(
            nullIf(SpanAttributes['agent.id'], ''),
            nullIf(ResourceAttributes['routeiq.agent_id'], ''),
            ServiceName
        )                                                                    AS agent_id,
        coalesce(nullIf(SpanAttributes['session.id'], ''), TraceId)         AS task_id,
        TraceId,
        SpanName                                                             AS span_type,
        StatusCode,
        StatusMessage,
        toInt64OrDefault(SpanAttributes['session.tool_errors'])             AS tool_errors,
        toFloat64OrDefault(SpanAttributes['session.error_rate_pct'])        AS error_rate_pct,
        SpanAttributes['traceloop.entity.output']                           AS lc_output,
        SpanAttributes['gen_ai.agent.name']                                 AS strands_agent_name,
        Duration
    FROM otel_traces
    WHERE
        SpanName = 'session:summary'
        OR (SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = '')
        OR (SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = '')
),
claude_turn_reasons AS (
    SELECT
        SpanAttributes['session.id']                                        AS session_id,
        argMax(
            SpanAttributes['turn.stop_reason'],
            toInt32OrDefault(SpanAttributes['turn.index'])
        )                                                                    AS last_stop_reason,
        countIf(SpanAttributes['turn.stop_reason'] = 'max_tokens')         AS max_tokens_hits
    FROM otel_traces
    WHERE SpanName = 'llm:turn'
    GROUP BY session_id
)
SELECT
    t.agent_id,
    t.task_id,
    t.span_type                                                              AS framework,
    if(t.StatusCode = 'STATUS_CODE_ERROR', 'FAILURE', 'SUCCESS')           AS outcome,
    t.StatusMessage,
    t.tool_errors,
    t.error_rate_pct,
    r.last_stop_reason,
    r.max_tokens_hits,
    multiIf(
        t.StatusCode = 'STATUS_CODE_ERROR' AND t.StatusMessage != '',       t.StatusMessage,
        t.StatusCode = 'STATUS_CODE_ERROR' AND r.max_tokens_hits > 0,       'context_window_exhausted',
        t.StatusCode = 'STATUS_CODE_ERROR' AND t.tool_errors > 0,           'tool_execution_errors',
        t.StatusCode = 'STATUS_CODE_ERROR',                                  'agent_crashed',
        r.max_tokens_hits > 0,                                               'hit_max_tokens',
        t.tool_errors > 0,                                                   'had_tool_errors_recovered',
        r.last_stop_reason = 'end_turn',                                     'completed_normally',
        r.last_stop_reason = 'stop_sequence',                                'completed_stop_sequence',
        t.span_type = 'invoke_agent Strands Agents',                         'strands_completed',
        t.span_type = 'AgentExecutor.workflow',                              'langchain_completed',
        'unknown'
    )                                                                        AS reason
FROM all_tasks t
LEFT JOIN claude_turn_reasons r ON t.task_id = r.session_id
ORDER BY t.agent_id, outcome, t.error_rate_pct DESC;


-- ── 3. P95 / P99 Latency — Task, Step, Tool ───────────────────────────────────

-- Task-level latency
SELECT
    coalesce(
        nullIf(SpanAttributes['agent.id'], ''),
        nullIf(ResourceAttributes['routeiq.agent_id'], ''),
        ServiceName
    )                                                                        AS agent_id,
    SpanName                                                                 AS framework,
    count()                                                                  AS task_count,
    round(avg(if(
        SpanName = 'session:summary',
        toFloat64OrDefault(SpanAttributes['session.duration_s']),
        Duration / 1e9
    )), 2)                                                                   AS avg_s,
    round(quantile(0.50)(if(
        SpanName = 'session:summary',
        toFloat64OrDefault(SpanAttributes['session.duration_s']),
        Duration / 1e9
    )), 2)                                                                   AS p50_s,
    round(quantile(0.95)(if(
        SpanName = 'session:summary',
        toFloat64OrDefault(SpanAttributes['session.duration_s']),
        Duration / 1e9
    )), 2)                                                                   AS p95_s,
    round(quantile(0.99)(if(
        SpanName = 'session:summary',
        toFloat64OrDefault(SpanAttributes['session.duration_s']),
        Duration / 1e9
    )), 2)                                                                   AS p99_s
FROM otel_traces
WHERE
    SpanName = 'session:summary'
    OR (SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = '')
    OR (SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = '')
GROUP BY agent_id, framework
ORDER BY p95_s DESC;

-- Step/turn-level latency
SELECT
    coalesce(
        nullIf(SpanAttributes['agent.id'], ''),
        ServiceName
    )                                                                        AS agent_id,
    SpanName                                                                 AS step_type,
    count()                                                                  AS step_count,
    round(avg(if(
        SpanAttributes['turn.latency_ms'] != '',
        toFloat64OrDefault(SpanAttributes['turn.latency_ms']),
        Duration / 1e6
    )))                                                                      AS avg_ms,
    round(quantile(0.95)(if(
        SpanAttributes['turn.latency_ms'] != '',
        toFloat64OrDefault(SpanAttributes['turn.latency_ms']),
        Duration / 1e6
    )))                                                                      AS p95_ms,
    round(quantile(0.99)(if(
        SpanAttributes['turn.latency_ms'] != '',
        toFloat64OrDefault(SpanAttributes['turn.latency_ms']),
        Duration / 1e6
    )))                                                                      AS p99_ms
FROM otel_traces
WHERE SpanName IN ('llm:turn', 'execute_event_loop_cycle', 'chat')
GROUP BY agent_id, step_type
ORDER BY p95_ms DESC;

-- Tool-level latency
SELECT
    coalesce(
        nullIf(SpanAttributes['agent.id'], ''),
        ServiceName
    )                                                                        AS agent_id,
    coalesce(
        nullIf(SpanAttributes['gen_ai.tool.name'], ''),
        nullIf(SpanAttributes['tool.name'], ''),
        SpanName
    )                                                                        AS tool_name,
    count()                                                                  AS call_count,
    round(avg(Duration / 1e6))                                              AS avg_ms,
    round(quantile(0.95)(Duration / 1e6))                                   AS p95_ms,
    round(quantile(0.99)(Duration / 1e6))                                   AS p99_ms
FROM otel_traces
WHERE
    SpanName = 'tool.call'
    OR SpanName LIKE 'tool:%'
GROUP BY agent_id, tool_name
ORDER BY p95_ms DESC;


-- ── 4. Cost per Successful Task ───────────────────────────────────────────────

-- Per-task cost (successful tasks only)
SELECT
    coalesce(
        nullIf(SpanAttributes['agent.id'], ''),
        nullIf(ResourceAttributes['routeiq.agent_id'], ''),
        ServiceName
    )                                                                        AS agent_id,
    coalesce(nullIf(SpanAttributes['session.id'], ''), TraceId)             AS task_id,
    SpanName                                                                 AS framework,
    toFloat64OrDefault(SpanAttributes['session.cost_usd'])                  AS cost_usd,
    toInt64OrDefault(coalesce(
        nullIf(SpanAttributes['gen_ai.usage.input_tokens'], ''),
        SpanAttributes['gen_ai.usage.prompt_tokens']
    ))                                                                       AS input_tokens,
    toInt64OrDefault(coalesce(
        nullIf(SpanAttributes['gen_ai.usage.output_tokens'], ''),
        SpanAttributes['gen_ai.usage.completion_tokens']
    ))                                                                       AS output_tokens,
    toInt64OrDefault(SpanAttributes['gen_ai.usage.total_tokens'])           AS total_tokens,
    round(Duration / 1e9, 2)                                                AS duration_s,
    SpanAttributes['gen_ai.request.model']                                  AS model,
    Timestamp
FROM otel_traces
WHERE (
    SpanName = 'session:summary'
    OR (SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = '')
    OR (SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = '')
)
AND StatusCode != 'STATUS_CODE_ERROR'
ORDER BY cost_usd DESC;

-- Aggregated per agent
SELECT
    coalesce(
        nullIf(SpanAttributes['agent.id'], ''),
        nullIf(ResourceAttributes['routeiq.agent_id'], ''),
        ServiceName
    )                                                                        AS agent_id,
    count()                                                                  AS successful_tasks,
    round(sum(toFloat64OrDefault(SpanAttributes['session.cost_usd'])), 4)   AS total_cost_usd,
    round(avg(toFloat64OrDefault(SpanAttributes['session.cost_usd'])), 4)   AS avg_cost_per_task,
    round(quantile(0.95)(toFloat64OrDefault(SpanAttributes['session.cost_usd'])), 4) AS p95_cost_usd,
    sum(toInt64OrDefault(SpanAttributes['gen_ai.usage.total_tokens']))      AS total_tokens
FROM otel_traces
WHERE (
    SpanName = 'session:summary'
    OR (SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = '')
    OR (SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = '')
)
AND StatusCode != 'STATUS_CODE_ERROR'
GROUP BY agent_id
ORDER BY total_cost_usd DESC;


-- ── 5. Loop Detection ─────────────────────────────────────────────────────────

-- Claude Code: explicit loop flag
SELECT
    'claude-code'                                                            AS agent_id,
    SpanAttributes['claude_code.session.id']                                AS task_id,
    SpanAttributes['gen_ai.tool.name']                                      AS tool_name,
    count()                                                                  AS total_calls,
    countIf(SpanAttributes['claude_code.tool.loop_detected'] = 'true')      AS explicit_loop_count,
    max(toInt32OrDefault(SpanAttributes['claude_code.tool.same_tool_count'])) AS max_consecutive
FROM otel_traces
WHERE SpanName = 'tool.call'
  AND (
      SpanAttributes['claude_code.tool.loop_detected'] = 'true'
      OR toInt32OrDefault(SpanAttributes['claude_code.tool.same_tool_count']) >= 3
  )
GROUP BY task_id, tool_name

UNION ALL

-- All frameworks: detect loops via repeated same-span tool calls within a trace
SELECT
    ServiceName                                                              AS agent_id,
    TraceId                                                                  AS task_id,
    SpanName                                                                 AS tool_name,
    count()                                                                  AS total_calls,
    0                                                                        AS explicit_loop_count,
    count()                                                                  AS max_consecutive
FROM otel_traces
WHERE SpanName LIKE 'tool:%'
  AND ServiceName != 'claude-code'
GROUP BY ServiceName, TraceId, SpanName
HAVING count() >= 3

ORDER BY explicit_loop_count DESC, max_consecutive DESC;


-- ── 6. Silent Failures ────────────────────────────────────────────────────────

SELECT
    coalesce(
        nullIf(SpanAttributes['agent.id'], ''),
        nullIf(ResourceAttributes['routeiq.agent_id'], ''),
        ServiceName
    )                                                                        AS agent_id,
    coalesce(nullIf(SpanAttributes['session.id'], ''), TraceId)             AS task_id,
    SpanName                                                                 AS framework,
    StatusCode,
    toInt64OrDefault(SpanAttributes['session.tool_errors'])                  AS tool_errors,
    toFloat64OrDefault(SpanAttributes['session.error_rate_pct'])             AS error_rate_pct,
    toInt64OrDefault(SpanAttributes['session.tool_calls'])                   AS tool_calls,
    toInt64OrDefault(SpanAttributes['session.assistant_turns'])              AS assistant_turns,
    round(Duration / 1e9, 2)                                                 AS duration_s,
    multiIf(
        toInt64OrDefault(SpanAttributes['session.tool_errors']) > 0
            AND StatusCode != 'STATUS_CODE_ERROR',                           'unreported_tool_errors',
        toInt64OrDefault(SpanAttributes['session.tool_calls']) = 0
            AND toInt64OrDefault(SpanAttributes['session.assistant_turns']) > 2,
                                                                             'no_tools_used',
        Duration / 1e9 < 5
            AND toFloat64OrDefault(SpanAttributes['session.cost_usd']) > 0,  'suspiciously_fast',
        toFloat64OrDefault(SpanAttributes['session.error_rate_pct']) > 0
            AND StatusCode != 'STATUS_CODE_ERROR',                           'hidden_error_rate',
        SpanName = 'AgentExecutor.workflow'
            AND StatusCode  = 'STATUS_CODE_UNSET'
            AND (SpanAttributes['traceloop.entity.output'] = ''
                 OR SpanAttributes['traceloop.entity.output'] = '{}'),       'empty_output',
        'not_silent_failure'
    )                                                                        AS silent_failure_type
FROM otel_traces
WHERE (
    SpanName = 'session:summary'
    OR (SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = '')
    OR (SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = '')
)
AND StatusCode != 'STATUS_CODE_ERROR'
AND (
    toInt64OrDefault(SpanAttributes['session.tool_errors']) > 0
    OR (toInt64OrDefault(SpanAttributes['session.tool_calls']) = 0
        AND toInt64OrDefault(SpanAttributes['session.assistant_turns']) > 2)
    OR (Duration / 1e9 < 5 AND toFloat64OrDefault(SpanAttributes['session.cost_usd']) > 0)
    OR toFloat64OrDefault(SpanAttributes['session.error_rate_pct']) > 0
    OR (SpanName = 'AgentExecutor.workflow'
        AND (SpanAttributes['traceloop.entity.output'] = ''
             OR SpanAttributes['traceloop.entity.output'] = '{}'))
    OR coalesce(nullIf(SpanAttributes['session.id'], ''), TraceId) IN (
        SELECT SpanAttributes['session.id']
        FROM otel_traces
        WHERE SpanName = 'llm:turn'
          AND SpanAttributes['turn.stop_reason'] = 'max_tokens'
    )
)
ORDER BY agent_id, error_rate_pct DESC;


-- ── 7. Human Escalation Count ─────────────────────────────────────────────────

-- Per-task
SELECT
    coalesce(
        nullIf(SpanAttributes['agent.id'], ''),
        nullIf(ResourceAttributes['routeiq.agent_id'], ''),
        ServiceName
    )                                                                        AS agent_id,
    coalesce(nullIf(SpanAttributes['session.id'], ''), TraceId)             AS task_id,
    SpanName                                                                 AS framework,
    toInt64OrDefault(SpanAttributes['session.human_turns'])                  AS human_turns,
    toInt64OrDefault(SpanAttributes['session.assistant_turns'])              AS assistant_turns,
    if(StatusCode = 'STATUS_CODE_ERROR', 'FAILURE', 'SUCCESS')              AS outcome,
    multiIf(
        toInt64OrDefault(SpanAttributes['session.human_turns']) <= 1,  'single_prompt',
        toInt64OrDefault(SpanAttributes['session.human_turns']) <= 3,  'light_guidance',
        toInt64OrDefault(SpanAttributes['session.human_turns']) <= 7,  'moderate_escalation',
        toInt64OrDefault(SpanAttributes['session.human_turns']) > 7,   'heavy_escalation',
        'n/a'
    )                                                                        AS escalation_tier
FROM otel_traces
WHERE
    SpanName = 'session:summary'
    OR (SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = '')
    OR (SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = '')
ORDER BY human_turns DESC;

-- Aggregated per agent
SELECT
    coalesce(
        nullIf(SpanAttributes['agent.id'], ''),
        nullIf(ResourceAttributes['routeiq.agent_id'], ''),
        ServiceName
    )                                                                        AS agent_id,
    count()                                                                  AS total_tasks,
    sum(toInt64OrDefault(SpanAttributes['session.human_turns']))             AS total_human_turns,
    round(avg(toInt64OrDefault(SpanAttributes['session.human_turns'])), 2)  AS avg_human_turns,
    countIf(toInt64OrDefault(SpanAttributes['session.human_turns']) > 3)    AS heavily_escalated,
    round(
        100.0 * countIf(toInt64OrDefault(SpanAttributes['session.human_turns']) > 3) / count(),
        2
    )                                                                        AS escalation_rate_pct
FROM otel_traces
WHERE
    SpanName = 'session:summary'
    OR (SpanName = 'invoke_agent Strands Agents' AND ParentSpanId = '')
    OR (SpanName = 'AgentExecutor.workflow'       AND ParentSpanId = '')
GROUP BY agent_id
ORDER BY escalation_rate_pct DESC;


-- ── 8. Retries ────────────────────────────────────────────────────────────────

SELECT
    coalesce(
        nullIf(SpanAttributes['agent.id'], ''),
        ServiceName
    )                                                                        AS agent_id,
    coalesce(
        nullIf(SpanAttributes['claude_code.session.id'], ''),
        TraceId
    )                                                                        AS task_id,
    coalesce(
        nullIf(SpanAttributes['gen_ai.tool.name'], ''),
        nullIf(SpanAttributes['tool.name'], ''),
        SpanName
    )                                                                        AS tool_name,
    count()                                                                  AS total_invocations,
    max(toInt32OrDefault(SpanAttributes['claude_code.tool.same_tool_count'])) AS max_consecutive_retries,
    countIf(
        SpanAttributes['claude_code.tool.success'] = 'false'
        OR StatusCode = 'STATUS_CODE_ERROR'
    )                                                                        AS failed_attempts,
    countIf(
        SpanAttributes['claude_code.tool.success'] = 'true'
        OR StatusCode = 'STATUS_CODE_OK'
    )                                                                        AS successful_attempts,
    if(
        countIf(SpanAttributes['claude_code.tool.success'] = 'false'
                OR StatusCode = 'STATUS_CODE_ERROR') > 0
        AND countIf(SpanAttributes['claude_code.tool.success'] = 'true'
                    OR StatusCode = 'STATUS_CODE_OK') > 0,
        'recovered', 'persistent_failure'
    )                                                                        AS retry_outcome
FROM otel_traces
WHERE
    SpanName = 'tool.call'
    OR SpanName LIKE 'tool:%'
GROUP BY agent_id, task_id, tool_name
HAVING max_consecutive_retries > 1 OR (total_invocations > 2 AND failed_attempts > 0)
ORDER BY max_consecutive_retries DESC, failed_attempts DESC;
