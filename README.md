## Is loan delinquency concentrated or widespread, and where should collections focus first?

**[View the live dashboard](https://violetwanjiru.github.io/loan-book-delinquency-concentrated-where-should-collections-focus-/)** | **[Read the SQL](lending_portfolio_analysis.sql)**

Delinquency in this book is concentrated. 60 of 1,868 loans (3.2%) are Late, and they hold almost all of the 1.57 million shillings unpaid; the other 1,808 loans (96.8%) are Paid. Collections should start with those 60, not with the 72-loan "31+ days late" bucket, because 12 of the 72 are already settled and days late on a settled loan records how late the payment was, not a live arrear.

The data covers 840 customers and loans funded from 30 March to 30 May 2026. Amounts are in shillings.

## What the data shows

| Area | Finding |
|---|---|
| Disbursements | April disbursed 33,645,283 shillings across 903 loans and May 33,964,033 across 909, a rise of 0.95%. March holds only 56 loans because the data starts on 30 March, so April's +1,856.56% is a base effect, not growth. |
| Repayment | Repaid money is 1.04 times the money lent. That exceeds 1 because repayments include interest and fees, so it is not a recovery rate. |
| Delinquency | The 60 Late loans carry 2,065,592 shillings of principal, and 75.8% of it is unrecovered. Proxy PAR30+ is 3.37% of principal counting all 72 loans in the 31+ bucket, and 2.98% counting the 60 Late loans only. |
| Customer behaviour | 673 of 840 customers (80.12%) borrowed more than once, returning after 26.41 days on average. Across 1,028 re-lending events, none followed a loan that is still unpaid. The ten largest borrowers took 55 loans worth 5,572,200 shillings (8.04% of principal) and repaid every one. |

## Approach

The analysis is one commented MySQL script, [lending_portfolio_analysis.sql](https://github.com/violetwanjiru/Where-is-the-unpaid-money-in-this-loan-book-/blob/main/Loan_Portfolio_Script.sql), and every figure here traces to a query in it. Four decisions shaped the numbers:

- **Dates.** Loan dates arrived as text in UTC. I backed up the table, validated the formats, and converted them. Months are reported in Nairobi time, which moves loans funded near midnight at month-end into the next month.
- **Unpaid amount.** I used the recorded shortfall as supplied. It differs from principal minus repaid on 121 of 1,868 loans, so I report it as recorded and state the definition.
- **Days late.** It is a recorded value, not measured at a date I chose. That is why Late status, not the 31+ bucket, defines the collections list.
- **Anomalies.** Nothing was deleted. 1,817 loans repaid above principal, which is expected because repayments include interest and fees. 72 Paid loans carry an unpaid amount of 2.27 shillings in total, which I read as rounding residue. There were no duplicate loan IDs and no missing or invalid dates.

## Recommendations

1. **Collect on the 60 Late loans and leave lending to everyone else unchanged.** Operations should confirm outstanding balances on those 60 before collections contact begins.
2. **Fast-track re-approval for proven borrowers, starting with the ten largest, with a capped pilot limit increase.** All ten are fully repaid, with no Late loans and no unpaid amount. Credit should name the current per-customer limit and approve the pilot.
3. **Keep allowing a new loan before the previous one is due, and repeat the check on each new extract.** 489 of 1,028 re-loans (47.6%) were funded before the previous loan was due, and every one of those previous loans is now settled.

## What this data cannot tell you

Days late, shortfall and status are recorded as at an extract date the file does not state, and repaid amounts include interest, fees and penalties. There are no payment dates or outstanding balances, so PAR30+ here is a proxy built on original principal, and payment before re-lending is confirmed only where the previous loan was paid on time (404 of 1,028 re-loans).

The window is about two months, with a partial March. That is too short to show seasonality, long repayment cycles or late-maturing defaults, and the average gap between loans is likely understated. The `new_repeat_loan` field marks all 1,868 loans as repeat, so it cannot separate new from returning customers.

The dashboard is a static page showing a snapshot of these query outputs, not a live database connection. To refresh it, edit the data block at the bottom of `index.html`.
