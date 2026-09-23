-- STEP 1 — Where deprovision / exit-cancel actions are logged, and how many in 90 days.
-- Read-only. Run in BigQuery, location EU, project lesko-486515.
--
-- Logs (DDL: lesko-provisioning/sql/05_deprovision_tables.sql, sql/02_exit_tables.sql):
--   lesko-486515.provisioning.deprovision_log     (lesko-deprovisioner)
--   lesko-486515.provisioning.exit_executor_log   (lesko-exit-canceller)
--   timestamp = acted_at, member key = member_id (MN member id, INT64)
--   a row is a real external write only when acted = TRUE
-- Cross-check: lesko-486515.provisioning.api_call_log (every outbound rail call, all services,
--   including lesko-dunning-executor, which writes neither log above).

DECLARE since TIMESTAMP DEFAULT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY);

-- 1a. every log row in the window, by worker x action
WITH acts AS (
  SELECT 'lesko-deprovisioner' AS worker, rail, action, acted, dry_run, result, member_id, acted_at
  FROM `lesko-486515.provisioning.deprovision_log`
  WHERE acted_at >= since
  UNION ALL
  SELECT 'lesko-exit-canceller', rail, action, acted, dry_run, result, member_id, acted_at
  FROM `lesko-486515.provisioning.exit_executor_log`
  WHERE acted_at >= since
)
SELECT
  worker, rail, action,
  COUNTIF(acted)                                                  AS acted_rows,
  COUNT(DISTINCT IF(acted, member_id, NULL))                      AS acted_members,
  ROUND(100 * COUNTIF(acted) / NULLIF(SUM(COUNTIF(acted)) OVER (), 0), 1) AS pct_of_all_acted,
  COUNTIF(NOT acted AND result = 'dry_run')                       AS dry_run_rows,
  COUNTIF(NOT acted AND STARTS_WITH(result, 'skip'))              AS skip_rows,
  COUNTIF(NOT acted AND (result LIKE '%error%' OR STARTS_WITH(result, 'blocked')))
                                                                  AS error_rows,
  MIN(IF(acted, acted_at, NULL))                                  AS first_acted_at,
  MAX(IF(acted, acted_at, NULL))                                  AS last_acted_at
FROM acts
GROUP BY worker, rail, action
ORDER BY worker, acted_rows DESC;

-- 1b. reconciliation: every successful member-affecting write in api_call_log, by service.
-- Anything here from a service other than the two workers above is an action path the two
-- logs do not cover (e.g. lesko-dunning-executor 'mark_failed+cancel', keyed by invoice number).
SELECT
  service, rail, action,
  COUNT(*)                                                        AS ok_calls,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                AS pct_of_total,
  MIN(called_at) AS first_call, MAX(called_at) AS last_call
FROM `lesko-486515.provisioning.api_call_log`
WHERE called_at >= since
  AND outcome = 'ok'
  AND (action LIKE '%cancel%' OR action LIKE '%mark_failed%' OR action = 'mark_invoice_failed'
       OR action = 'remove_from_network')
GROUP BY service, rail, action
ORDER BY ok_calls DESC;

-- 1c. the one removal path that writes NO log: the Zapier zap 'MEMBER CANCEL - RECURLY'
-- [295178856] bans in MN straight off a Recurly expired_subscription_notification.
-- lesko-provisioning/README.md still lists "Disable zap 295178856" as an open checkbox.
-- Its signature is an MN departure within 60 s of an expiry on the same address.
-- Weekly count; non-zero in recent weeks = the zap (or something like it) is still removing people.
WITH expiries AS (
  SELECT received_at,
         LOWER(TRIM(REGEXP_EXTRACT(REGEXP_EXTRACT(raw_payload, r'(?s)<account>.*?</account>'),
                                   r'<email>([^<]*)</email>'))) AS email
  FROM `lesko-486515.provisioning.wh_recurly`
  WHERE event_type = 'expired_subscription_notification'
    AND received_at >= TIMESTAMP_SUB(since, INTERVAL 1 DAY)
    AND COALESCE(signature_valid, FALSE)
),
leaves AS (
  SELECT received_at, SAFE_CAST(customer_id AS INT64) AS member_id, LOWER(TRIM(payer_email)) AS email
  FROM `lesko-486515.provisioning.wh_mn`
  WHERE event_type = 'MemberLeftHook' AND received_at >= since
)
SELECT
  DATE_TRUNC(DATE(l.received_at), WEEK(MONDAY))                   AS week,
  COUNT(DISTINCT l.member_id)                                     AS mn_leaves_total,
  COUNT(DISTINCT IF(e.email IS NOT NULL, l.member_id, NULL))      AS leaves_within_60s_of_recurly_expiry,
  ROUND(100 * COUNT(DISTINCT IF(e.email IS NOT NULL, l.member_id, NULL))
            / COUNT(DISTINCT l.member_id), 1)                     AS pct
FROM leaves l
LEFT JOIN expiries e
  ON e.email = l.email
 AND l.received_at BETWEEN e.received_at AND TIMESTAMP_ADD(e.received_at, INTERVAL 60 SECOND)
GROUP BY week
ORDER BY week;
