---
name: dealer-order-intake
description: Use when checking or booking a dealer order that arrived as a PDF order form by email at Bergmann Pro. Covers the back-office checks, the order of tool calls, the five error classes and the report format.
---

# Dealer order intake, Bergmann Pro

The back office receives about 160 PDF order forms a week from smaller dealers.
Two clerks type them into SAP. Roughly one in three forms has an error that is
found only later, when production or invoicing stumbles over it. This skill
turns the clerks' checklist into something an agent runs before anything
reaches SAP.

## Order of work

1. `call_tool {"name":"workflow_validate-dealer-order","arguments":{"email_id":"<id>"}}`
   first, always. It resolves the dealer, every article, the dealer's current
   price and the earliest production slot in one go. Do not repeat those
   lookups by hand unless the workflow failed.
2. Judge the evidence with the five checks below.
3. Write the check report (format below). One report per email.
4. Only the booking agent writes to SAP, and only after a person approved the
   report. Never book an order that has an open question for the dealer.

## The five checks

| Check | Evidence in the workflow result | Verdict |
|---|---|---|
| Dealer | `dealer.match`, `dealer.mismatch` | mismatch between number and name = **ask dealer**; no match = ask dealer |
| Article | `material.match`, `material.exact`, `material.candidates` | match but not exact (typo, missing hyphen) = **correct and note**; no match = ask dealer, list candidates, never guess |
| Price | `price.net_unit_price` vs `unit_price_as_written`; `price.previous_net_unit_price` | SAP price always wins; a form price equal to last year's list = note "outdated price list" and inform dealer; any other difference = note |
| Quantity | `price.pack_size`, qty | not a pack multiple = **round up to the next pack** and note |
| Delivery week | `slot.requested_week_feasible`, `slot.earliest_week`, `slot.reason` | not feasible = propose `earliest_week`, never promise the requested week, flag as **inform dealer** |

Credit block on the dealer = stop, hand to finance.

## Verdicts

- **BOOK**: no open question. Corrections (article typo, pack rounding, price from SAP) are allowed and listed.
- **BOOK WITH NOTICE**: bookable, but the dealer must be told something (new delivery week, price difference).
- **ASK DEALER**: an article or the dealer cannot be resolved with certainty. Draft the question.
- **STOP**: credit block or anything that needs finance or sales.

## Report format

```
Order <dealer_reference> from <dealer name> (<dealer_no>), email <email_id>
Verdict: BOOK | BOOK WITH NOTICE | ASK DEALER | STOP

Positions
1. <article as written> -> <resolved article_no> <description>, qty <qty> (<correction if any>), price <SAP net price> EUR (<form price note>)
2. ...

Delivery: requested <week>, feasible <yes/no>, earliest <week> (line <n>)
Findings: <one line per finding, prefix [article] [price] [qty] [dealer] [week]>
Message to dealer: <only if BOOK WITH NOTICE or ASK DEALER, two to four sentences, in the dealer's language>
Evidence: <tool calls used>
```

## Language

Reports in German for German and Austrian dealers, otherwise English. Keep the
message to the dealer short and factual. Amounts in EUR, net.
