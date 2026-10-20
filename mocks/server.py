"""Mock customer systems for Bergmann Kitchen Systems, one file, three systems.

    SYSTEM=mailbox  python server.py   # the dealer order inbox (PDF order forms, already OCR'd)
    SYSTEM=sap      python server.py   # SAP S/4HANA: dealers, materials, prices, sales orders, the OTD spreadsheet
    SYSTEM=mes      python server.py   # the legacy MES: line capacity and planned load per week

Every tool answers with a structured result and never raises, so a muster
workflow can chain them without failing on a missing dealer or article.
Writes keep state in memory only; restarting the pod resets the demo.
Synthetic data throughout (data/*.json).
"""
import datetime as dt
import difflib
import json
import os
import re
from pathlib import Path

from fastmcp import FastMCP

SYSTEM = os.environ.get("SYSTEM", "sap")
DATA = Path(os.environ.get("DATA_DIR", Path(__file__).parent / "data"))
PORT = int(os.environ.get("PORT", "8000"))
TODAY = dt.date.fromisoformat(os.environ.get("DEMO_TODAY", "2026-10-26"))  # a Monday, ISO week 44

RO = {"readOnlyHint": True}
WRITE = {"readOnlyHint": False, "destructiveHint": False, "idempotentHint": False}


def load(name):
    return json.loads((DATA / f"{name}.json").read_text(encoding="utf-8"))


def iso_week(d: dt.date) -> str:
    y, w, _ = d.isocalendar()
    return f"{y}-W{w:02d}"


def parse_week(s: str):
    """'2026-W46', 'KW 46', 'week 46' -> (2026, 46); None if unreadable."""
    if not s:
        return None
    m = re.search(r"(\d{4})-?W(\d{1,2})", s, re.I) or re.search(r"(?:KW|week|wk)\s*(\d{1,2})", s, re.I)
    if not m:
        return None
    if len(m.groups()) == 2:
        return int(m.group(1)), int(m.group(2))
    return TODAY.year, int(m.group(1))


def week_add(year: int, week: int, n: int):
    d = dt.date.fromisocalendar(year, week, 1) + dt.timedelta(weeks=n)
    y, w, _ = d.isocalendar()
    return y, w


def norm(s: str) -> str:
    return re.sub(r"[^A-Z0-9]", "", (s or "").upper())


# --------------------------------------------------------------------------- mailbox
if SYSTEM == "mailbox":
    mcp = FastMCP("bergmann-dealer-mailbox")
    INBOX = load("inbox")
    STATE = {e["email_id"]: {"status": "new", "notes": []} for e in INBOX}

    @mcp.tool(annotations=RO)
    def list_order_emails(status: str = "new") -> dict:
        """Dealer order emails in the shared mailbox bestellung@bergmann.example with their status (new, in_review, booked, returned_to_dealer). Each carries one PDF order form."""
        rows = [
            {
                "email_id": e["email_id"],
                "received": e["received"],
                "from": e["from"],
                "subject": e["subject"],
                "attachment": e["attachment"],
                "status": STATE[e["email_id"]]["status"],
            }
            for e in INBOX
            if status in ("all", STATE[e["email_id"]]["status"])
        ]
        return {"count": len(rows), "emails": rows}

    @mcp.tool(annotations=RO)
    def get_order_form(email_id: str) -> dict:
        """The order form attached to one email, as the OCR/IDP step read it: dealer name and number as written, requested delivery week, and the positions with article numbers, descriptions, quantities and unit prices exactly as the dealer wrote them (typos included)."""
        for e in INBOX:
            if e["email_id"] == email_id:
                return {"found": True, "email_id": email_id, "status": STATE[email_id]["status"], **e["form"]}
        return {"found": False, "email_id": email_id, "reason": "no email with this id"}

    @mcp.tool(annotations=WRITE)
    def set_email_status(email_id: str, status: str, note: str = "") -> dict:
        """Move an order email to in_review, booked or returned_to_dealer and leave a note for the back office."""
        if email_id not in STATE:
            return {"ok": False, "reason": "no email with this id"}
        if status not in ("new", "in_review", "booked", "returned_to_dealer"):
            return {"ok": False, "reason": "unknown status"}
        STATE[email_id]["status"] = status
        if note:
            STATE[email_id]["notes"].append({"at": dt.datetime.now().isoformat(timespec="seconds"), "note": note})
        return {"ok": True, "email_id": email_id, "status": status, "notes": STATE[email_id]["notes"]}


# --------------------------------------------------------------------------- SAP
elif SYSTEM == "sap":
    mcp = FastMCP("bergmann-sap-erp")
    DEALERS = load("dealers")
    MATERIALS = load("materials")
    PRICING = load("pricing")
    KPI = load("otd_kpi")
    ORDERS = {}
    SEQ = [4710]

    def _dealer(no):
        return next((d for d in DEALERS if d["dealer_no"] == no), None)

    def _material(no):
        return next((m for m in MATERIALS if m["article_no"] == no), None)

    @mcp.tool(annotations=RO)
    def get_dealer(dealer_no: str) -> dict:
        """Dealer master record by dealer number (D-#####): name, country, discount group, price list, EDI connection, credit status."""
        d = _dealer(dealer_no)
        return {"found": True, **d} if d else {"found": False, "dealer_no": dealer_no, "reason": "no dealer with this number"}

    @mcp.tool(annotations=RO)
    def find_dealer(name: str = "", dealer_no: str = "") -> dict:
        """Resolve a dealer from what the order form says. Checks the number first, then the name; reports a mismatch when number and name point to different dealers, and lists candidates when nothing matches exactly."""
        by_no = _dealer(dealer_no) if dealer_no else None
        names = [d["name"] for d in DEALERS]
        close = difflib.get_close_matches(name, names, n=3, cutoff=0.6) if name else []
        by_name = next((d for d in DEALERS if d["name"] == close[0]), None) if close else None
        if by_no and by_name and by_no["dealer_no"] != by_name["dealer_no"]:
            return {
                "match": None,
                "mismatch": True,
                "reason": f"dealer number {dealer_no} belongs to {by_no['name']}, but the form names {name}",
                "candidates": [by_no, by_name],
            }
        m = by_no or by_name
        if m:
            return {"match": m, "mismatch": False, "matched_by": "dealer_no" if by_no else "name", "candidates": []}
        return {"match": None, "mismatch": False, "reason": "no dealer found", "candidates": [d for d in DEALERS if d["name"] in close]}

    @mcp.tool(annotations=RO)
    def get_material(article_no: str) -> dict:
        """Material master by exact article number: description, product family, production line, pack size, stock, standard lead time."""
        m = _material(article_no)
        return {"found": True, **m} if m else {"found": False, "article_no": article_no, "reason": "no material with this number"}

    @mcp.tool(annotations=RO)
    def find_material(query: str) -> dict:
        """Resolve an article from what the dealer wrote: exact number, number with typos (missing hyphens, wrong case) or a description. Returns the match, or candidates when the number does not exist."""
        q = norm(query)
        exact = next((m for m in MATERIALS if norm(m["article_no"]) == q), None)
        if exact:
            return {"query": query, "match": exact, "exact": exact["article_no"] == query.strip().upper(), "candidates": []}
        scored = sorted(
            MATERIALS,
            key=lambda m: max(
                difflib.SequenceMatcher(None, q, norm(m["article_no"])).ratio(),
                difflib.SequenceMatcher(None, query.lower(), m["description"].lower()).ratio(),
            ),
            reverse=True,
        )[:3]
        return {"query": query, "match": None, "exact": False, "candidates": scored, "reason": "no exact article number"}

    @mcp.tool(annotations=RO)
    def get_dealer_price(dealer_no: str, article_no: str) -> dict:
        """The net unit price this dealer pays today (list price 2026 less the dealer's discount group), with the price list version. Also returns last year's price so an outdated price on an order form can be recognised."""
        d, m = _dealer(dealer_no), _material(article_no)
        if not d or not m:
            return {"found": False, "dealer_no": dealer_no, "article_no": article_no, "reason": "dealer or article unknown"}
        disc = PRICING["discount_groups"][d["discount_group"]]
        cur = round(m["list_price"] * (1 - disc), 2)
        old = round(m["list_price"] / (1 + PRICING["list_price_increase_2026"]) * (1 - disc), 2)
        return {
            "found": True,
            "dealer_no": dealer_no,
            "article_no": article_no,
            "currency": "EUR",
            "net_unit_price": cur,
            "price_list": PRICING["current_price_list"],
            "valid_from": PRICING["valid_from"],
            "previous_price_list": PRICING["previous_price_list"],
            "previous_net_unit_price": old,
            "pack_size": m["pack_size"],
        }

    @mcp.tool(annotations=RO)
    def check_availability(article_no: str, qty: int) -> dict:
        """Stock and lead time from SAP's point of view: spare parts ship from stock, appliances are made to order with a standard lead time; the real production slot comes from the MES."""
        m = _material(article_no)
        if not m:
            return {"found": False, "article_no": article_no, "reason": "no material with this number"}
        if m["make_to_order"]:
            y, w = week_add(TODAY.year, TODAY.isocalendar()[1], m["lead_time_weeks"])
            return {"found": True, "article_no": article_no, "qty": qty, "make_to_order": True, "line": m["line"],
                    "standard_lead_time_weeks": m["lead_time_weeks"], "standard_earliest_week": f"{y}-W{w:02d}",
                    "note": "confirm the slot with the MES (earliest_slot)"}
        ok = m["stock"] >= qty
        return {"found": True, "article_no": article_no, "qty": qty, "make_to_order": False, "stock": m["stock"],
                "available_now": ok, "pack_size": m["pack_size"],
                "qty_is_pack_multiple": qty % m["pack_size"] == 0}

    @mcp.tool(annotations=WRITE)
    def create_sales_order(dealer_no: str, items: list[dict], requested_delivery_week: str, dealer_reference: str = "", source_email_id: str = "") -> dict:
        """Create a sales order in SAP (VA01). items: [{article_no, qty}]. Prices come from the dealer's price list, never from the form. Refuses unknown dealers, unknown articles and quantities that are not pack multiples."""
        d = _dealer(dealer_no)
        if not d:
            return {"ok": False, "reason": f"dealer {dealer_no} unknown"}
        if d.get("credit_block"):
            return {"ok": False, "reason": f"dealer {dealer_no} has a credit block, release by finance needed"}
        lines, total = [], 0.0
        for it in items:
            m = _material(str(it.get("article_no", "")))
            qty = int(it.get("qty", 0))
            if not m:
                return {"ok": False, "reason": f"article {it.get('article_no')} unknown"}
            if qty <= 0 or qty % m["pack_size"]:
                return {"ok": False, "reason": f"qty {qty} of {m['article_no']} is not a multiple of pack size {m['pack_size']}"}
            p = get_dealer_price.fn(dealer_no, m["article_no"])["net_unit_price"]
            lines.append({"pos": len(lines) + 1, "article_no": m["article_no"], "description": m["description"], "qty": qty, "net_unit_price": p, "net_value": round(p * qty, 2)})
            total += p * qty
        SEQ[0] += 1
        no = f"SO-{SEQ[0]}"
        ORDERS[no] = {"order_no": no, "dealer_no": dealer_no, "dealer": d["name"], "requested_delivery_week": requested_delivery_week,
                      "dealer_reference": dealer_reference, "source_email_id": source_email_id, "lines": lines,
                      "net_total": round(total, 2), "currency": "EUR", "created": dt.datetime.now().isoformat(timespec="seconds"), "status": "open"}
        return {"ok": True, **ORDERS[no]}

    @mcp.tool(annotations=RO)
    def get_sales_order(order_no: str) -> dict:
        """A sales order created in this session."""
        return {"found": True, **ORDERS[order_no]} if order_no in ORDERS else {"found": False, "order_no": order_no}

    @mcp.tool(annotations=RO)
    def list_sales_orders() -> dict:
        """All sales orders created in this session."""
        return {"count": len(ORDERS), "orders": list(ORDERS.values())}

    @mcp.tool(annotations=RO)
    def get_otd_report() -> dict:
        """The back office's on-time-delivery spreadsheet for Bergmann Pro: the KPI, the target, the causes of late deliveries and what manual order entry costs today."""
        return KPI


# --------------------------------------------------------------------------- MES
elif SYSTEM == "mes":
    mcp = FastMCP("bergmann-mes-planning")
    CAP = load("capacity")
    MATERIALS = load("materials")

    @mcp.tool(annotations=RO)
    def get_line_load(week: str) -> dict:
        """Planned load against capacity per production line for one ISO week (e.g. 2026-W46), as the Monday plan in the MES has it."""
        pw = parse_week(week)
        if not pw:
            return {"found": False, "week": week, "reason": "week not readable, use 2026-W46"}
        key = f"{pw[0]}-W{pw[1]:02d}"
        rows = CAP["load"].get(key)
        if rows is None:
            return {"found": False, "week": key, "reason": "no plan for this week yet"}
        return {"found": True, "week": key, "lines": [
            {"line": ln, "name": CAP["lines"][ln]["name"], "capacity_units": CAP["lines"][ln]["capacity_units"], "planned_units": rows[ln],
             "free_units": CAP["lines"][ln]["capacity_units"] - rows[ln]} for ln in CAP["lines"]]}

    @mcp.tool(annotations=RO)
    def earliest_slot(article_no: str, qty: int, requested_week: str = "") -> dict:
        """The earliest week the line that builds this article has free capacity for the quantity, never earlier than the standard lead time. Says whether the dealer's requested week can be met."""
        m = next((x for x in MATERIALS if x["article_no"] == article_no), None)
        if not m:
            return {"found": False, "article_no": article_no, "reason": "no material with this number"}
        if not m["make_to_order"]:
            return {"found": True, "article_no": article_no, "make_to_order": False, "note": "ships from stock, no production slot needed", "requested_week_feasible": True}
        y0, w0 = TODAY.isocalendar()[0], TODAY.isocalendar()[1]
        y, w = week_add(y0, w0, m["lead_time_weeks"])
        slot = None
        for _ in range(16):
            key = f"{y}-W{w:02d}"
            rows = CAP["load"].get(key)
            free = (CAP["lines"][m["line"]]["capacity_units"] - rows[m["line"]]) if rows else CAP["lines"][m["line"]]["capacity_units"]
            if free >= qty:
                slot = key
                break
            y, w = week_add(y, w, 1)
        req = parse_week(requested_week)
        req_key = f"{req[0]}-W{req[1]:02d}" if req else None
        return {"found": True, "article_no": article_no, "qty": qty, "line": m["line"], "line_name": CAP["lines"][m["line"]]["name"],
                "earliest_week": slot, "requested_week": req_key,
                "requested_week_feasible": bool(slot and req_key and slot <= req_key),
                "reason": None if not req_key or (slot and slot <= req_key) else f"line {m['line']} is fully planned until {slot}"}

else:
    raise SystemExit(f"unknown SYSTEM {SYSTEM!r}; use mailbox, sap or mes")

if __name__ == "__main__":
    mcp.run(transport="http", host="0.0.0.0", port=PORT, path="/mcp")
