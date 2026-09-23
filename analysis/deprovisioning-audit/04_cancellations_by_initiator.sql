-- STEP 4 — Recurly cancellations per week, 90 days, split by who initiated.
-- Read-only. BigQuery, location EU, project lesko-486515. Raw webhooks only.
--
-- INITIATOR RULES
--   api              one of OUR services made a successful Recurly cancel / mark_failed call
--                    for this subscription (api_call_log, outcome='ok'). Services that do this:
--                    lesko-exit-canceller (cancel_subscription, mark_invoice_failed) and
--                    lesko-dunning-executor ('mark_failed+cancel', target = invoice number).
--   dunning_expiry   expired_subscription_notification after Recurly's retries ran out
--                    (final dunning event, or a failed payment with no success since), not api
--   customer_or_admin canceled_subscription_notification that is not api. Recurly v2 webhooks do
--                    NOT distinguish self-service from a staff cancel in the Recurly admin UI,
--                    so those two cannot be separated from this data.
--   expiry_after_cancel  the expiry that ends an EARLIER cancel's paid period — the tail of a
--                    cancellation already counted, reported but excluded from the total
--   expiry_other     non-renewing / fixed-term expiry with no payment failure and no cancel
--
-- JOIN KEY FOR "api" — api_call_log.target_id is the v3 short id (exit-canceller) or an
-- invoice number (dunning-executor); webhooks carry the 32-hex UUID. Alternatives:
--   STRICT  v3 id -> UUID via recurly_subscriptions_raw.sub_id / recurly_live_probe, same sub,
--           call within 15 min before the webhook                    <- HEADLINE (conservative)
--   LOOSE   api_call_log.subject (the payer email) = webhook account email, call within 15 min
--           before the webhook. Catches the dunning-executor (invoice-keyed) and unmapped v3
--           ids, but could attribute a customer's own cancel to us if both happen in 15 min.
-- A cancel matched LOOSE but not STRICT is reported in its own column, not in `api`.
--
-- FLAG: api-initiated cancels where the subscription was NOT past due first
--   = no failed payment since the last successful one, and no final dunning, as of the call.
--   For the exit-canceller this is expected (it cancels good-standing subs of members who left
--   MN); the flag matters when the "leave" was not a real leave — see zap_like_ban.

DECLARE since TIMESTAMP DEFAULT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY);

CREATE TEMP TABLE wh AS
SELECT
  event_id, received_at, event_type,
  LOWER(TRIM(REGEXP_EXTRACT(acct, r'<email>([^<]*)</email>')))                        AS email,
  COALESCE(REGEXP_EXTRACT(sub, r'<uuid>([^<]*)</uuid>'),
           REGEXP_EXTRACT(txn, r'<subscription_id>([^<]*)</subscription_id>'))         AS sub_uuid,
  SAFE_CAST(REGEXP_EXTRACT(inv, r'<final_dunning_event[^>]*>([^<]*)<') AS BOOL)           AS dunning_final
FROM (
  SELECT event_id, received_at, event_type,
    REGEXP_EXTRACT(raw_payload, r'(?s)<account>.*?</account>')           AS acct,
    REGEXP_EXTRACT(raw_payload, r'(?s)<subscription>.*?</subscription>') AS sub,
    REGEXP_EXTRACT(raw_payload, r'(?s)<transaction>.*?</transaction>')   AS txn,
    REGEXP_EXTRACT(raw_payload, r'(?s)<invoice>.*?</invoice>')           AS inv
  FROM `lesko-486515.provisioning.wh_recurly`
  WHERE COALESCE(signature_valid, FALSE) AND NOT COALESCE(is_test, FALSE)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY received_at DESC) = 1
);

CREATE TEMP TABLE v3map AS
SELECT DISTINCT v3_id, sub_uuid FROM (
  SELECT sub_id AS v3_id, sub_uuid
  FROM `lesko-486515.member_ledger_archive.recurly_subscriptions_raw` WHERE sub_id IS NOT NULL
  UNION ALL
  SELECT subscription_v3_id, subscription_id
  FROM `lesko-486515.provisioning.recurly_live_probe`
  WHERE subscription_v3_id IS NOT NULL AND subscription_id IS NOT NULL
);

CREATE TEMP TABLE api AS
SELECT c.called_at, c.service, c.action, c.target_id,
       LOWER(TRIM(c.subject)) AS subject_email, m.sub_uuid
FROM `lesko-486515.provisioning.api_call_log` c
LEFT JOIN v3map m ON m.v3_id = c.target_id
WHERE c.rail = 'recurly' AND c.outcome = 'ok'
  AND (c.action LIKE '%cancel%' OR c.action LIKE '%mark_failed%' OR c.action = 'mark_invoice_failed')
  AND c.called_at >= TIMESTAMP_SUB(since, INTERVAL 1 DAY);

-- one row per (subscription, event type): first occurrence in the window
CREATE TEMP TABLE ev AS
SELECT event_id, received_at, event_type, email, sub_uuid
FROM wh
WHERE event_type IN ('canceled_subscription_notification', 'expired_subscription_notification')
  AND received_at >= since
QUALIFY ROW_NUMBER() OVER (PARTITION BY COALESCE(sub_uuid, event_id), event_type
                           ORDER BY received_at) = 1;

CREATE TEMP TABLE ev_class AS
WITH standing AS (
  SELECT e.event_id,
    MAX(IF(w.event_type = 'successful_payment_notification', w.received_at, NULL)) AS last_ok,
    MAX(IF(w.event_type = 'failed_payment_notification',     w.received_at, NULL)) AS last_fail,
    MAX(IF(w.event_type = 'new_dunning_event_notification' AND w.dunning_final,
           w.received_at, NULL))                                                  AS last_final
  FROM ev e
  JOIN wh w ON w.email = e.email AND w.received_at < e.received_at
           AND (w.sub_uuid = e.sub_uuid OR w.sub_uuid IS NULL)
           AND w.event_type IN ('successful_payment_notification', 'failed_payment_notification',
                                'new_dunning_event_notification')
  GROUP BY 1
),
prior_cancel AS (
  SELECT DISTINCT e.event_id
  FROM ev e
  JOIN wh w ON w.sub_uuid = e.sub_uuid AND w.event_type = 'canceled_subscription_notification'
           AND w.received_at < e.received_at
  WHERE e.event_type = 'expired_subscription_notification'
),
api_match AS (
  SELECT e.event_id,
    LOGICAL_OR(a.sub_uuid = e.sub_uuid)                                     AS api_strict,
    LOGICAL_OR(a.subject_email = e.email)                                   AS api_loose,
    MIN(a.called_at)                                                        AS api_called_at,
    STRING_AGG(DISTINCT a.service)                                          AS api_services
  FROM ev e
  JOIN api a ON (a.sub_uuid = e.sub_uuid OR a.subject_email = e.email)
            AND a.called_at BETWEEN TIMESTAMP_SUB(e.received_at, INTERVAL 15 MINUTE) AND e.received_at
  GROUP BY 1
)
SELECT e.*, s.last_ok, s.last_fail, s.last_final,
  COALESCE(am.api_strict, FALSE) AS api_strict,
  COALESCE(am.api_loose,  FALSE) AS api_loose,
  am.api_called_at, am.api_services,
  -- past due AS OF the moment of the call (or of the webhook when there was no call)
  COALESCE(s.last_fail  > COALESCE(s.last_ok, TIMESTAMP '1970-01-01'), FALSE)
    OR COALESCE(s.last_final > COALESCE(s.last_ok, TIMESTAMP '1970-01-01'), FALSE) AS was_past_due,
  CASE
    WHEN COALESCE(am.api_strict, FALSE) THEN 'api'
    WHEN COALESCE(am.api_loose,  FALSE) THEN 'api_loose_only'
    WHEN e.event_type = 'canceled_subscription_notification' THEN 'customer_or_admin'
    WHEN pc.event_id IS NOT NULL THEN 'expiry_after_cancel'
    WHEN COALESCE(s.last_final > COALESCE(s.last_ok, TIMESTAMP '1970-01-01'), FALSE)
      OR COALESCE(s.last_fail  > COALESCE(s.last_ok, TIMESTAMP '1970-01-01'), FALSE)
      THEN 'dunning_expiry'
    ELSE 'expiry_other'
  END AS initiator
FROM ev e
LEFT JOIN standing     s  USING (event_id)
LEFT JOIN prior_cancel pc USING (event_id)
LEFT JOIN api_match    am USING (event_id);

-- ═══ STEP 4 OUTPUT — per week ════════════════════════════════════════════════
-- total excludes expiry_after_cancel (already counted at the cancel)
SELECT
  DATE_TRUNC(DATE(received_at), WEEK(MONDAY))                          AS week,
  COUNTIF(initiator != 'expiry_after_cancel')                          AS cancellations,
  COUNTIF(initiator = 'customer_or_admin')                             AS customer_or_admin,
  COUNTIF(initiator = 'dunning_expiry')                                AS dunning_expiry,
  COUNTIF(initiator = 'api')                                           AS api,
  COUNTIF(initiator = 'api_loose_only')                                AS api_loose_only,
  COUNTIF(initiator = 'expiry_other')                                  AS expiry_other,
  ROUND(100 * COUNTIF(initiator = 'customer_or_admin') / NULLIF(COUNTIF(initiator != 'expiry_after_cancel'), 0), 1) AS pct_customer,
  ROUND(100 * COUNTIF(initiator = 'dunning_expiry')    / NULLIF(COUNTIF(initiator != 'expiry_after_cancel'), 0), 1) AS pct_dunning,
  ROUND(100 * COUNTIF(initiator = 'api')               / NULLIF(COUNTIF(initiator != 'expiry_after_cancel'), 0), 1) AS pct_api,
  COUNTIF(initiator = 'api' AND NOT was_past_due)                      AS FLAG_api_not_past_due,
  COUNTIF(initiator = 'api_loose_only' AND NOT was_past_due)           AS flag_api_loose_not_past_due,
  COUNTIF(initiator = 'expiry_after_cancel')                           AS memo_expiry_after_cancel
FROM ev_class
GROUP BY ROLLUP (week)
ORDER BY week NULLS LAST;

-- ═══ STEP 4 FLAG DETAIL — api cancels on a sub that was NOT past due ═══════════
-- zap_like_ban: for exit-canceller cancels, whether the member's MN "leave" came <= 5 min
-- after a Recurly expiry on the same address (the Zapier ban signature), i.e. the leave that
-- triggered this cancel may not have been the member's choice.
SELECT
  c.received_at, c.event_type, c.email, c.sub_uuid, c.api_services, c.api_called_at,
  c.last_ok, c.last_fail, c.last_final,
  EXISTS (
    SELECT 1
    FROM `lesko-486515.provisioning.exit_executor_log` x
    JOIN wh w2 ON w2.email = LOWER(TRIM(x.payer_email))
              AND w2.event_type = 'expired_subscription_notification'
              AND w2.received_at BETWEEN TIMESTAMP_SUB(x.left_at, INTERVAL 5 MINUTE) AND x.left_at
    WHERE x.acted AND x.rail = 'recurly' AND x.action = 'cancel_subscription'
      AND LOWER(TRIM(x.payer_email)) = c.email
      AND x.acted_at BETWEEN TIMESTAMP_SUB(c.api_called_at, INTERVAL 5 MINUTE)
                         AND TIMESTAMP_ADD(c.api_called_at, INTERVAL 5 MINUTE)
  ) AS zap_like_ban
FROM ev_class c
WHERE c.initiator = 'api' AND NOT c.was_past_due
ORDER BY c.received_at DESC;
