/* =====================================================================
   LENDING PORTFOLIO ANALYSIS
   Audience : Credit and Operations
   Author   : Violet Wanjiru
   Dialect  : MySQL 8.0+ (CTEs and window functions)
   Table    : loans (expected grain: one row per loan)
   Time     : funded_date is stored in UTC. From Q2 onward it is converted
              to Kenyan time (EAT, UTC+3) so months match how the business
              reads the book. Q1 shows raw UTC.
   Currency : shillings, as recorded
   Principle: After the Q0 type conversion, no record is deleted or edited.
              Anomalies are flagged (Q8).

   Contents
     Q0  Data cleaning               Q5  Portfolio at risk (PAR30+ proxy)
     Q1  Data profiling              Q6  Top borrowers
     Q2  Monthly disbursements       Q7  Sequential borrowing
     Q3  Repayment and shortfall     Q8  Validation checks
     Q4  Arrears buckets
   ===================================================================== */


/* =====================================================================
   Q0. DATA CLEANING
   Purpose : Convert text dates to DATE / DATETIME so due dates, ageing
             and cohorts calculate correctly.
   Reuse   : For a new dataset, find/replace `loans` with the table name
             and run top to bottom. Steps 0.4 and 0.6 are manual checks:
             read the output before moving on.
   ===================================================================== */

-- 0.1 Preview the raw data
SELECT *
FROM loans
LIMIT 10;

-- 0.2 Datatypes BEFORE conversion (expect due_date and funded_date as text)
SELECT
    column_name,
    data_type,
    column_type,
    is_nullable
FROM information_schema.columns
WHERE table_schema = DATABASE()
  AND table_name   = 'loans'
ORDER BY ordinal_position;

-- 0.3 Back up before any change.
--     Errors if loans_backup already exists. Intended: a re-run cannot
--     overwrite the original backup with converted data.
--     Copies data and column types only, not indexes.
CREATE TABLE loans_backup AS
SELECT *
FROM loans;

-- The backup must match the source row for row
SELECT
    (SELECT COUNT(*) FROM loans)        AS rows_in_loans,
    (SELECT COUNT(*) FROM loans_backup) AS rows_in_backup;

-- 0.4 Validate date formats 
--     due_date    : YYYY-MM-DD
--     funded_date : YYYY-MM-DD HH:MM:SS (trailing fractions or timezone
--                   are tolerated here and trimmed in 0.5)
--     Proceed only if due_bad, funded_bad, due_blank, funded_blank are all 0.
--     REGEXP returns NULL for NULL input, so *_blank catches NULL and empty text.
SELECT
    COUNT(*) AS total_rows,
    SUM(due_date    REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')                            AS due_ok,
    SUM(funded_date REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}')  AS funded_ok,
    SUM(due_date    NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2}$')                        AS due_bad,
    SUM(funded_date NOT REGEXP '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}') AS funded_bad,
    SUM(due_date    IS NULL OR TRIM(due_date)    = '')                                AS due_blank,
    SUM(funded_date IS NULL OR TRIM(funded_date) = '')                                AS funded_blank
FROM loans;

-- 0.5 Convert the date columns
-- due_date: text -> DATE (safe after the 0.4 gate)
ALTER TABLE loans MODIFY due_date DATE;

-- funded_date: trim to 'YYYY-MM-DD HH:MM:SS', then text -> DATETIME.
-- Safe-update mode is off for this one statement only.
SET SQL_SAFE_UPDATES = 0;

UPDATE loans
SET funded_date = LEFT(TRIM(funded_date), 19);

SET SQL_SAFE_UPDATES = 1;

ALTER TABLE loans MODIFY funded_date DATETIME;

-- 0.6 Confirm the conversion
-- Datatypes: due_date = date, funded_date = datetime
SHOW COLUMNS FROM loans;

-- DATE() and TIME() only work on true date types
SELECT
    funded_date,
    due_date,
    DATE(funded_date) AS funded_day,
    TIME(funded_date) AS funded_time
FROM loans
LIMIT 10;

-- Nothing should have become NULL or a zero date; ranges should be plausible
SELECT
    COUNT(*)                 AS total_rows,
    SUM(due_date    IS NULL) AS null_due_dates,
    SUM(funded_date IS NULL) AS null_funded_dates,
    MIN(due_date)            AS earliest_due_date,
    MAX(due_date)            AS latest_due_date,
    MIN(funded_date)         AS earliest_funded_date,
    MAX(funded_date)         AS latest_funded_date
FROM loans;


/* =====================================================================
   Q1. DATA PROFILING
   Purpose : Row counts, key integrity, date range and category mix
             before any metric is built.
   ===================================================================== */

-- 1.1 Table summary and key integrity (dates in UTC, as stored).
--     Flag is PASS only when rows = distinct loan_id.
WITH loan_summary AS (
    SELECT
        COUNT(*)                    AS number_of_rows,
        COUNT(loan_id)              AS number_of_loans,
        COUNT(DISTINCT loan_id)     AS number_of_distinct_loans,
        COUNT(DISTINCT customer_id) AS number_of_customers,
        MIN(funded_date)            AS oldest_record,
        MAX(funded_date)            AS latest_record,
        SUM(CASE WHEN loan_id     IS NULL THEN 1 ELSE 0 END) AS null_loan_ids,
        SUM(CASE WHEN funded_date IS NULL THEN 1 ELSE 0 END) AS null_funded_dates
    FROM loans
)
SELECT
    *,
    CASE
        WHEN number_of_rows = number_of_distinct_loans THEN 'PASS'
        ELSE 'FAIL: duplicate or null loan_id'
    END AS loan_id_uniqueness_check
FROM loan_summary;
-- Result: 1,868 rows = 1,868 distinct loans (PASS); 840 customers;
--         no null loan_id or funded_date;
--         funded 2026-03-30 00:22:22 to 2026-05-30 23:27:24 (UTC).

-- 1.2 Duplicate loan_id diagnostic (identifies the IDs if 1.1 fails)
SELECT
    loan_id,
    COUNT(*) AS times_appearing
FROM loans
GROUP BY loan_id
HAVING COUNT(*) > 1
ORDER BY times_appearing DESC;
-- Result: no rows. No duplicate loan_id.

-- 1.3 Loans by status
SELECT
    loan_status,
    COUNT(loan_id) AS number_of_loans
FROM loans
GROUP BY loan_status
ORDER BY number_of_loans DESC;
-- Result: Paid 1,808; Late 60.

-- 1.4 New vs repeat loans
SELECT
    new_repeat_loan,
    COUNT(loan_id) AS total_loans
FROM loans
GROUP BY new_repeat_loan
ORDER BY total_loans DESC;
-- Result: all 1,868 loans are recorded as 'repeat'.
-- Reading: the field cannot separate new from repeat borrowers.
--          Q7 derives repeat behaviour from funding history instead.


/* =====================================================================
   Q2. MONTHLY DISBURSEMENT TREND
   Months are in EAT. funding_days = days in the month with at least one
   loan, so a partial month is visible.
   ===================================================================== */
WITH loans_local AS (
    -- Convert UTC to EAT once, so the offset appears in one place
    SELECT
        loan_id,
        customer_id,
        loan_amount,
        CONVERT_TZ(funded_date, '+00:00', '+03:00') AS funded_date_eat
    FROM loans
),
monthly AS (
    SELECT
        DATE_FORMAT(funded_date_eat, '%Y-%m') AS funded_month,
        COUNT(DISTINCT DATE(funded_date_eat)) AS funding_days,
        COUNT(loan_id)                        AS number_of_loans,
        SUM(loan_amount)                      AS total_principal_disbursed,
        COUNT(DISTINCT customer_id)           AS unique_borrowers,
        ROUND(AVG(loan_amount), 2)            AS avg_loan_amount
    FROM loans_local
    GROUP BY DATE_FORMAT(funded_date_eat, '%Y-%m')
)
SELECT
    funded_month,
    funding_days,
    number_of_loans,
    total_principal_disbursed,
    unique_borrowers,
    avg_loan_amount,
    -- MoM % change in principal disbursed; NULL for the first month
    ROUND(
        (total_principal_disbursed
         - LAG(total_principal_disbursed) OVER (ORDER BY funded_month))
        / NULLIF(LAG(total_principal_disbursed) OVER (ORDER BY funded_month), 0)
        * 100, 2
    ) AS mom_pct_change
FROM monthly
ORDER BY funded_month;
-- Result: Mar 56 loans, 1,719,614 | Apr 903 loans, 33,645,283 | May 909 loans, 33,964,033
--         Unique borrowers 55 / 718 / 744.
-- Reading: April's +1,856.56% compares a full month with March's 56 loans.
--          The data starts on 30 March, so this is a base effect, not growth.
--          The comparable change is April to May: +0.95%.


/* =====================================================================
   Q3. REPAYMENT AND SHORTFALL
   Ratio = SUM(repaid_amounts) / SUM(loan_amount). It is not the
   repayment rate:
     1. It counts money, not loans. A few large payers can lift it and
        hide customers who paid nothing.
     2. repaid_amounts includes interest, fees and penalties, so the
        ratio can exceed 1.0 without full principal recovery (Q8, check B).
     3. It includes loans not yet due. The true rate uses only loans due
        at the reporting date:
        loans due and fully repaid / loans due (3.4).
   ===================================================================== */

--  Monthly repayment ratio and shortfall (EAT)
WITH loans_local AS (
    SELECT
        loan_id,
        loan_amount,
        repaid_amounts,
        shortfall,
        CONVERT_TZ(funded_date, '+00:00', '+03:00') AS funded_date_eat
    FROM loans
)
SELECT
    DATE_FORMAT(funded_date_eat, '%Y-%m')                        AS funded_month,
    COUNT(loan_id)                                               AS number_of_loans,
    SUM(loan_amount)                                             AS total_disbursed,
    ROUND(SUM(repaid_amounts), 2)                                AS total_repaid,
    ROUND(SUM(shortfall), 2)                                     AS total_shortfall,
    ROUND(SUM(repaid_amounts) / NULLIF(SUM(loan_amount), 0), 4)  AS repayment_ratio
FROM loans_local
GROUP BY DATE_FORMAT(funded_date_eat, '%Y-%m')
ORDER BY funded_month;
-- Result (all months, unaffected by the timezone): 69,328,930 disbursed;
--         1,566,602.78 shortfall; 1.04 shillings repaid per shilling lent.

/* =====================================================================
   Q4. ARREARS BUCKETS (recorded days_late)
   NULL     -> '6. Unknown (NULL)': a missing value does not prove the
               loan is current.
   Negative -> '7. Invalid (negative)': not a valid days-late count;
               kept out of Current and flagged, not corrected.
   Both stay in the totals, so no loan or shortfall drops out.
   ===================================================================== */
WITH bucketed AS (
    SELECT
        loan_id,
        loan_amount,
        shortfall,
        CASE
            WHEN days_late IS NULL THEN '6. Unknown (NULL)'
            WHEN days_late < 0     THEN '7. Invalid (negative)'
            WHEN days_late = 0     THEN '1. Current (0)'
            WHEN days_late < 8     THEN '2. 1-7 days'
            WHEN days_late < 15    THEN '3. 8-14 days'
            WHEN days_late < 31    THEN '4. 15-30 days'
            ELSE                        '5. 31+ days'
        END AS late_bucket
    FROM loans
)
SELECT
    late_bucket,
    COUNT(loan_id)           AS loan_count,
    SUM(loan_amount)         AS total_loan_amount,
    ROUND(SUM(shortfall), 2) AS total_shortfall,
    ROUND(SUM(shortfall) * 100.0
          / NULLIF(SUM(SUM(shortfall)) OVER (), 0), 2) AS pct_of_total_shortfall
FROM bucketed
GROUP BY late_bucket
ORDER BY late_bucket;
-- Result: Current 1,492 | 1-7 days 268 | 8-14 days 13 | 15-30 days 23 | 31+ days 72 loans.
--         The 31+ bucket holds 1,566,600.83 of 1,566,602.78 total shortfall.
--         Buckets 1-30 carry under 2 shillings combined (0.18 + 0.29 + 1.48).
-- Reading: days_late is recorded, not live. A settled loan can sit in a
--          late bucket (see 5.3).


/* =====================================================================
   Q5. PORTFOLIO AT RISK (PAR30+ PROXY)
   Proxy PAR30+     = principal of loans with days_late >= 31 / total principal
   Shortfall share  = shortfall of loans with days_late >= 31 / total shortfall
   Principal is loan_amount (loan_amount_1 is redundant, see Q8 check A).
   Shortfall is used as recorded. NULL becomes 0 and negatives are floored
   at 0, so an overpayment never offsets another loan's unpaid amount.
   ===================================================================== */
-- Proxy PAR30+ and shortfall concentration
WITH loan_base AS (
    SELECT
        loan_id,
        loan_status,
        loan_amount,
        days_late,
        GREATEST(COALESCE(shortfall, 0), 0) AS shortfall_clean
    FROM loans
)
SELECT
    SUM(loan_amount)                                                        AS total_loan_amount,

    -- Proxy PAR30+: lending sitting in loans 31+ days late
    SUM(CASE WHEN days_late >= 31 THEN loan_amount ELSE 0 END)              AS loan_amount_31_plus,
    ROUND(100.0 * SUM(CASE WHEN days_late >= 31 THEN loan_amount ELSE 0 END)
          / SUM(loan_amount), 2)                                            AS proxy_par30_pct,

    -- Same measure excluding loans already settled (status Paid)
    SUM(CASE WHEN days_late >= 31 AND UPPER(TRIM(loan_status)) = 'LATE'
             THEN loan_amount ELSE 0 END)                                   AS loan_amount_31_plus_late,
    ROUND(100.0 * SUM(CASE WHEN days_late >= 31 AND UPPER(TRIM(loan_status)) = 'LATE'
                           THEN loan_amount ELSE 0 END)
          / SUM(loan_amount), 2)                                            AS par30_late_only_pct,

    -- Shortfall concentration: share of unpaid money in 31+ loans
    ROUND(SUM(shortfall_clean), 2)                                          AS total_shortfall,
    ROUND(SUM(CASE WHEN days_late >= 31 THEN shortfall_clean ELSE 0 END), 2) AS shortfall_31_plus,
    ROUND(100.0 * SUM(CASE WHEN days_late >= 31 THEN shortfall_clean ELSE 0 END)
          / NULLIF(SUM(shortfall_clean), 0), 2)                             AS pct_of_shortfall_from_31_plus
FROM loan_base;
-- Result: total principal 69,328,930; 31+ principal 2,339,048 (proxy PAR30+ 3.37%);
--         31+ and Late principal 2,065,592 (2.98%);
--         shortfall 1,566,602.78, of which 1,566,600.83 (100.00%) is in 31+ loans.

-- Who is in the 31+ bucket? Split by recorded status
SELECT
    loan_status,
    COUNT(loan_id)           AS number_of_loans,
    SUM(loan_amount)         AS total_principal,
    ROUND(SUM(shortfall), 2) AS total_shortfall
FROM loans
WHERE days_late >= 31
GROUP BY loan_status
ORDER BY loan_status;
-- Result: Paid 12 loans, 273,456 principal, 0.32 unpaid.
--         Late 60 loans, 2,065,592 principal, 1,566,600.51 unpaid.
-- Reading: all 60 Late loans sit in the 31+ bucket. The 12 Paid loans are
--          settled; days_late on a settled loan records how late the
--          payment was, not a current arrear. The collections list is the
--          60 Late loans.

/* =====================================================================
   Reading Q5
   Proxy PAR30+ measures exposure: share of lending (original principal)
   in loans 31+ days late. Shortfall share measures concentration: share
   of unpaid money in those loans. Different numerators and denominators,
   so they answer different questions.

   The proxy is not a true PAR30+:
     - It uses original principal, not what is still owed.
     - Its denominator is all loans funded, not the live portfolio.
     - days_late is recorded, not measured at a date we choose (5.3).

   A true PAR30+ needs: outstanding principal per loan at a stated as-of
   date; payments split into principal, interest, fees and penalties; the
   repayment schedule (days past due on the oldest unpaid instalment);
   write-off and restructure flags.
   True PAR30+ = outstanding principal of loans over 30 days past due
                 / total outstanding principal of active loans,
                 at the same as-of date.
   ===================================================================== */


/* =====================================================================
   Q6. TOP BORROWERS
   Tie-break, applied in order (the same 10 customers on every run):
     1. higher total_principal   2. higher loan_count
     3. earlier first_funded_date   4. lower customer_id (unique)
   Dates are EAT.
   ===================================================================== */

--  Top 10 customers by principal disbursed
WITH loans_local AS (
    SELECT
        customer_id,
        loan_id,
        loan_amount,
        CONVERT_TZ(funded_date, '+00:00', '+03:00') AS funded_date_eat
    FROM loans
)
SELECT
    customer_id,
    COUNT(loan_id)             AS loan_count,
    MIN(funded_date_eat)       AS first_funded_date,
    MAX(funded_date_eat)       AS latest_funded_date,
    SUM(loan_amount)           AS total_principal,
    ROUND(AVG(loan_amount), 2) AS avg_loan_amount
FROM loans_local
GROUP BY customer_id
ORDER BY total_principal DESC,
         loan_count DESC,
         first_funded_date ASC,
         customer_id ASC
LIMIT 10;
-- Result: the top 10 hold 5,572,200 shillings (8.04% of 69,328,930 principal).
--         Largest: 9 loans, 914,000.

-- 6.2 Repayment position of the same 10 customers
--     late_loans = 0 and total_shortfall near 0 means repaid in full.
WITH loans_local AS (
    SELECT
        customer_id,
        loan_id,
        loan_amount,
        CONVERT_TZ(funded_date, '+00:00', '+03:00') AS funded_date_eat
    FROM loans
),
top_customers AS (
    SELECT
        customer_id,
        ROW_NUMBER() OVER (
            ORDER BY SUM(loan_amount) DESC,
                     COUNT(loan_id) DESC,
                     MIN(funded_date_eat) ASC,
                     customer_id ASC
        ) AS customer_rank
    FROM loans_local
    GROUP BY customer_id
)
SELECT
    t.customer_rank,
    l.customer_id,
    COUNT(l.loan_id)                                                       AS loan_count,
    SUM(l.loan_amount)                                                     AS total_principal,
    ROUND(SUM(l.repaid_amounts), 2)                                        AS total_repaid,
    SUM(CASE WHEN UPPER(TRIM(l.loan_status)) = 'LATE' THEN 1 ELSE 0 END)  AS late_loans,
    ROUND(SUM(l.shortfall), 2)                                             AS total_shortfall,
    MAX(l.days_late)                                                       AS max_days_late
FROM top_customers t
JOIN loans l
  ON l.customer_id = t.customer_id
WHERE t.customer_rank <= 10
GROUP BY t.customer_rank, l.customer_id
ORDER BY t.customer_rank;


/* =====================================================================
   Q7. SEQUENTIAL BORROWING
   gap_days = calendar days between a loan and the customer's previous
              loan (EAT dates).
   Two averages, because "average gap" reads two ways:
     per customer : each customer's average, then averaged (every customer
                    counts once)
     pooled       : every gap counts once (heavy borrowers weigh more)
   Same-day loans:
     - Ordered by funded time, then loan_id, so the LAG is deterministic.
     - Gap is 0 (calendar days), kept in the headline averages.
     - They count as borrowing more than once.
     - A second average excludes zero gaps to show their effect.
   ===================================================================== */

-- 7.1 Share of customers who borrowed more than once, and average gap
WITH loans_local AS (
    SELECT
        customer_id,
        loan_id,
        CONVERT_TZ(funded_date, '+00:00', '+03:00') AS funded_date_eat
    FROM loans
),
loan_sequence AS (
    -- Look back one loan within each customer's own history
    SELECT
        customer_id,
        loan_id,
        funded_date_eat,
        LAG(funded_date_eat) OVER (
            PARTITION BY customer_id
            ORDER BY funded_date_eat, loan_id
        ) AS previous_funded_date_eat
    FROM loans_local
),
loan_gaps AS (
    -- A first loan has no previous loan (NULL) and drops out here
    SELECT
        customer_id,
        DATEDIFF(DATE(funded_date_eat), DATE(previous_funded_date_eat)) AS gap_days
    FROM loan_sequence
    WHERE previous_funded_date_eat IS NOT NULL
),
customer_gaps AS (
    -- One row per customer with at least two loans
    SELECT
        customer_id,
        COUNT(*)                 AS number_of_gaps,
        SUM(gap_days)            AS total_gap_days,
        AVG(gap_days)            AS avg_gap_days,
        AVG(NULLIF(gap_days, 0)) AS avg_gap_days_excl_same_day,
        SUM(gap_days = 0)        AS number_of_same_day_gaps
    FROM loan_gaps
    GROUP BY customer_id
),
customer_totals AS (
    SELECT COUNT(DISTINCT customer_id) AS total_customers
    FROM loans
)
SELECT
    t.total_customers,
    COUNT(g.customer_id)                                       AS customers_with_2plus_loans,
    ROUND(100.0 * COUNT(g.customer_id) / t.total_customers, 2) AS pct_borrowed_more_than_once,
    ROUND(AVG(g.avg_gap_days), 2)                              AS avg_gap_days_per_customer,
    ROUND(SUM(g.total_gap_days) / SUM(g.number_of_gaps), 2)    AS avg_gap_days_pooled,
    ROUND(AVG(g.avg_gap_days_excl_same_day), 2)                AS avg_gap_days_per_customer_excl_same_day,
    SUM(g.number_of_gaps)                                      AS total_gaps,
    SUM(g.number_of_same_day_gaps)                             AS total_same_day_gaps
FROM customer_totals t
CROSS JOIN customer_gaps g
GROUP BY t.total_customers;
-- Result: 673 of 840 customers (80.12%) borrowed more than once.
--         Average gap 26.41 days per customer (22.51 pooled; 26.66 excluding same-day).
--         11 of 1,028 gaps are same-day, so they barely move the average.
-- Reading: the window is short (about two months), so long gaps are not
--          observable and the average gap is understated.

-- 7.2 Re-lending check: position of a customer's previous loan when the next
--     loan was funded.
--     The data has no payment dates, so payment before re-lending can only
--     be confirmed in some cases (D). Unpaid = shortfall of 1 shilling or
--     more (smaller amounts are rounding residue, see Q8 check C).
--     Each loan is compared with the customer's immediately previous loan only.
WITH loans_local AS (
    SELECT
        customer_id,
        loan_id,
        shortfall,
        days_late,
        due_date,
        CONVERT_TZ(funded_date, '+00:00', '+03:00') AS funded_date_eat
    FROM loans
),
loan_sequence AS (
    SELECT
        customer_id,
        loan_id,
        funded_date_eat,
        LAG(loan_id)   OVER (PARTITION BY customer_id ORDER BY funded_date_eat, loan_id) AS previous_loan_id,
        LAG(shortfall) OVER (PARTITION BY customer_id ORDER BY funded_date_eat, loan_id) AS previous_shortfall,
        LAG(days_late) OVER (PARTITION BY customer_id ORDER BY funded_date_eat, loan_id) AS previous_days_late,
        LAG(due_date)  OVER (PARTITION BY customer_id ORDER BY funded_date_eat, loan_id) AS previous_due_date
    FROM loans_local
)
SELECT
    CASE
        WHEN previous_shortfall >= 1 AND DATE(funded_date_eat) > previous_due_date
            THEN 'A. Previous loan overdue and still unpaid'
        WHEN previous_shortfall >= 1
            THEN 'B. Previous loan unpaid today, not yet due at funding'
        WHEN DATE(funded_date_eat) < previous_due_date
            THEN 'C. Funded before previous loan was due, since settled'
        WHEN previous_days_late <= 0
            THEN 'D. Previous loan paid on time, confirmed before next loan'
        ELSE 'E. Previous loan settled late, timing not confirmable'
    END                         AS relending_position,
    COUNT(loan_id)              AS number_of_loans,
    COUNT(DISTINCT customer_id) AS number_of_customers
FROM loan_sequence
WHERE previous_loan_id IS NOT NULL
GROUP BY relending_position
ORDER BY relending_position;
-- Reading: A = lent while an overdue loan was unpaid (a control gap).
--          D = payment before re-lending is confirmed.
--          C and E cannot be confirmed without payment dates.
--          A customer can appear in more than one row.


/* =====================================================================
   Q8. VALIDATION CHECKS
   Checks only flag. Nothing is deleted or altered.
     A   loan_amount differs from loan_amount_1
     B   repaid_amounts > loan_amount
     C   Paid loan with positive shortfall
     C2  Paid loan with shortfall of 1 shilling or more (material)
     D   Late loan with zero shortfall
     E1  missing funded_date or due_date
     E2  invalid date (zero date or before 2000-01-01)
     E3  funded_date after due_date (funded_date in EAT)
   Part 1 counts each check. Part 2 lists the flagged loans.
   Keep the CTE identical in both parts.
   ===================================================================== */

/* =====================================================================
   Q8. VALIDATION CHECKS
   Checks only flag. Nothing is deleted or altered.
     A   loan_amount differs from loan_amount_1
     B   repaid_amounts > loan_amount (information, not an error)
     C   Paid loan with positive shortfall
     D   Late loan with zero shortfall
     E1  missing funded_date or due_date
     E2  invalid date (zero date or before 2000-01-01)
     E3  funded_date after due_date (funded_date in EAT)
   Status: PASS   = nothing flagged
           REVIEW = flagged, needs a look
           INFO   = reported for context, not an anomaly
   To list the loans behind a check, select loan_id from validation_flags
   where that flag = 1.
   ===================================================================== */
WITH validation_flags AS (
    SELECT
        loan_id,
        CASE WHEN NOT (loan_amount <=> loan_amount_1) THEN 1 ELSE 0 END           AS flag_a,
        CASE WHEN repaid_amounts > loan_amount THEN 1 ELSE 0 END                  AS flag_b,
        CASE WHEN UPPER(TRIM(loan_status)) = 'PAID' AND shortfall > 0
             THEN 1 ELSE 0 END                                                    AS flag_c,
        CASE WHEN UPPER(TRIM(loan_status)) = 'LATE' AND shortfall = 0
             THEN 1 ELSE 0 END                                                    AS flag_d,
        CASE WHEN funded_date IS NULL OR due_date IS NULL THEN 1 ELSE 0 END       AS flag_e1,
        CASE WHEN funded_date < '2000-01-01' OR due_date < '2000-01-01'
             THEN 1 ELSE 0 END                                                    AS flag_e2,
        CASE WHEN DATE(CONVERT_TZ(funded_date, '+00:00', '+03:00')) > due_date
             THEN 1 ELSE 0 END                                                    AS flag_e3
    FROM loans
)
SELECT 'A' AS check_code, 'loan_amount differs from loan_amount_1' AS check_description,
       SUM(flag_a) AS loans_flagged,
       CASE WHEN SUM(flag_a) = 0 THEN 'PASS' ELSE 'REVIEW' END AS status
FROM validation_flags
UNION ALL
SELECT 'B', 'repaid_amounts greater than loan_amount (expected: includes interest and fees)',
       SUM(flag_b), 'INFO'
FROM validation_flags
UNION ALL
SELECT 'C', 'Paid loan with positive shortfall',
       SUM(flag_c), CASE WHEN SUM(flag_c) = 0 THEN 'PASS' ELSE 'REVIEW' END
FROM validation_flags
UNION ALL
SELECT 'D', 'Late loan with zero shortfall',
       SUM(flag_d), CASE WHEN SUM(flag_d) = 0 THEN 'PASS' ELSE 'REVIEW' END
FROM validation_flags
UNION ALL
SELECT 'E1', 'Missing funded_date or due_date',
       SUM(flag_e1), CASE WHEN SUM(flag_e1) = 0 THEN 'PASS' ELSE 'REVIEW' END
FROM validation_flags
UNION ALL
SELECT 'E2', 'Invalid date (zero date or before 2000-01-01)',
       SUM(flag_e2), CASE WHEN SUM(flag_e2) = 0 THEN 'PASS' ELSE 'REVIEW' END
FROM validation_flags
UNION ALL
SELECT 'E3', 'funded_date after due_date',
       SUM(flag_e3), CASE WHEN SUM(flag_e3) = 0 THEN 'PASS' ELSE 'REVIEW' END
FROM validation_flags;
-- Result: A 0 | B 1,817 | C 72 | D 0 | E1 0 | E2 0 | E3 0.
-- Reading:
--   A   loan_amount_1 matches loan_amount on every row, so it is redundant.
--       It is ignored throughout and left in place, not dropped.
--   B   1,817 of 1,868 loans (97.3%) repaid above principal. Expected:
--       repaid_amounts includes interest and fees. Information only.
--   C   Paid loans hold 2.27 shillings of shortfall in total (1,566,602.78
--       less 1,566,600.51 on Late loans), so the 72 flagged are rounding
--       residue, not unpaid balances.
--   D   'Late' matches the recorded status. All 60 Late loans carry unpaid shortfall.
--   E   Dates are complete, valid and in order.



/* BUSINESS FINDINGS
   1.PROVEN REPEAT BORROWERS: FAST-TRACK THE TEN LARGEST
   Credit should fast-track re-approval for customers with a clean
   repayment record, starting with the ten largest borrowers, and pilot
   a capped limit increase for them. These ten customers 
   took 55 loans worth 5,572,200 shillings, 8.04% of all principal, and
   all ten are fully repaid: no Late loans, no shortfall and at most one
   day late. The record covers about two months at today's loan sizes
   and says nothing about how they repay larger amounts, so the increase
   should be capped and tested, not granted outright.

   3. EARLY RE-LENDING: KEEP ALLOWING IT, AND MONITOR
   Credit should keep allowing a customer to take a new loan before the
   previous one is due, and repeat the check on each new extract. Across
   1,028 re-lending events, none followed a loan with an unpaid balance;
   489 (47.6%) were funded before the previous loan was due, and every
   one of those previous loans is now settled, while a further 404
   (39.3%) are confirmed paid on time before the next loan. Loans funded
   late in the window may not yet have reached the point where
   non-payment shows, so this clean result could weaken as they mature,
   and with no payment dates we cannot tell whether an earlier loan was
   cleared before the new one was funded. Credit to supply the next
   extract before the next portfolio review so the check can be
   repeated.

   3. RETURNING CUSTOMERS: FORECAST FUNDING FROM THE RETURN CYCLE
   Credit and Operations should forecast monthly funding from the
   customers due to return, because most loans are a customer coming
   back. At least 1,028 of 1,868 loans (55.0%) were a customer's second
   or later loan within the window, 673 of 840 customers (80.12%)
   borrowed more than once, and they returned after 26.41 days on
   average per customer (22.51 pooled), with same-day loans only 11 of
   1,028 gaps. About two months cannot show long gaps, so the true
   return time is likely longer than 26 days, and the new_repeat_loan
   field marks all 1,868 loans as repeat, so it cannot split new from
   returning customers. 
*/

/*
Two caveats on interpreting this dataset

1. Several fields are recorded, not measured at a date we choose.
   days_late, shortfall and status are as at an extract date the file
   doesn't state, and repaid_amounts includes interest, fees and
   penalties. There are no payment dates or outstanding balances.
   So PAR30+ is a proxy (3.37% on original principal, 2.98% excluding
   settled loans). The repaid-to-lent ratio of 1.04 is not a recovery
   rate. Payment before re-lending can be confirmed only where the
   previous loan was paid on time.

2. The window is short and partly incomplete.
   The data runs from 30 March to 30 May. March holds 56 loans and
   isn't comparable to later months. About two months cannot show
   seasonality, long repayment cycles or late-maturing defaults.
   Timestamps are UTC and reported in Nairobi time, so month
   boundaries differ from a raw UTC view. A customer's first loan in
   the window isn't necessarily their first ever.
*/


