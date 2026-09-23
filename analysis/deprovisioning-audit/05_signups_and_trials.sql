-- STEP 5 — Top-of-funnel context: weekly new signups and trial conversions, 90 days.
-- Read-only. BigQuery, location EU, project lesko-486515.
--
-- Recurly from raw webhooks (wh_recurly). PayPal / ClickBank signups are shown from
-- fct_signups as a context column only (derived, not used for any state judgement).
--
-- TRIAL CONVERSION — a subscription whose trial_ends_at falls in the week (and has passed),
-- converted when a successful charge > $1 lands in [trial_ends_at - 1 day, trial_ends_at + 14 days]
-- (14 days lets a dunning recovery count). Alternatives for tying the charge to the trial:
--   STRICT  the charge's transaction names the trial's subscription UUID       <- HEADLINE
--   LOOSE   any charge > $1 on the same account email in the window (also counts a second,
--           unrelated subscription on that address, so it can overstate conversion)
-- Trials ending in the last 14 days are reported as `trials_open`, not in the rate.

DECLARE since TIMESTAMP DEFAULT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY);

CREATE TEMP TABLE wh AS
SELECT
  event_id, received_at, event_type,
  LOWER(TRIM(REGEXP_EXTRACT(acct, r'<email>([^<]*)</email>')))                        AS email,
  COALESCE(REGEXP_EXTRACT(sub, r'<uuid>([^<]*)</uuid>'),
           REGEXP_EXTRACT(txn, r'<subscription_id>([^<]*)</subscription_id>'))         AS sub_uuid,
  REGEXP_EXTRACT(sub, r'<plan_code>([^<]*)</plan_code>')                              AS plan_code,
  SAFE_CAST(REGEXP_EXTRACT(sub, r'<activated_at[^>]*>([^<]*)</activated_at>') AS TIMESTAMP) AS activated_at,
  SAFE_CAST(REGEXP_EXTRACT(sub, r'<trial_ends_at[^>]*>([^<]*)<') AS TIMESTAMP)            AS trial_ends_at,
  SAFE_CAST(REGEXP_EXTRACT(txn, r'<amount_in_cents[^>]*>([^<]*)<') AS NUMERIC) / 100      AS txn_amount
FROM (
  SELECT event_id, received_at, event_type,
    REGEXP_EXTRACT(raw_payload, r'(?s)<account>.*?</account>')           AS acct,
    REGEXP_EXTRACT(raw_payload, r'(?s)<subscription>.*?</subscription>') AS sub,
    REGEXP_EXTRACT(raw_payload, r'(?s)<transaction>.*?</transaction>')   AS txn
  FROM `lesko-486515.provisioning.wh_recurly`
  WHERE COALESCE(signature_valid, FALSE) AND NOT COALESCE(is_test, FALSE)
  QUALIFY ROW_NUMBER() OVER (PARTITION BY event_id ORDER BY received_at DESC) = 1
);

-- ═══ 5a. weekly new signups ═════════════════════════════════════════════════
WITH rec AS (
  SELECT sub_uuid, ANY_VALUE(email) AS email, MIN(received_at) AS signed_up_at,
         LOGICAL_OR(trial_ends_at IS NOT NULL) AS with_trial
  FROM wh
  WHERE event_type = 'new_subscription_notification' AND sub_uuid IS NOT NULL
  GROUP BY sub_uuid
  HAVING MIN(received_at) >= since
),
other_rails AS (
  SELECT DATE_TRUNC(DATE(received_at), WEEK(MONDAY)) AS week, rail,
         COUNT(DISTINCT subscription_id) AS n
  FROM `lesko-486515.provisioning_models.fct_signups`
  WHERE rail IN ('paypal', 'clickbank') AND received_at >= since
  GROUP BY 1, 2
)
SELECT
  w.week,
  w.recurly_signups,
  w.recurly_with_trial,
  w.recurly_no_trial,
  w.recurly_new_emails,
  COALESCE(pp.n, 0)                                       AS paypal_signups_ctx,
  COALESCE(cb.n, 0)                                       AS clickbank_signups_ctx,
  w.recurly_signups + COALESCE(pp.n, 0) + COALESCE(cb.n, 0) AS all_rails,
  ROUND(100 * w.recurly_signups / NULLIF(w.recurly_signups + COALESCE(pp.n, 0) + COALESCE(cb.n, 0), 0), 1)
                                                          AS pct_recurly
FROM (
  SELECT DATE_TRUNC(DATE(signed_up_at), WEEK(MONDAY)) AS week,
         COUNT(*)                                     AS recurly_signups,
         COUNTIF(with_trial)                          AS recurly_with_trial,
         COUNTIF(NOT with_trial)                      AS recurly_no_trial,
         COUNT(DISTINCT email)                        AS recurly_new_emails
  FROM rec GROUP BY 1
) w
LEFT JOIN other_rails pp ON pp.week = w.week AND pp.rail = 'paypal'
LEFT JOIN other_rails cb ON cb.week = w.week AND cb.rail = 'clickbank'
ORDER BY w.week;

-- ═══ 5b. weekly trial conversions (by week the trial ENDED) ═══════════════════
WITH trials AS (
  SELECT sub_uuid, ANY_VALUE(email) AS email, MAX(trial_ends_at) AS trial_ends_at
  FROM wh
  WHERE sub_uuid IS NOT NULL AND trial_ends_at IS NOT NULL
  GROUP BY sub_uuid
  HAVING MAX(trial_ends_at) >= since AND MAX(trial_ends_at) <= CURRENT_TIMESTAMP()
),
charges AS (
  SELECT email, sub_uuid, received_at AS paid_at
  FROM wh
  WHERE event_type = 'successful_payment_notification' AND txn_amount > 1
),
trial_cancels AS (
  SELECT DISTINCT tr.sub_uuid
  FROM trials tr
  JOIN wh x ON x.sub_uuid = tr.sub_uuid
           AND x.event_type = 'canceled_subscription_notification'
           AND x.received_at < tr.trial_ends_at
),
t AS (
  SELECT tr.sub_uuid, tr.trial_ends_at,
    tr.trial_ends_at <= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 14 DAY) AS matured,
    LOGICAL_OR(c.sub_uuid = tr.sub_uuid) AS conv_strict,
    LOGICAL_OR(c.paid_at IS NOT NULL)    AS conv_loose,
    LOGICAL_OR(tc.sub_uuid IS NOT NULL)  AS cancelled_in_trial
  FROM trials tr
  LEFT JOIN trial_cancels tc ON tc.sub_uuid = tr.sub_uuid
  LEFT JOIN charges c
    ON c.email = tr.email
   AND c.paid_at BETWEEN TIMESTAMP_SUB(tr.trial_ends_at, INTERVAL 1 DAY)
                     AND TIMESTAMP_ADD(tr.trial_ends_at, INTERVAL 14 DAY)
  GROUP BY tr.sub_uuid, tr.trial_ends_at
)
SELECT
  DATE_TRUNC(DATE(trial_ends_at), WEEK(MONDAY))                        AS week_trial_ended,
  COUNT(*)                                                             AS trials_ended,
  COUNTIF(NOT matured)                                                 AS trials_open,
  COUNTIF(matured)                                                     AS trials_matured,
  COUNTIF(matured AND cancelled_in_trial)                              AS cancelled_during_trial,
  COUNTIF(matured AND conv_strict)                                     AS converted,
  ROUND(100 * COUNTIF(matured AND conv_strict) / NULLIF(COUNTIF(matured), 0), 1) AS conversion_pct,
  COUNTIF(matured AND conv_loose)                                      AS converted_loose,
  ROUND(100 * COUNTIF(matured AND conv_loose)  / NULLIF(COUNTIF(matured), 0), 1) AS conversion_pct_loose
FROM t
GROUP BY ROLLUP (week_trial_ended)
ORDER BY week_trial_ended NULLS LAST;
