-- STEPS 2 + 3 — Recurly subscription state AT THE MOMENT each action was taken, and whether
-- the member paid Recurly in the 30 days after.
-- Read-only (TEMP tables only). BigQuery, location EU, project lesko-486515.
--
-- RECURLY STATE COMES FROM RAW SOURCES ONLY, never from customer_state / payment_status:
--   * lesko-486515.provisioning.wh_recurly              raw webhook XML (from 2026-06-23),
--     parsed here with the same regexes as stg_recurly, filtered to events received <= acted_at
--   * lesko-486515.member_ledger_archive.recurly_subscriptions_raw   frozen June-2026 API
--     snapshot; used ONLY for a subscription with no webhook event before the action
--   * lesko-486515.provisioning.recurly_transactions    raw transaction feed (step 3)
--
-- JOIN KEY — the logs carry member_id, Recurly carries email / subscription id. Alternatives:
--   K1  the address the worker itself logged (deprovision_log.payer_email = the member's MN
--       sign-in email; exit_executor_log.payer_email = the address the Recurly account was
--       found under) + for exit cancels, the targeted subscription itself.  EXACT, no fuzzy
--       bridges.                                                    <- CONSERVATIVE / HEADLINE
--   K2  K1 + every payer address member_payer_live bridges to the member id (exact, fuzzy
--       June seed, Gmail-normalised and human-approved name matches). Wider; can over-match,
--       and its derived layer is rebuilt from the LIVE roster, so a member already removed
--       may have lost bridges (survivorship bias). Shown as a sensitivity column.
--   K3  exit-cancel target_id is Recurly's v3 short id ("yewj4ojyegbt"), NOT the 32-hex UUID
--       the webhooks key on. Mapped through recurly_subscriptions_raw.sub_id and
--       recurly_live_probe.subscription_v3_id; unmapped targets fall back to member level
--       and are counted in `target_unmapped`.
--   Not usable: recurly_live_probe rows written by the deprovisioner's gate carry no member_id
--   (only probe_reason 'deprovision:<rails>'), so they cannot be tied to a log row reliably.

DECLARE since TIMESTAMP DEFAULT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 90 DAY);

-- ── raw Recurly webhooks, parsed ─────────────────────────────────────────────
CREATE TEMP TABLE wh AS
SELECT
  event_id, received_at, event_type,
  LOWER(TRIM(REGEXP_EXTRACT(acct, r'<email>([^<]*)</email>')))                        AS email,
  COALESCE(REGEXP_EXTRACT(sub, r'<uuid>([^<]*)</uuid>'),
           REGEXP_EXTRACT(txn, r'<subscription_id>([^<]*)</subscription_id>'))         AS sub_uuid,
  REGEXP_EXTRACT(sub, r'<state>([^<]*)</state>')                                      AS sub_state,
  SAFE_CAST(REGEXP_EXTRACT(sub, r'<canceled_at[^>]*>([^<]*)</canceled_at>') AS TIMESTAMP) AS canceled_at,
  SAFE_CAST(REGEXP_EXTRACT(sub, r'<expires_at[^>]*>([^<]*)</expires_at>') AS TIMESTAMP)   AS expires_at,
  SAFE_CAST(REGEXP_EXTRACT(sub, r'<current_period_ends_at[^>]*>([^<]*)<') AS TIMESTAMP)   AS period_ends_at,
  SAFE_CAST(REGEXP_EXTRACT(txn, r'<amount_in_cents[^>]*>([^<]*)<') AS NUMERIC) / 100      AS txn_amount,
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

CREATE TEMP TABLE snap AS
SELECT LOWER(TRIM(email)) AS email, sub_uuid, sub_id AS sub_v3_id, sub_state,
       expires_at, current_period_ends_at AS period_ends_at
FROM `lesko-486515.member_ledger_archive.recurly_subscriptions_raw`
QUALIFY ROW_NUMBER() OVER (PARTITION BY sub_uuid ORDER BY current_period_ends_at DESC) = 1;

CREATE TEMP TABLE v3map AS
SELECT DISTINCT v3_id, sub_uuid FROM (
  SELECT sub_v3_id AS v3_id, sub_uuid FROM snap WHERE sub_v3_id IS NOT NULL
  UNION ALL
  SELECT subscription_v3_id, subscription_id
  FROM `lesko-486515.provisioning.recurly_live_probe`
  WHERE subscription_v3_id IS NOT NULL AND subscription_id IS NOT NULL
);

-- ── the actions (acted = TRUE only: real external writes) ────────────────────
CREATE TEMP TABLE actions AS
SELECT CONCAT('dep:', log_id) AS action_id, 'lesko-deprovisioner' AS worker,
       action, rail, member_id, acted_at, CAST(NULL AS TIMESTAMP) AS left_at,
       LOWER(TRIM(payer_email)) AS logged_email, CAST(NULL AS STRING) AS target_v3_id
FROM `lesko-486515.provisioning.deprovision_log`
WHERE acted AND action = 'remove_from_network' AND acted_at >= since
UNION ALL
SELECT CONCAT('exit:', log_id), 'lesko-exit-canceller', action, rail, member_id, acted_at, left_at,
       LOWER(TRIM(payer_email)),
       IF(rail = 'recurly' AND action = 'cancel_subscription', target_id, NULL)
FROM `lesko-486515.provisioning.exit_executor_log`
WHERE acted AND action IN ('cancel_subscription', 'cancel_rebill', 'mark_invoice_failed')
  AND acted_at >= since;

CREATE TEMP TABLE targets AS
SELECT a.action_id, a.target_v3_id, m.sub_uuid AS target_uuid
FROM actions a
LEFT JOIN v3map m ON m.v3_id = a.target_v3_id
WHERE a.target_v3_id IS NOT NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY a.action_id ORDER BY m.sub_uuid) = 1;

-- ── key addresses per action, per key set ────────────────────────────────────
CREATE TEMP TABLE key_rows AS
WITH k1 AS (
  SELECT action_id, logged_email AS email FROM actions WHERE logged_email IS NOT NULL
  UNION DISTINCT
  -- the account address on the targeted subscription (hint-found exit cancels log no email)
  SELECT t.action_id, w.email
  FROM targets t JOIN wh w ON w.sub_uuid = t.target_uuid AND w.email IS NOT NULL
  UNION DISTINCT
  SELECT t.action_id, s.email
  FROM targets t JOIN snap s ON s.sub_uuid = t.target_uuid AND s.email IS NOT NULL
)
SELECT action_id, 'K1' AS key_set, email FROM k1
UNION DISTINCT
SELECT action_id, 'K2', email FROM k1
UNION DISTINCT
SELECT a.action_id, 'K2', LOWER(TRIM(mpl.payer_email))
FROM actions a
JOIN `lesko-486515.provisioning_models.member_payer_live` mpl ON mpl.mn_member_id = a.member_id
WHERE mpl.payer_email IS NOT NULL;

-- ── candidate subscriptions and their state AS OF acted_at ───────────────────
CREATE TEMP TABLE sub_class AS
WITH cand AS (
  SELECT DISTINCT k.action_id, k.key_set, w.sub_uuid
  FROM key_rows k
  JOIN actions a USING (action_id)
  JOIN wh w ON w.email = k.email AND w.sub_uuid IS NOT NULL AND w.received_at <= a.acted_at
  UNION DISTINCT
  SELECT k.action_id, k.key_set, s.sub_uuid
  FROM key_rows k JOIN snap s ON s.email = k.email
  UNION DISTINCT
  SELECT t.action_id, ks, t.target_uuid
  FROM targets t CROSS JOIN UNNEST(['K1', 'K2']) AS ks
  WHERE t.target_uuid IS NOT NULL
),
last_wh AS (
  SELECT c.action_id, c.key_set, c.sub_uuid, a.acted_at,
    ARRAY_AGG(IF(w.sub_uuid IS NULL, NULL,
                 STRUCT(w.sub_state AS state, w.expires_at, w.period_ends_at, w.email))
              IGNORE NULLS ORDER BY w.received_at DESC LIMIT 1)[SAFE_OFFSET(0)] AS l
  FROM cand c
  JOIN actions a USING (action_id)
  LEFT JOIN wh w ON w.sub_uuid = c.sub_uuid AND w.sub_state IS NOT NULL
                AND w.received_at <= a.acted_at
  GROUP BY 1, 2, 3, 4
),
evald AS (
  SELECT lw.action_id, lw.key_set, lw.sub_uuid, lw.acted_at,
    CASE WHEN lw.l IS NOT NULL THEN 'webhook'
         WHEN s.sub_uuid IS NOT NULL THEN 'june_snapshot' ELSE 'none' END AS state_src,
    IF(lw.l IS NOT NULL, lw.l.state,          s.sub_state)      AS state,
    IF(lw.l IS NOT NULL, lw.l.expires_at,     s.expires_at)     AS expires_at,
    IF(lw.l IS NOT NULL, lw.l.period_ends_at, s.period_ends_at) AS period_ends_at,
    IF(lw.l IS NOT NULL, lw.l.email,          s.email)          AS sub_email
  FROM last_wh lw
  LEFT JOIN snap s ON s.sub_uuid = lw.sub_uuid
),
-- payment standing before the action: per subscription where the event names it,
-- account (email) level where it does not — the same shape as the live gate's
-- has_past_due_invoice, which is account-level too
standing AS (
  SELECT e.action_id, e.key_set, e.sub_uuid,
    MAX(IF(w.event_type = 'successful_payment_notification', w.received_at, NULL)) AS last_ok,
    MAX(IF(w.event_type = 'failed_payment_notification',     w.received_at, NULL)) AS last_fail,
    MAX(IF(w.event_type = 'new_dunning_event_notification' AND w.dunning_final,
           w.received_at, NULL))                                                  AS last_final_dunning
  FROM evald e
  JOIN wh w ON w.email = e.sub_email
           AND w.received_at <= e.acted_at
           AND (w.sub_uuid = e.sub_uuid OR w.sub_uuid IS NULL)
           AND w.event_type IN ('successful_payment_notification', 'failed_payment_notification',
                                'new_dunning_event_notification')
  GROUP BY 1, 2, 3
)
SELECT e.*, st.last_ok, st.last_fail, st.last_final_dunning,
  CASE
    WHEN e.state_src = 'none' THEN 'unknown'
    WHEN e.state = 'expired' OR (e.expires_at IS NOT NULL AND e.expires_at <= e.acted_at) THEN
      IF(COALESCE(st.last_final_dunning > COALESCE(st.last_ok, TIMESTAMP '1970-01-01'), FALSE)
         OR COALESCE(st.last_fail > COALESCE(st.last_ok, TIMESTAMP '1970-01-01'), FALSE),
         'ended_nonpayment', 'ended_other')
    -- cancelled, expiry still in the future: non-renewing but PAID for right now
    WHEN e.state = 'canceled' THEN 'cancelled_in_paid_period'
    -- frozen June row whose period has passed with no renewal webhook since
    WHEN e.state_src = 'june_snapshot' AND e.period_ends_at <= e.acted_at THEN 'snapshot_lapsed'
    -- Recurly ran all retries; expiry is pending
    WHEN COALESCE(st.last_final_dunning > COALESCE(st.last_ok, TIMESTAMP '1970-01-01'), FALSE)
      THEN 'dunning_exhausted'
    WHEN COALESCE(st.last_fail > COALESCE(st.last_ok, TIMESTAMP '1970-01-01'), FALSE)
      THEN 'past_due_in_retry_window'
    ELSE 'active_good_standing'
  END AS sub_class
FROM evald e
LEFT JOIN standing st USING (action_id, key_set, sub_uuid);

-- ── one bucket per (action, key set) ─────────────────────────────────────────
CREATE TEMP TABLE action_buckets AS
WITH agg AS (
  SELECT a.action_id, a.worker, a.action, a.rail, a.member_id, a.acted_at, a.left_at, ks AS key_set,
    t.target_v3_id, t.target_uuid,
    COUNTIF(sc.sub_class = 'active_good_standing')                           AS n_active,
    COUNTIF(sc.sub_class = 'past_due_in_retry_window')                       AS n_past_due,
    COUNTIF(sc.sub_class = 'cancelled_in_paid_period')                       AS n_cancel_paid,
    COUNTIF(sc.sub_class IN ('active_good_standing', 'past_due_in_retry_window')) AS n_renewing,
    COUNTIF(sc.sub_class IN ('active_good_standing', 'past_due_in_retry_window')
            AND sc.sub_uuid IS DISTINCT FROM t.target_uuid)                  AS n_renewing_other,
    LOGICAL_OR(sc.sub_class IN ('ended_nonpayment', 'dunning_exhausted'))    AS any_ended_np,
    LOGICAL_OR(sc.sub_class IN ('ended_other', 'snapshot_lapsed'))           AS any_ended_other,
    ANY_VALUE(IF(sc.sub_uuid = t.target_uuid, sc.sub_class, NULL))           AS target_class,
    COUNT(sc.sub_uuid)                                                       AS n_subs_seen
  FROM actions a
  CROSS JOIN UNNEST(['K1', 'K2']) AS ks
  LEFT JOIN targets   t  ON t.action_id = a.action_id
  LEFT JOIN sub_class sc ON sc.action_id = a.action_id AND sc.key_set = ks
  GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
)
SELECT agg.*,
  target_v3_id IS NOT NULL AND target_uuid IS NULL AS target_unmapped,
  CASE
    WHEN target_class IS NOT NULL THEN CASE            -- exit cancel, target resolved
      WHEN n_renewing_other >= 1                              THEN 'c_other_live_sub'
      WHEN target_class = 'active_good_standing'              THEN 'b1_active'
      WHEN target_class = 'past_due_in_retry_window'          THEN 'b2_past_due_in_retry_window'
      WHEN target_class = 'cancelled_in_paid_period'          THEN 'b3_cancelled_still_paid'
      WHEN target_class IN ('ended_nonpayment', 'dunning_exhausted') THEN 'a_ended_nonpayment'
      WHEN target_class IN ('ended_other', 'snapshot_lapsed') THEN 'a2_ended_other'
      ELSE 'd_no_recurly_state' END
    ELSE CASE                                          -- member level
      WHEN n_renewing >= 2 OR (n_renewing >= 1 AND (any_ended_np OR any_ended_other))
                                                              THEN 'c_other_live_sub'
      WHEN n_active >= 1                                      THEN 'b1_active'
      WHEN n_past_due >= 1                                    THEN 'b2_past_due_in_retry_window'
      WHEN n_cancel_paid >= 1                                 THEN 'b3_cancelled_still_paid'
      WHEN any_ended_np                                       THEN 'a_ended_nonpayment'
      WHEN any_ended_other                                    THEN 'a2_ended_other'
      ELSE 'd_no_recurly_sub_found' END
  END AS bucket
FROM agg;

-- exit cancels only: did the "leave" look like the Zapier ban (expiry <= 5 min before left_at)?
-- Same test as member_exit_actions GUARD 2.
CREATE TEMP TABLE zap_flag AS
SELECT DISTINCT b.action_id, b.key_set
FROM action_buckets b
JOIN key_rows k ON k.action_id = b.action_id AND k.key_set = b.key_set
JOIN wh w ON w.email = k.email AND w.event_type = 'expired_subscription_notification'
         AND w.received_at BETWEEN TIMESTAMP_SUB(b.left_at, INTERVAL 5 MINUTE) AND b.left_at
WHERE b.left_at IS NOT NULL;

-- ═══ STEP 2 OUTPUT ═══════════════════════════════════════════════════════════
SELECT
  key_set,
  COALESCE(worker, 'ALL')                                          AS worker_label,
  bucket,
  COUNT(*)                                                         AS actions,
  COUNT(DISTINCT member_id)                                        AS members,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY key_set, worker), 1) AS pct_of_worker,
  COUNTIF(target_unmapped)                                         AS target_unmapped,
  COUNTIF(z.action_id IS NOT NULL)                                 AS exit_after_zap_like_ban
FROM action_buckets b
LEFT JOIN zap_flag z USING (action_id, key_set)
GROUP BY GROUPING SETS ((key_set, worker, bucket), (key_set, bucket))
ORDER BY key_set, worker_label, bucket;

-- ═══ STEP 3 OUTPUT ═══════════════════════════════════════════════════════════
-- For b* and c: a successful Recurly charge (> $0) on any key address in (acted_at, +30 d].
-- Two raw sources, either counts: the transaction feed and successful_payment webhooks.
-- `matured` = acted at least 30 days ago; only matured actions have a full 30-day window,
-- so paid_30d_pct is computed on matured actions.
-- on_prior_sub = the charge names a subscription we already knew at acted_at (a renewal /
-- dunning recovery on the old sub), vs new_signup = a new_subscription after the action.
WITH pay AS (
  SELECT LOWER(TRIM(account_email)) AS email, created_at AS paid_at, subscription_ids AS sub_ref
  FROM `lesko-486515.provisioning.recurly_transactions`
  WHERE status = 'success' AND txn_type = 'purchase' AND amount > 0
  QUALIFY ROW_NUMBER() OVER (PARTITION BY txn_id ORDER BY fetched_at DESC) = 1
  UNION ALL
  SELECT email, received_at, sub_uuid
  FROM wh
  WHERE event_type = 'successful_payment_notification' AND COALESCE(txn_amount, 0) > 0
),
paid_rows AS (
  SELECT b.action_id, b.key_set, b.target_v3_id, p.sub_ref
  FROM action_buckets b
  JOIN key_rows k ON k.action_id = b.action_id AND k.key_set = b.key_set
  JOIN pay p ON p.email = k.email
            AND p.paid_at >  b.acted_at
            AND p.paid_at <= TIMESTAMP_ADD(b.acted_at, INTERVAL 30 DAY)
),
paid_flag AS (
  SELECT pr.action_id, pr.key_set,
    LOGICAL_OR(sc.sub_uuid IS NOT NULL
               OR STRPOS(COALESCE(pr.sub_ref, ''), COALESCE(pr.target_v3_id, '~none~')) > 0)
                                                                      AS paid_on_prior_sub
  FROM paid_rows pr
  LEFT JOIN sub_class sc ON sc.action_id = pr.action_id AND sc.key_set = pr.key_set
                        AND sc.sub_uuid = pr.sub_ref
  GROUP BY 1, 2
),
per_action AS (
  SELECT b.action_id, b.key_set, b.worker, b.bucket, b.member_id,
    b.acted_at <= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY) AS matured,
    pf.action_id IS NOT NULL                                          AS paid_30d,
    COALESCE(pf.paid_on_prior_sub, FALSE)                             AS paid_on_prior_sub
  FROM action_buckets b
  LEFT JOIN paid_flag pf USING (action_id, key_set)
  WHERE STARTS_WITH(b.bucket, 'b') OR STARTS_WITH(b.bucket, 'c')
),
signup AS (
  SELECT DISTINCT b.action_id, b.key_set
  FROM action_buckets b
  JOIN key_rows k ON k.action_id = b.action_id AND k.key_set = b.key_set
  JOIN wh w ON w.email = k.email AND w.event_type = 'new_subscription_notification'
           AND w.received_at > b.acted_at
           AND w.received_at <= TIMESTAMP_ADD(b.acted_at, INTERVAL 30 DAY)
)
SELECT
  key_set, COALESCE(worker, 'ALL') AS worker_label, bucket,
  COUNT(*)                                                     AS actions,
  COUNTIF(matured)                                             AS matured,
  COUNTIF(matured AND paid_30d)                                AS paid_30d,
  ROUND(100 * COUNTIF(matured AND paid_30d) / NULLIF(COUNTIF(matured), 0), 1) AS paid_30d_pct,
  COUNTIF(matured AND paid_on_prior_sub)                       AS paid_on_prior_sub,
  COUNTIF(matured AND s.action_id IS NOT NULL)                 AS new_signup_30d,
  COUNTIF(NOT matured AND paid_30d)                            AS paid_so_far_unmatured
FROM per_action pa
LEFT JOIN signup s USING (action_id, key_set)
GROUP BY GROUPING SETS ((key_set, worker, bucket), (key_set, bucket))
ORDER BY key_set, worker_label, bucket;

-- ═══ DRILL-DOWN (optional): the members behind b/c on the conservative key ═══════
-- SELECT b.*, sc.sub_uuid, sc.sub_class, sc.state_src, sc.expires_at, sc.period_ends_at,
--        sc.last_ok, sc.last_fail, sc.last_final_dunning
-- FROM action_buckets b JOIN sub_class sc USING (action_id, key_set)
-- WHERE b.key_set = 'K1' AND (STARTS_WITH(b.bucket, 'b') OR STARTS_WITH(b.bucket, 'c'))
-- ORDER BY b.acted_at DESC;
