# Are the deprovisioning / exit-cancel rails removing paying members?

Read-only investigation, 2026-09-23. Window: the last 90 days (from 2026-06-25). That covers
the whole live history of both workers: deprovisioning went live on 2026-07-16 (first real
removals 2026-07-30) and exit-cancel went live on 2026-07-14.

**Status: the SQL is written but has not been run.** This session had no working BigQuery
credential, so every count below is a placeholder until the scripts are run in the BigQuery
console (project `lesko-486515`, location **EU**). Each script is self-contained and uses
TEMP tables only, so nothing in the warehouse changes. They parse cleanly as BigQuery SQL, but
they have never run against real data, so treat the first run as a test.

Source of truth for every schema referenced: `Lesko-Help/lesko-provisioning`
(`sql/*.sql`, `ddl/*.sql`, `definitions/**`, `deprovisioner/`, `exit_canceller/`).

| Step | File |
|---|---|
| 1 | `01_action_inventory.sql` |
| 2 + 3 | `02_03_action_buckets.sql` (one script; step 3 reuses step 2's temp tables) |
| 4 | `04_cancellations_by_initiator.sql` |
| 5 | `05_signups_and_trials.sql` |

---

## Step 1: Are the actions logged? Yes

| Worker | Table | Timestamp | Member key | "Really happened" |
|---|---|---|---|---|
| lesko-deprovisioner | `lesko-486515.provisioning.deprovision_log` | `acted_at` | `member_id` (MN id) | `acted = TRUE AND action = 'remove_from_network'` |
| lesko-exit-canceller | `lesko-486515.provisioning.exit_executor_log` | `acted_at` | `member_id` (MN id) | `acted = TRUE AND action IN ('cancel_subscription','cancel_rebill','mark_invoice_failed')` |
| (all services) | `lesko-486515.provisioning.api_call_log` | `called_at` | `subject` (email or member id) | `outcome = 'ok'` |

Two actors are **not** in either worker log:

* **lesko-dunning-executor** marks invoices failed and cancels subscriptions. It logs to
  `dunning_executor_log` and to `api_call_log` (`action = 'mark_failed+cancel'`, target = invoice
  number). Query 1b lists it, and step 4 counts it as `api`.
* **Zapier zap "MEMBER CANCEL - RECURLY" [295178856]** bans the member in MN on every Recurly
  `expired_subscription_notification`, without checking for another live subscription. It
  **writes no log anywhere**. The `lesko-provisioning` README still has "Disable zap 295178856"
  as an unticked box. `session_log.md` only says the drop in leaves is "consistent with" the
  zap being retired. Query 1c measures its signature: an MN leave within 60 s of a Recurly
  expiry on the same address.

Result table (fill from 1a, 1b, 1c):

| worker | action | acted rows | members | % of all acted |
|---|---|---:|---:|---:|
| lesko-deprovisioner | remove_from_network | | | |
| lesko-exit-canceller | cancel_subscription (recurly) | | | |
| lesko-exit-canceller | mark_invoice_failed (recurly) | | | |
| lesko-exit-canceller | cancel_rebill (clickbank) | | | |
| lesko-exit-canceller | cancel_subscription (paypal) | | | |
| lesko-dunning-executor (api_call_log) | mark_failed+cancel | | | |
| zap-like MN leaves (1c) | leave ≤ 60 s after expiry | | | |

---

## Step 2: Recurly state at the moment we acted

**State source is raw only.** Recurly state comes from `provisioning.wh_recurly`, the raw
webhook XML, parsed inline with `stg_recurly`'s own regexes and cut off at `received_at <=
acted_at`. For a subscription with no webhook before the action, the state falls back to
`member_ledger_archive.recurly_subscriptions_raw`, the frozen June 2026 API snapshot.
`customer_state`, `payment_status`, `member_subscriptions` and the other derived models are
never used for state.

**Join key.** The logs carry `member_id`. Recurly carries an email and a subscription id.

| Key | What it is | Used as |
|---|---|---|
| **K1** | The address the worker itself logged: `deprovision_log.payer_email` (= the MN sign-in email) or `exit_executor_log.payer_email` (= the address the Recurly account was found under). For exit cancels it also includes the targeted subscription and that subscription's account email. Exact match, no fuzzy bridges. | **Headline (conservative)** |
| K2 | K1 plus every payer address that `member_payer_live` bridges to the member id: fuzzy June seed, Gmail normalisation and approved name matches. | Sensitivity column. It can over-match. Its derived layer is rebuilt from the *live* roster, so a member already removed can lose bridges. |
| K3 | Exit-cancel `target_id` → subscription UUID. | Needed because of the ID mismatch below. Mapped via `recurly_subscriptions_raw.sub_id` and `recurly_live_probe.subscription_v3_id`. Unmapped targets are counted in `target_unmapped`. |

**ID mismatch.** The exit-canceller writes Recurly's **v3 short id** (`yewj4ojyegbt`) into
`target_id`, not the 32-hex UUID that every webhook table keys on. A direct join matches
nothing. See finding F1.

K1 is the conservative choice because it only claims "this member had a live subscription"
when the exact address the worker acted on had one. It will under-count, not over-count,
paying members removed. K2 is the upper bound.

**Buckets**, one per action per key set:

| Bucket | Meaning |
|---|---|
| a_ended_nonpayment | Sub expired, or Recurly dunning was exhausted (final dunning event, or a failed payment with no success since), **before** we acted |
| a2_ended_other | Sub ended for another reason before we acted (a customer cancel that ran out, or a frozen June row whose period passed with no renewal) |
| b1_active | Sub active and in good standing when we acted |
| b2_past_due_in_retry_window | Failed payment since the last success, but no final dunning event yet (Recurly still retrying) |
| b3_cancelled_still_paid | Cancelled, but `expires_at` still in the future (the member had paid for access at that moment) |
| c_other_live_sub | The member key had **another** renewing live Recurly sub at the time (a duplicate subscription) |
| d_no_recurly_sub_found | Nothing found on the Recurly rail under this key (PayPal, ClickBank or unknown) |

`c` takes precedence over `b`, and `b` over `a`. For exit cancels the targeted subscription
decides the bucket. For deprovisions (which carry no subscription id) the member's whole set of
subscriptions decides.

What to expect by design: the exit-canceller *only* cancels subscriptions Recurly reports as
`active`, because the member left MN. So `b1` there is intended, and the question is whether
the leave was real. The `exit_after_zap_like_ban` column flags exits whose MN leave came within
5 minutes of a Recurly expiry. That is the zap signature, and it is how `loeser.chris` lost a
paid-up yearly on 2026-07-15. For the deprovisioner, **any** `b` or `c` row is a candidate
wrongful removal.

| bucket | deprovisioner n (%) K1 | exit-canceller n (%) K1 | all n (%) K1 | all n (%) K2 |
|---|---:|---:|---:|---:|
| a_ended_nonpayment | | | | |
| a2_ended_other | | | | |
| b1_active | | | | |
| b2_past_due_in_retry_window | | | | |
| b3_cancelled_still_paid | | | | |
| c_other_live_sub | | | | |
| d_no_recurly_sub_found | | | | |
| **total** | | | | |

---

## Step 3: b and c: did Recurly collect money in the 30 days after?

A charge counts if it succeeded, was over $0, and hit any key address in
`(acted_at, acted_at + 30 d]`. The sources are the raw `provisioning.recurly_transactions`
feed or `successful_payment_notification` webhooks; either one counts.

Only actions at least 30 days old ("matured") are in the percentage. `paid_on_prior_sub`
separates a renewal or dunning recovery on a subscription we already knew about (the member
was still paying) from `new_signup_30d` (the member came back).

| bucket | matured actions | paid ≤ 30 d | % | on prior sub | new signup |
|---|---:|---:|---:|---:|---:|
| b1_active | | | | | |
| b2_past_due_in_retry_window | | | | | |
| b3_cancelled_still_paid | | | | | |
| c_other_live_sub | | | | | |

For exit cancels, a charge on the prior sub after an `ok` cancel is the known "cancel doesn't
stop an already-raised invoice" gap. Step 1b of the exit-canceller exists to close that gap,
and this column shows whether it does.

---

## Step 4: Recurly cancellations per week, by initiator

| initiator | Rule |
|---|---|
| api | One of our services made a successful Recurly cancel or mark-failed call for **the same subscription** (v3→UUID mapped) within 15 min before the webhook. **Headline (conservative).** |
| api_loose_only | Matched only by email + time (catches dunning-executor calls keyed by invoice). Shown separately, not counted in `api`. |
| customer_or_admin | `canceled_subscription_notification`, not api. Recurly v2 webhooks cannot tell a self-service cancel from a staff cancel in the Recurly admin. |
| dunning_expiry | `expired_subscription_notification` after the retries ran out, not api |
| expiry_after_cancel | The end of an earlier cancel's paid period. Already counted at the cancel, so it's a memo line only. |
| expiry_other | Non-renewing or fixed-term expiry |

`FLAG_api_not_past_due` counts api cancels where the subscription had no failed payment since
its last success. The flag-detail query lists them with `zap_like_ban`.

| week | total | customer | dunning | api | api loose | other | FLAG api not past due |
|---|---:|---:|---:|---:|---:|---:|---:|
| … | | | | | | | |

---

## Step 5: Top of funnel

5a: weekly Recurly new subscriptions (raw), split by with/without trial, with PayPal and
ClickBank from `fct_signups` as a context column. 5b: trials by the week they **ended**. A
trial counts as converted if a successful charge over $1 on the same subscription UUID lands
between 1 day before and 14 days after the trial ends. The loose variant (same email) is
shown alongside.

| week | Recurly signups | with trial | PayPal | ClickBank | trials ended (matured) | converted | % |
|---|---:|---:|---:|---:|---:|---:|---:|
| … | | | | | | | |

---

## Findings from the code (no data needed)

**F1: "we cancelled" can never be detected for Recurly in the derived models.**
`recurly_cancel.our_cancels` matches `api_call_log.target_id` against the webhook
`subscription_uuid`. The exit-canceller logs the **v3 short id** there:
`exit_canceller/main.py` keys `recurly_targets` on `sub["id"]`, and `act()` passes that to
`raillog.log_call`. The two ID formats never match. As a result, every exit-canceller cancel is
labelled `member_cancelled` in `recurly_cancel`, and anything downstream that reports
cancellations by initiator from it over-counts customer cancels and shows zero of ours. The
removal date is unaffected, because both labels use the same `cancel_date` rule. This is why
step 4 maps v3 ids to UUIDs itself rather than reading the derived label. `recurly_live_probe`'s
own DDL warns about exactly this UUID-vs-v3 trap.

**F2: `deprovision_log` does not record why a member was removed.** It stores
`sub_ended_at`, but not which subscription ended, which rail it was on, or which addresses the
live gate checked (`search_emails`). `payer_email` is the MN sign-in address. So any audit has
to rebuild the member→payer link after the fact, through a bridge whose derived layer forgets
members once they leave the roster. `recurly_live_probe` rows written by the gate carry no
`member_id` either.

**F3: the Zapier ban zap may still be live and is invisible to both logs** (see Step 1).
If query 1c shows zap-like leaves in recent weeks, that is a removal path outside the
deprovisioner and its guards. It is also a trigger for the exit-canceller, which then cancels
the member's *other*, still-good subscription. That is the `loeser.chris` pattern, which
`member_exit_actions` GUARD 2 exists to catch.

**F4: the repo already documents paying members being removed.** Step 2 should confirm
whether these cases were isolated:

* 2026-09-04: 106 members read unpaid while holding a live Recurly sub. 91 were paying, and
  **10 had already been removed** (`ddl/recurly_live_probe.sql`, frozen June snapshot).
* 2026-09-04: PayPal member 20663061 was **removed while paying** because only the ending
  agreement was re-read (`deprovisioner/main.py` docstring).
* 2026-09-08: of 167 queued members who had used the community in the last 30 days,
  **7 had already been removed, 6 of whom had really paid** (`workflow_settings.yaml`,
  still-using hold).
* 2026-07-15: exit-cancel cancelled `loeser.chris`'s yearly, paid through 2026-10-30, after
  a zap ban (`member_exit_actions.sqlx`).

Each case has had a guard added since. Steps 2 and 3 show whether anything still gets through
after those guards: look at `b*` and `c` rows for the deprovisioner dated after 2026-09-08.

## Caveats

* Recurly v2 has no distinct `past_due` subscription state (a subscription stays `active`
  through dunning), so "past due" is derived from failed / successful payment and
  final-dunning events. Where the event names the subscription it's per subscription;
  otherwise it's per account, like the live gate's `has_past_due_invoice`.
* The June snapshot is frozen. A snapshot-only subscription whose period passed before the
  action with no renewal webhook since is treated as lapsed (`a2`). That's safe only because
  the webhook rail has had no silent hours since go-live, per the repo.
* Actions in the last 30 days have an incomplete step 3 window. They're reported as
  `paid_so_far_unmatured`, not in the percentage.
* PayPal and ClickBank subscription state is out of scope for the bucketing (the brief is
  Recurly). Those members land in `d_no_recurly_sub_found`.
