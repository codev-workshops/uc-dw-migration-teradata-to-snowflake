#!/usr/bin/env python3
"""Deploy the converted Snowflake DDL/DML, load the seed data, reconcile it
against data/validation/, and run behavioural checks.

Targets:
  --target snowflake  Real Snowflake account. Connection from environment:
                      SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER, SNOWFLAKE_PASSWORD
                      (or SNOWFLAKE_PRIVATE_KEY_FILE), SNOWFLAKE_WAREHOUSE,
                      SNOWFLAKE_ROLE, SNOWFLAKE_DATABASE (default
                      BANKING_MIGRATION_VALIDATION). The script runs
                      CREATE OR REPLACE on BANKING_DW in that database:
                      never point it at a database holding real data.
  --target emulator   Offline: fakesnow (Snowflake dialect on DuckDB). Applies
                      the emulator-only shims listed in EMULATOR_SHIMS and
                      interprets procedure/UDTF bodies statement by statement,
                      because the emulator has no Snowflake Scripting or UDTFs.

Requires: pip install -r snowflake/validation/requirements.txt
"""

import argparse
import csv
import datetime as dt
import decimal
import json
import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SF = REPO / "snowflake"
SEEDS = {
    "DIM_CUSTOMER": REPO / "data/seed/dim_customer_sample.csv",
    "DIM_ACCOUNT": REPO / "data/seed/dim_account_sample.csv",
    "DIM_PRODUCT": REPO / "data/seed/dim_product_sample.csv",
    "DIM_BRANCH": REPO / "data/seed/dim_branch_sample.csv",
}
DIM_DATE_RANGE = (dt.date(2000, 1, 1), dt.date(2029, 12, 31))

# Emulator-only rewrites (pattern, replacement, reason). Never applied to Snowflake.
EMULATOR_SHIMS = [
    (r"\s+COLLATE\s+'en-ci'", "", "DuckDB parser has no Snowflake collation specs"),
    (r"TEMPORARY TABLE BANKING_DW\.", "TEMPORARY TABLE ", "DuckDB temp tables live in the temp schema"),
    (r"BANKING_DW\.(VT_\w+)", r"\1", "DuckDB temp tables live in the temp schema"),
    (r"ORDER BY RANDOM\(\)", "ORDER BY ft.TRANSACTION_ID", "DuckDB rejects volatile window ORDER BY"),
]


# --------------------------------------------------------------------------
# SQL helpers
# --------------------------------------------------------------------------
def split_sql(text):
    """Split on ';' outside quotes, comments and $$ blocks. Drops comment-only chunks."""
    out, buf, i, n = [], [], 0, len(text)
    while i < n:
        two = text[i:i + 2]
        ch = text[i]
        if two == "--":
            j = text.find("\n", i)
            j = n if j < 0 else j
            buf.append(text[i:j]); i = j
        elif two == "/*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            buf.append(text[i:j]); i = j
        elif two == "$$":
            j = text.find("$$", i + 2)
            j = n if j < 0 else j + 2
            buf.append(text[i:j]); i = j
        elif ch == "'":
            j = i + 1
            while j < n:
                if text[j] == "'" and text[j + 1:j + 2] == "'":
                    j += 2
                elif text[j] == "'":
                    break
                else:
                    j += 1
            buf.append(text[i:j + 1]); i = j + 1
        elif ch == ";":
            out.append("".join(buf)); buf = []; i += 1
        else:
            buf.append(ch); i += 1
    out.append("".join(buf))
    cleaned = []
    for s in out:
        bare = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
        bare = re.sub(r"--[^\n]*", "", bare)
        if bare.strip():
            cleaned.append(s.strip())
    return cleaned


def strip_comments(sql):
    """Drop leading comment lines/blocks so the first keyword can be inspected."""
    prev = None
    while prev != sql:
        prev = sql
        sql = re.sub(r"^\s*(?:/\*.*?\*/|--[^\n]*)", "", sql, count=1, flags=re.S)
    return sql.strip()


def split_top_level(text):
    """Split on commas outside parentheses and quotes."""
    parts, buf, depth, quote = [], [], 0, False
    for ch in text:
        if ch == "'":
            quote = not quote
        elif not quote and ch == "(":
            depth += 1
        elif not quote and ch == ")":
            depth -= 1
        elif not quote and ch == "," and depth == 0:
            parts.append("".join(buf).strip()); buf = []
            continue
        buf.append(ch)
    parts.append("".join(buf).strip())
    return [p for p in parts if p]


def lit(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "TRUE" if v else "FALSE"
    if isinstance(v, (int, float, decimal.Decimal)):
        return str(v)
    if isinstance(v, dt.datetime):
        return f"TIMESTAMP '{v:%Y-%m-%d %H:%M:%S}'"
    if isinstance(v, dt.date):
        return f"DATE '{v:%Y-%m-%d}'"
    return "'" + str(v).replace("'", "''") + "'"


def sub_names(sql, values):
    """Replace :NAME and bare NAME (not after '.', not inside quotes) with literals, in one pass."""
    if not values:
        return sql
    upper = {k.upper(): v for k, v in values.items()}
    names = "|".join(sorted((re.escape(k) for k in upper), key=len, reverse=True))
    pattern = re.compile(rf"(?<![\w.]):?({names})\b", flags=re.I)
    parts = re.split(r"('(?:[^']|'')*')", sql)
    for i in range(0, len(parts), 2):
        parts[i] = pattern.sub(lambda m: lit(upper[m.group(1).upper()]), parts[i])
    return "".join(parts)


# --------------------------------------------------------------------------
# Targets
# --------------------------------------------------------------------------
class Target:
    name = "base"

    def __init__(self, conn):
        self.conn = conn
        self.cur = conn.cursor()
        self.rowcount = 0

    def shim(self, sql):
        return sql

    def execute(self, sql, params=None):
        self.cur.execute(self.shim(sql), params)
        self.rowcount = self.cur.rowcount if self.cur.rowcount is not None else 0
        return self.cur

    def query(self, sql):
        cur = self.execute(sql)
        cols = [d[0].upper() for d in cur.description] if cur.description else []
        return [dict(zip(cols, r)) for r in cur.fetchall()]

    def scalar(self, sql):
        return self.execute(sql).fetchone()[0]

    def executemany(self, sql, rows):
        self.cur.executemany(self.shim(sql), rows)

    def bulk_insert(self, table, rows):
        for i in range(0, len(rows), 2000):
            self.execute(f"INSERT INTO BANKING_DW.{table} VALUES "
                         + ", ".join("(" + ", ".join(lit(v) for v in r) + ")" for r in rows[i:i + 2000]))


class SnowflakeTarget(Target):
    name = "snowflake"

    def deploy_routine(self, sql):
        self.execute(sql)

    def call(self, proc, args):
        res = self.scalar(f"CALL BANKING_DW.{proc}({', '.join(lit(a) for a in args)})")
        return json.loads(res) if isinstance(res, str) else res

    def udtf(self, func, args=None, kwargs=None):
        parts = [lit(a) for a in (args or [])]
        parts += [f"{k} => {lit(v)}" for k, v in (kwargs or {}).items()]
        return self.query(f"SELECT * FROM TABLE(BANKING_DW.{func}({', '.join(parts)}))")


class EmulatorTarget(Target):
    """fakesnow target. Procedures and UDTFs are interpreted from their source."""
    name = "emulator"

    def __init__(self, conn):
        super().__init__(conn)
        self.procs, self.funcs = {}, {}

    def bulk_insert(self, table, rows):
        # fakesnow transpiles every statement; load the generated calendar straight into DuckDB
        db = self.scalar("SELECT CURRENT_DATABASE()")
        duck = self.conn._duck_conn
        duck.executemany(f"INSERT INTO {db}.BANKING_DW.{table} VALUES ({', '.join(['?'] * len(rows[0]))})", rows)

    def shim(self, sql):
        for pat, rep, _ in EMULATOR_SHIMS:
            sql = re.sub(pat, rep, sql)
        return sql

    def deploy_routine(self, sql):
        m = re.match(r"CREATE OR REPLACE (PROCEDURE|FUNCTION)\s+BANKING_DW\.(\w+)\((.*?)\)\s*RETURNS",
                     sql, flags=re.S | re.I)
        kind, name, arglist = m.group(1).upper(), m.group(2).upper(), m.group(3)
        body = sql[sql.index("$$") + 2: sql.rindex("$$")]
        args = []
        for a in split_top_level(arglist):
            am = re.match(r"(\w+)\s+([\w(), ]+?)(?:\s+DEFAULT\s+(.+))?$", a, flags=re.S | re.I)
            args.append((am.group(1).upper(), am.group(3)))
        (self.procs if kind == "PROCEDURE" else self.funcs)[name] = (args, body)
        import sqlglot  # body SQL must at least parse as Snowflake
        if kind == "FUNCTION":
            sqlglot.parse_one(body, read="snowflake")

    def _bind(self, args, given, kwargs=None):
        values = {}
        given = list(given or [])
        for idx, (name, default) in enumerate(args):
            if kwargs and name in kwargs:
                values[name] = kwargs[name]
            elif idx < len(given):
                values[name] = given[idx]
            elif default is not None:
                values[name] = self.scalar("SELECT " + sub_names(default, values))
            else:
                raise ValueError(f"missing argument {name}")
        return values

    def udtf(self, func, args=None, kwargs=None):
        params, body = self.funcs[func.upper()]
        values = self._bind(params, args, {k.upper(): v for k, v in (kwargs or {}).items()})
        return self.query(sub_names(body, values))

    def call(self, proc, args):
        params, body = self.procs[proc.upper()]
        vars_ = self._bind(params, args)
        m = re.match(r"\s*DECLARE(.*?)\bBEGIN\b(.*)\bEND;\s*$", body, flags=re.S | re.I)
        decls, main = m.group(1), m.group(2)
        handler = None
        if re.search(r"^\s*EXCEPTION\s*$", main, flags=re.M):
            main, handler = re.split(r"^\s*EXCEPTION\s*$", main, maxsplit=1, flags=re.M)
            handler = re.sub(r"^\s*WHEN OTHER THEN", "", handler.strip(), flags=re.I)
        for d in split_sql(decls):
            dm = re.match(r"(\w+)\s+[\w(), ]+?(?:\s+DEFAULT\s+(.+))?$", d.strip(), flags=re.S | re.I)
            vars_[dm.group(1).upper()] = (self.scalar("SELECT " + sub_names(dm.group(2), vars_))
                                          if dm.group(2) else None)
        try:
            return self._run(main, vars_)
        except Exception as exc:  # emulate EXCEPTION WHEN OTHER
            if handler is None:
                raise
            print(f"  (emulator) {proc} raised, running EXCEPTION block: {str(exc).splitlines()[0][:200]}")
            vars_.update(SQLCODE=-1, SQLERRM=str(exc).splitlines()[0][:200], SQLSTATE="P0000")
            return self._run(handler, vars_)

    def _run(self, block, vars_):
        for stmt in split_sql(block):
            body = re.sub(r"^(\s*--[^\n]*\n)+", "", stmt).strip()
            am = re.match(r"(\w+)\s*:=\s*(.+)$", body, flags=re.S)
            if am:
                expr = am.group(2).strip()
                vars_[am.group(1).upper()] = (self.rowcount if expr.upper() == "SQLROWCOUNT"
                                              else self.scalar("SELECT " + sub_names(expr, vars_)))
            elif body.upper().startswith("RETURN"):
                pairs = re.findall(r"'(\w+)',\s*(\w+)", body)
                return {k: (vars_[v.upper()] if v.upper() in vars_ else int(v)) for k, v in pairs}
            else:
                self.execute(sub_names(body, vars_))
        return None


def connect(target):
    import snowflake.connector
    if target == "emulator":
        import fakesnow
        global _PATCHER  # keep the patch context alive for the whole run
        _PATCHER = fakesnow.patch()
        _PATCHER.__enter__()
        conn = snowflake.connector.connect(database="BANKING_MIGRATION_VALIDATION")
        t = EmulatorTarget(conn)
    else:
        kw = dict(account=os.environ["SNOWFLAKE_ACCOUNT"], user=os.environ["SNOWFLAKE_USER"],
                  warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE"), role=os.environ.get("SNOWFLAKE_ROLE"))
        if os.environ.get("SNOWFLAKE_PRIVATE_KEY_FILE"):
            kw["private_key_file"] = os.environ["SNOWFLAKE_PRIVATE_KEY_FILE"]
        else:
            kw["password"] = os.environ["SNOWFLAKE_PASSWORD"]
        conn = snowflake.connector.connect(**{k: v for k, v in kw.items() if v})
        t = SnowflakeTarget(conn)
    db = os.environ.get("SNOWFLAKE_DATABASE", "BANKING_MIGRATION_VALIDATION")
    t.execute(f"CREATE DATABASE IF NOT EXISTS {db}")
    t.execute(f"USE DATABASE {db}")
    t.execute("CREATE SCHEMA IF NOT EXISTS BANKING_DW")
    t.execute("USE SCHEMA BANKING_DW")
    if t.name == "snowflake":
        t.execute("ALTER SESSION SET TIMEZONE = 'Europe/Oslo'")
    return t


# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
class Report:
    def __init__(self):
        self.items = []

    def check(self, section, name, ok, detail=""):
        self.items.append({"section": section, "check": name,
                           "status": "PASS" if ok else "FAIL", "detail": str(detail)})
        print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
        return ok

    def note(self, section, name, status, detail=""):
        self.items.append({"section": section, "check": name, "status": status, "detail": str(detail)})
        print(f"  [{status}] {name}" + (f" — {detail}" if detail else ""))

    @property
    def failed(self):
        return [i for i in self.items if i["status"] == "FAIL"]


_T0 = dt.datetime.now()


def section(title):
    print(f"\n== {title}  (+{(dt.datetime.now() - _T0).seconds}s)")
    return title


# --------------------------------------------------------------------------
# Steps
# --------------------------------------------------------------------------
def lint(rep):
    import sqlglot
    s = section("Snowflake-dialect parse (sqlglot)")
    files = sorted((SF / "ddl").rglob("*.sql")) + sorted((SF / "dml").rglob("*.sql")) \
        + [SF / "validation/checksum_queries.sql"]
    for f in files:
        text = f.read_text()
        if f.parent.name == "scripts":  # strip SnowSQL !commands
            text = re.sub(r"^!.*$", "", text, flags=re.M)
        errors, unparsed = [], []
        for stmt in split_sql(text):
            head = strip_comments(stmt).split(None, 2)[:2]
            if head and head[0].upper() == "PUT":  # client-side SnowSQL command
                unparsed.append("PUT")
                continue
            try:
                tree = sqlglot.parse_one(stmt, read="snowflake")
                if isinstance(tree, sqlglot.exp.Command):
                    unparsed.append(" ".join(head).upper())
            except Exception as exc:
                errors.append(str(exc).splitlines()[0][:160])
        detail = "; ".join(errors)
        if unparsed:
            detail += ("; " if detail else "") + "not checked by sqlglot: " + ", ".join(unparsed)
        rep.check(s, f"parse {f.relative_to(REPO)} ({len(split_sql(text))} statements)", not errors, detail)


def deploy(t, rep):
    s = section("Deploy converted objects")
    groups = [sorted((SF / "ddl/tables").glob("*.sql")), sorted((SF / "ddl/views").glob("*.sql")),
              [SF / "validation/fixtures_supporting_tables.sql"],
              sorted((SF / "dml/stored_procedures").glob("*.sql")), sorted((SF / "dml/macros").glob("*.sql"))]
    for f in [f for g in groups for f in g]:
        err = None
        for stmt in split_sql(f.read_text()):
            try:
                if re.match(r"CREATE OR REPLACE (PROCEDURE|FUNCTION)", strip_comments(stmt), flags=re.I):
                    t.deploy_routine(strip_comments(stmt))
                else:
                    t.execute(stmt)
            except Exception as exc:
                err = f"{strip_comments(stmt).splitlines()[0][:70]} -> {str(exc).splitlines()[0][:200]}"
                break
        rep.check(s, f"deploy {f.relative_to(REPO)}", err is None, err or "")


def load_seeds(t, rep):
    s = section("Load seed data")
    for table, path in SEEDS.items():
        with open(path, newline="") as fh:
            rows = list(csv.reader(fh, delimiter="|"))
        cols, data = rows[0], [[v if v != "" else None for v in r] for r in rows[1:]]
        t.executemany(f"INSERT INTO BANKING_DW.{table} ({', '.join(cols)}) "
                      f"VALUES ({', '.join(['%s'] * len(cols))})", data)
        rep.note(s, f"loaded {path.relative_to(REPO)} -> {table}", "INFO", f"{len(data)} rows")
    t.bulk_insert("DIM_DATE", dim_date_rows())
    rep.note(s, "generated DIM_DATE", "INFO", f"{DIM_DATE_RANGE[0]} .. {DIM_DATE_RANGE[1]}")


def easter(y):
    a, b, c = y % 19, y // 100, y % 100
    d, e = b // 4, b % 4
    f = (b + 8) // 25
    g = (b - f + 1) // 3
    h = (19 * a + b - d - g + 15) % 30
    i, k = c // 4, c % 4
    l_ = (32 + 2 * e + 2 * i - h - k) % 7
    m = (a + 11 * h + 22 * l_) // 451
    return dt.date(y, (h + l_ - 7 * m + 114) // 31, ((h + l_ - 7 * m + 114) % 31) + 1)


def norwegian_holidays(y):
    e = easter(y)
    td = dt.timedelta
    return {dt.date(y, 1, 1): "Nyttarsdag", e - td(3): "Skjaertorsdag", e - td(2): "Langfredag",
            e: "Forste paskedag", e + td(1): "Andre paskedag", dt.date(y, 5, 1): "Arbeidernes dag",
            dt.date(y, 5, 17): "Grunnlovsdag", e + td(39): "Kristi himmelfartsdag",
            e + td(49): "Forste pinsedag", e + td(50): "Andre pinsedag",
            dt.date(y, 12, 25): "Forste juledag", dt.date(y, 12, 26): "Andre juledag"}


def dim_date_rows():
    rows, d, hol = [], DIM_DATE_RANGE[0], {}
    while d <= DIM_DATE_RANGE[1]:
        if d.year not in hol:
            hol[d.year] = norwegian_holidays(d.year)
        nxt = d + dt.timedelta(days=1)
        q = (d.month - 1) // 3 + 1
        weekend = d.isoweekday() >= 6
        hname = hol[d.year].get(d)
        try:
            prev_year = d.replace(year=d.year - 1)
        except ValueError:
            prev_year = d.replace(year=d.year - 1, day=28)
        rows.append([int(d.strftime("%Y%m%d")), d, d.isoweekday(), d.strftime("%A"), d.day,
                     d.timetuple().tm_yday, int(d.strftime("%W")), d.isocalendar()[1], d.month,
                     d.strftime("%B"), d.strftime("%b"), q, f"Q{q}", 1 if d.month <= 6 else 2,
                     d.year, d.year, q, int(weekend), int(hname is not None), hname,
                     int(not weekend and hname is None), int(nxt.month != d.month),
                     int(nxt.month != d.month and d.month % 3 == 0), int(d.month == 12 and d.day == 31),
                     d - dt.timedelta(days=1), nxt, prev_year])
        d = nxt
    return rows


def reconcile(t, rep):
    s = section("Row-count reconciliation vs data/validation/expected_row_counts.csv")
    with open(REPO / "data/validation/expected_row_counts.csv", newline="") as fh:
        expected = list(csv.DictReader(fh, delimiter="|"))
    for row in expected:
        table, exp = row["TABLE_NAME"], int(row["EXPECTED_ROW_COUNT"])
        actual = t.scalar(f"SELECT COUNT(*) FROM BANKING_DW.{table}")
        if table.startswith("FACT_"):
            rep.note(s, f"{table}: expected {exp}, actual {actual}", "N/A",
                     "no source extract in repo (" + row["NOTES"] + "); reconcile after the Teradata unload")
        else:
            rep.check(s, f"{table}: expected {exp}, actual {actual}", actual == exp)


def checksums(t, rep):
    s = section("Checksum queries (snowflake/validation/checksum_queries.sql)")
    results = []
    for idx, stmt in enumerate(split_sql((SF / "validation/checksum_queries.sql").read_text()), 1):
        try:
            rows = t.query(stmt)
            results.append({"query": idx, "rows": rows})
            rep.check(s, f"query {idx} ran", True, f"{len(rows)} rows")
        except Exception as exc:
            rep.check(s, f"query {idx} ran", False, str(exc).splitlines()[0][:200])
    q2 = results[1]["rows"][0] if len(results) > 1 else {}
    rep.check(s, "DIM_CUSTOMER fingerprint (seed)", q2.get("ROW_COUNT") == 15 and q2.get("ID_SUM") == 15120
              and str(q2.get("MIN_ONBOARD_DATE")) == "2005-02-28", {k: q2.get(k) for k in
              ("ROW_COUNT", "ID_SUM", "LEN_SUM", "MIN_ONBOARD_DATE", "MAX_ONBOARD_DATE", "ACTIVE_COUNT")})
    dupes = results[-1]["rows"] if results else []
    rep.check(s, "no duplicates on declared PKs / grains", all(r["DUPLICATES"] == 0 for r in dupes),
              {r["PK"]: r["DUPLICATES"] for r in dupes})
    return results


def num(v):
    return None if v is None else decimal.Decimal(str(v).replace(",", "").strip())


def scenarios(t, rep):
    s = section("Behavioural checks: procedures, views, UDTFs")
    today = t.scalar("SELECT CURRENT_DATE()")
    first_this = today.replace(day=1)
    m2_end = first_this - dt.timedelta(days=1)
    m1_end = m2_end.replace(day=1) - dt.timedelta(days=1)
    m1, m2 = (m1_end.year, m1_end.month), (m2_end.year, m2_end.month)

    # --- SP_CUSTOMER_SCD2 ------------------------------------------------
    t.execute("""INSERT INTO BANKING_DW.STG_CUSTOMER
        SELECT CUSTOMER_ID, FIRST_NAME, LAST_NAME, DATE_OF_BIRTH, GENDER, MARITAL_STATUS, EMAIL_ADDRESS,
               PHONE_NUMBER, ADDRESS_LINE_1, ADDRESS_LINE_2, CITY, STATE_PROVINCE, POSTAL_CODE,
               COUNTRY_CODE, CUSTOMER_SEGMENT, RISK_SCORE, CREDIT_RATING, KYC_STATUS
        FROM BANKING_DW.DIM_CUSTOMER WHERE CUSTOMER_ID IN (1001, 1002, 1003)""")
    t.execute("UPDATE BANKING_DW.STG_CUSTOMER SET CUSTOMER_SEGMENT = 'PRIVATE' WHERE CUSTOMER_ID = 1001")
    t.execute("UPDATE BANKING_DW.STG_CUSTOMER SET KYC_STATUS = 'REVIEW' WHERE CUSTOMER_ID = 1003")
    t.execute("""INSERT INTO BANKING_DW.STG_CUSTOMER (CUSTOMER_ID, FIRST_NAME, LAST_NAME, CITY, STATE_PROVINCE,
        POSTAL_CODE, CUSTOMER_SEGMENT, RISK_SCORE, CREDIT_RATING, KYC_STATUS, MARITAL_STATUS, ADDRESS_LINE_1)
        VALUES (2001, 'Nora', 'Berg', 'Bergen', 'Vestland', '5003', 'RETAIL', 40, 'A', 'PENDING', 'S', 'Bryggen 1'),
               (2002, 'Ola', 'Dahl', 'Tromso', 'Troms', '9008', 'RETAIL', 35, 'BB', 'PENDING', 'M', 'Storgata 2')""")
    r = t.call("SP_CUSTOMER_SCD2", [900])
    rep.check(s, "SP_CUSTOMER_SCD2 returns P_CHANGED=2, P_NEW_ROWS=4 (2 new versions + 2 new customers)",
              r and r["P_CHANGED"] == 2 and r["P_NEW_ROWS"] == 4 and r["P_RETURN_CODE"] == 0, r)
    cnt = t.query("""SELECT COUNT(*) AS TOTAL, SUM(CASE WHEN CURRENT_FLAG = 'Y' THEN 1 ELSE 0 END) AS CURRENT_ROWS,
        COUNT(DISTINCT CUSTOMER_KEY) AS KEYS FROM BANKING_DW.DIM_CUSTOMER""")[0]
    rep.check(s, "DIM_CUSTOMER after SCD2: 19 rows, 17 current, unique AUTOINCREMENT keys",
              (cnt["TOTAL"], cnt["CURRENT_ROWS"], cnt["KEYS"]) == (19, 17, 19), cnt)
    v = t.query("""SELECT CURRENT_FLAG, CUSTOMER_SEGMENT, ONBOARDING_DATE, EFFECTIVE_TO FROM BANKING_DW.DIM_CUSTOMER
        WHERE CUSTOMER_ID = 1001 ORDER BY CUSTOMER_KEY""")
    rep.check(s, "customer 1001: old version expired, new version current with original ONBOARDING_DATE",
              [x["CURRENT_FLAG"] for x in v] == ["N", "Y"] and v[1]["CUSTOMER_SEGMENT"] == "PRIVATE"
              and str(v[1]["ONBOARDING_DATE"]) == "2015-06-01" and v[0]["EFFECTIVE_TO"].year != 9999, v)
    r = t.call("SP_CUSTOMER_SCD2", [901])
    rep.check(s, "SP_CUSTOMER_SCD2 re-run with same staging is a no-op", r["P_CHANGED"] == 0 and r["P_NEW_ROWS"] == 0, r)

    # --- SP_LOAD_DAILY_TRANSACTIONS ----------------------------------------
    t.execute(f"INSERT INTO BANKING_DW.DIM_EXCHANGE_RATES VALUES ('EUR', 'NOK', {lit(today)}, 11.5)")
    t.execute(f"""INSERT INTO BANKING_DW.STG_TRANSACTIONS (TRANSACTION_ID, LOAD_DATE, ACCOUNT_ID, TRANSACTION_DATE,
        TRANSACTION_TIME, TRANSACTION_TYPE, CHANNEL, TRANSACTION_AMOUNT, CURRENCY_CODE, MERCHANT_NAME, POSTING_DATE, VALUE_DATE)
        VALUES (5001, {lit(today)}, 'ACCT-NO-100001', {lit(today)}, '09:15:30', 'DEBIT', 'POS', 250.00, 'NOK', 'Rema 1000', {lit(today)}, {lit(today)}),
               (5002, {lit(today)}, 'ACCT-NO-100001', {lit(today)}, '12:00:00', 'CREDIT', 'ONLINE', 1000.00, 'NOK', NULL, {lit(today)}, {lit(today)}),
               (5003, {lit(today)}, 'ACCT-NO-100005', {lit(today)}, '13:30:00', 'DEBIT', 'ONLINE', 100.00, 'EUR', 'Amazon DE', {lit(today)}, {lit(today)}),
               (5004, {lit(today)}, 'ACCT-NO-100002', {lit(today)}, '16:45:00', 'TRANSFER', 'MOBILE', 300.00, 'NOK', NULL, {lit(today)}, {lit(today)}),
               (5005, {lit(today)}, 'ACCT-XX-999999', {lit(today)}, '17:00:00', 'DEBIT', 'ATM', 50.00, 'NOK', NULL, {lit(today)}, {lit(today)})""")
    r = t.call("SP_LOAD_DAILY_TRANSACTIONS", [today, 902])
    rep.check(s, "SP_LOAD_DAILY_TRANSACTIONS returns 4 inserted / 1 rejected / code 0",
              r and (r["P_ROWS_INSERTED"], r["P_ROWS_REJECTED"], r["P_RETURN_CODE"]) == (4, 1, 0), r)
    ft = t.query("""SELECT TRANSACTION_ID, DATE_KEY, TRANSACTION_TS, BASE_CURRENCY_AMOUNT, IS_INTERNATIONAL, CUSTOMER_KEY
        FROM BANKING_DW.FACT_TRANSACTION WHERE ETL_BATCH_ID = 902 ORDER BY TRANSACTION_ID""")
    eur = [x for x in ft if x["TRANSACTION_ID"] == 5003][0]
    first = ft[0]
    rep.check(s, "derived columns: DATE_KEY=YYYYMMDD, TRANSACTION_TS=date+time, EUR converted x11.5, IS_INTERNATIONAL=1",
              first["DATE_KEY"] == int(today.strftime("%Y%m%d"))
              and first["TRANSACTION_TS"] == dt.datetime.combine(today, dt.time(9, 15, 30))
              and num(eur["BASE_CURRENCY_AMOUNT"]) == decimal.Decimal("1150.00") and eur["IS_INTERNATIONAL"] == 1,
              {"DATE_KEY": first["DATE_KEY"], "TS": first["TRANSACTION_TS"], "EUR_BASE": eur["BASE_CURRENCY_AMOUNT"]})
    cur_key = t.scalar("SELECT CUSTOMER_KEY FROM BANKING_DW.DIM_CUSTOMER WHERE CUSTOMER_ID = 1001 AND CURRENT_FLAG = 'Y'")
    rep.check(s, "facts reference the current SCD2 CUSTOMER_KEY", first["CUSTOMER_KEY"] == cur_key,
              f"{first['CUSTOMER_KEY']} vs {cur_key}")
    err = t.query("SELECT ACCOUNT_ID, ERROR_REASON, BATCH_ID FROM BANKING_DW.STG_TRANSACTION_ERRORS")
    logs = t.query("SELECT LOG_LEVEL, LOG_MESSAGE FROM BANKING_DW.ETL_LOG WHERE BATCH_ID = 902 ORDER BY LOG_TS, LOG_LEVEL")
    rep.check(s, "rejected row in STG_TRANSACTION_ERRORS; 2 INFO rows in ETL_LOG",
              err == [{"ACCOUNT_ID": "ACCT-XX-999999", "ERROR_REASON": "INVALID_ACCOUNT", "BATCH_ID": 902}]
              and [x["LOG_LEVEL"] for x in logs] == ["INFO", "INFO"]
              and "Inserted: 4, Rejected: 1" in logs[-1]["LOG_MESSAGE"], logs)
    t.execute("ALTER TABLE BANKING_DW.DIM_EXCHANGE_RATES RENAME TO DIM_EXCHANGE_RATES_HIDDEN")
    try:
        r = t.call("SP_LOAD_DAILY_TRANSACTIONS", [today, 903])
    finally:
        t.execute("ALTER TABLE BANKING_DW.DIM_EXCHANGE_RATES_HIDDEN RENAME TO DIM_EXCHANGE_RATES")
    errlog = t.query("SELECT LOG_MESSAGE FROM BANKING_DW.ETL_LOG WHERE BATCH_ID = 903 AND LOG_LEVEL = 'ERROR'")
    rep.check(s, "EXCEPTION block: failure logged to ETL_LOG and returned as non-zero P_RETURN_CODE",
              r and r["P_RETURN_CODE"] != 0 and len(errlog) == 1 and errlog[0]["LOG_MESSAGE"].startswith("SQLCODE: "),
              {"result": r, "log": errlog})

    # --- SP_MONTHLY_SNAPSHOT -------------------------------------------------
    keys = {x["ACCOUNT_ID"]: x for x in t.query(
        """SELECT a.ACCOUNT_ID, a.ACCOUNT_KEY, a.PRODUCT_ID, a.BRANCH_ID, c.CUSTOMER_KEY FROM BANKING_DW.DIM_ACCOUNT a
           JOIN BANKING_DW.DIM_CUSTOMER c ON c.CUSTOMER_ID = a.CUSTOMER_ID AND c.CURRENT_FLAG = 'Y'
           WHERE a.ACCOUNT_ID IN ('ACCT-NO-100001', 'ACCT-NO-100005')""")}
    A, B = keys["ACCT-NO-100001"], keys["ACCT-NO-100005"]
    tid = [6000]

    def txn(acct, day, typ, amt, bal=None, ts=None, intl=0, base=None, cust=None, batch=1):
        tid[0] += 1
        ts = ts or dt.datetime.combine(day, dt.time(12, 0))
        t.execute(f"""INSERT INTO BANKING_DW.FACT_TRANSACTION (TRANSACTION_ID, TRANSACTION_DATE, TRANSACTION_TIME,
            TRANSACTION_TS, ACCOUNT_KEY, CUSTOMER_KEY, PRODUCT_ID, BRANCH_ID, DATE_KEY, TRANSACTION_TYPE,
            TRANSACTION_AMOUNT, BASE_CURRENCY_AMOUNT, RUNNING_BALANCE, IS_INTERNATIONAL, ETL_BATCH_ID)
            VALUES ({tid[0]}, {lit(day)}, {lit(ts.strftime('%H:%M:%S'))}, {lit(ts)}, {acct['ACCOUNT_KEY']},
            {cust or acct['CUSTOMER_KEY']}, {acct['PRODUCT_ID']}, {acct['BRANCH_ID']}, {day:%Y%m%d}, '{typ}',
            {amt}, {base if base is not None else amt}, {lit(bal)}, {intl}, {batch})""")
        return tid[0]

    d1, d2 = m1_end.replace(day=15), m2_end.replace(day=15)
    txn(A, d1, "CREDIT", 1000); txn(A, d1, "FEE", -10)
    txn(B, d1, "CREDIT", 2000); txn(B, d1, "FEE", -20)
    txn(A, d2, "CREDIT", 500); txn(A, d2, "DEBIT", -200); txn(A, d2, "FEE", -5)
    txn(B, d2, "FEE", -7)
    r1 = t.call("SP_MONTHLY_SNAPSHOT", [m1[0], m1[1], 910])
    r2 = t.call("SP_MONTHLY_SNAPSHOT", [m2[0], m2[1], 911])
    n_accts = t.scalar("SELECT COUNT(*) FROM BANKING_DW.DIM_ACCOUNT WHERE CURRENT_FLAG = 'Y' AND ACCOUNT_STATUS IN ('ACTIVE','DORMANT')")
    rep.check(s, f"SP_MONTHLY_SNAPSHOT merges one row per active account per month ({n_accts})",
              r1["P_ROWS_MERGED"] == n_accts and r2["P_ROWS_MERGED"] == n_accts, {"m1": r1, "m2": r2})
    snapA = t.query(f"""SELECT SNAPSHOT_MONTH_KEY, SNAPSHOT_DATE, OPENING_BALANCE, CLOSING_BALANCE, TOTAL_DEBITS,
        FEES_CHARGED, CUSTOMER_KEY FROM BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT WHERE ACCOUNT_KEY = {A['ACCOUNT_KEY']}
        ORDER BY SNAPSHOT_MONTH_KEY""")
    rep.check(s, "snapshot balances: m1 close 990; m2 opening = m1 close (corrected prev-snapshot date), close 1285",
              [num(x["CLOSING_BALANCE"]) for x in snapA] == [990, 1285] and num(snapA[1]["OPENING_BALANCE"]) == 990
              and snapA[0]["SNAPSHOT_DATE"] == m1_end, snapA)
    rep.check(s, "snapshot CUSTOMER_KEY comes from DIM_CUSTOMER (corrected a.CUSTOMER_KEY)",
              snapA[0]["CUSTOMER_KEY"] == A["CUSTOMER_KEY"], snapA[0]["CUSTOMER_KEY"])
    dormant = t.scalar(f"""SELECT MIN(DAYS_DORMANT) FROM BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT
        WHERE SNAPSHOT_MONTH_KEY = {m2[0] * 100 + m2[1]} AND ACCOUNT_KEY NOT IN ({A['ACCOUNT_KEY']}, {B['ACCOUNT_KEY']})""")
    rep.check(s, "accounts without transactions get DAYS_DORMANT = days in month", dormant == m2_end.day, dormant)
    r3 = t.call("SP_MONTHLY_SNAPSHOT", [m2[0], m2[1], 912])
    total = t.scalar("SELECT COUNT(*) FROM BANKING_DW.FACT_MONTHLY_ACCOUNT_SNAPSHOT")
    rep.check(s, "re-running a month is idempotent (MERGE updates, no duplicates)",
              total == 2 * n_accts and r3["P_ROWS_MERGED"] == n_accts, {"rows": total, "rerun": r3})

    # --- VW_BRANCH_PERFORMANCE -----------------------------------------------
    bp = t.query(f"""SELECT BRANCH_ID, SNAPSHOT_MONTH_KEY, CUMULATIVE_FEES_YTD, MOVING_AVG_VOLUME_3M, TOTAL_FEES_EARNED,
        TOTAL_DEPOSITS, PCT_OF_REGION_DEPOSITS, REGION_DEPOSIT_RANK, MONTH_LABEL FROM BANKING_DW.VW_BRANCH_PERFORMANCE
        WHERE BRANCH_ID IN ({A['BRANCH_ID']}, {B['BRANCH_ID']}) ORDER BY BRANCH_ID, SNAPSHOT_MONTH_KEY""")
    cum = {(x["BRANCH_ID"], x["SNAPSHOT_MONTH_KEY"]): num(x["CUMULATIVE_FEES_YTD"]) for x in bp}
    k1, k2 = m1[0] * 100 + m1[1], m2[0] * 100 + m2[1]
    same_year = m1[0] == m2[0]
    exp = {(A["BRANCH_ID"], k1): 10, (A["BRANCH_ID"], k2): 15 if same_year else 5,
           (B["BRANCH_ID"], k1): 20, (B["BRANCH_ID"], k2): 27 if same_year else 7}
    rep.check(s, "CUMULATIVE_FEES_YTD is per branch (and per year), not across branches", cum == exp,
              {f"{k[0]}/{k[1]}": v for k, v in cum.items()})
    mavgA = [num(x["MOVING_AVG_VOLUME_3M"]) for x in bp if x["BRANCH_ID"] == A["BRANCH_ID"]]
    rep.check(s, "MOVING_AVG_VOLUME_3M is per branch (A: m1 1010, m2 avg(1010, 705) = 857.5)",
              [round(v, 2) for v in mavgA] == [decimal.Decimal("1010"), decimal.Decimal("857.5")], mavgA)
    rep.check(s, "formatted columns are VARCHAR (TOTAL_DEPOSITS, PCT_OF_REGION_DEPOSITS)",
              isinstance(bp[0]["TOTAL_DEPOSITS"], str) and isinstance(bp[0]["PCT_OF_REGION_DEPOSITS"], str),
              {k: bp[0][k] for k in ("TOTAL_DEPOSITS", "PCT_OF_REGION_DEPOSITS", "MONTH_LABEL")})

    # --- VW_CUSTOMER_360 -----------------------------------------------------
    c360 = t.query("SELECT CUSTOMER_ID, TOTAL_ACCOUNTS, TOTAL_BALANCE FROM BANKING_DW.VW_CUSTOMER_360 ORDER BY CUSTOMER_ID")
    row = [x for x in c360 if x["CUSTOMER_ID"] == 1001][0]
    rep.check(s, "VW_CUSTOMER_360: one row per current active customer (17)", len(c360) == 17, len(c360))
    rep.check(s, "VW_CUSTOMER_360: TOTAL_BALANCE = sum of latest snapshot per account (1285.00), VARCHAR",
              num(row["TOTAL_BALANCE"]) == decimal.Decimal("1285") and row["TOTAL_ACCOUNTS"] == 2
              and isinstance(row["TOTAL_BALANCE"], str), row)

    # --- VW_REGULATORY_LARGE_TRANSACTIONS ------------------------------------
    big = txn(A, today, "CREDIT", 150000, batch=1)
    t.execute(f"""INSERT INTO BANKING_DW.FACT_TRANSACTION SELECT * REPLACE (2 AS ETL_BATCH_ID)
                  FROM BANKING_DW.FACT_TRANSACTION WHERE TRANSACTION_ID = {big}""") if t.name == "snowflake" else \
        t.execute(f"""INSERT INTO BANKING_DW.FACT_TRANSACTION (TRANSACTION_ID, TRANSACTION_DATE, TRANSACTION_TIME,
            TRANSACTION_TS, ACCOUNT_KEY, CUSTOMER_KEY, PRODUCT_ID, BRANCH_ID, DATE_KEY, TRANSACTION_TYPE,
            TRANSACTION_AMOUNT, BASE_CURRENCY_AMOUNT, IS_INTERNATIONAL, ETL_BATCH_ID)
            SELECT TRANSACTION_ID, TRANSACTION_DATE, TRANSACTION_TIME, TRANSACTION_TS, ACCOUNT_KEY, CUSTOMER_KEY,
            PRODUCT_ID, BRANCH_ID, DATE_KEY, TRANSACTION_TYPE, TRANSACTION_AMOUNT, BASE_CURRENCY_AMOUNT,
            IS_INTERNATIONAL, 2 FROM BANKING_DW.FACT_TRANSACTION WHERE TRANSACTION_ID = {big}""")
    reg = t.query("SELECT TRANSACTION_ID, ETL_BATCH_ID, REPORTING_CATEGORY, ROW_HASH FROM BANKING_DW.VW_REGULATORY_LARGE_TRANSACTIONS")
    rep.check(s, "VW_REGULATORY_LARGE_TRANSACTIONS dedups by TRANSACTION_ID (latest batch) and computes HASH()",
              len(reg) == 1 and reg[0]["ETL_BATCH_ID"] == 2 and reg[0]["REPORTING_CATEGORY"] == "THRESHOLD_EXCEEDED"
              and reg[0]["ROW_HASH"] is not None, reg)

    # --- UDTFs (macro replacements) -------------------------------------------
    for i in range(3):
        txn(B, today - dt.timedelta(days=i + 1), "CREDIT", 45000)
    rows = t.udtf("AML_STRUCTURING", [today, 30, 50000])
    rep.check(s, "AML_STRUCTURING: 3 credits of 45,000 within 80-100% of threshold -> 1 hit",
              len(rows) == 1 and rows[0]["TXN_COUNT"] == 3 and num(rows[0]["SORT_AMOUNT"]) == 135000, rows)
    txn(B, today - dt.timedelta(days=5), "CREDIT", 80000)
    txn(B, today - dt.timedelta(days=3), "DEBIT", 75000)
    rows = t.udtf("AML_RAPID_MOVEMENT", kwargs={"SCREENING_DATE": today})
    rep.check(s, "AML_RAPID_MOVEMENT (defaults for LOOKBACK_DAYS/AMOUNT_THRESHOLD): credit then debit 2 days later",
              len(rows) == 1 and rows[0]["DAYS_BETWEEN"] == 2, rows)
    new_key = t.scalar("SELECT CUSTOMER_KEY FROM BANKING_DW.DIM_CUSTOMER WHERE CUSTOMER_ID = 2001")
    txn(A, today, "DEBIT", 60000, intl=1, cust=new_key)
    rows = t.udtf("AML_NEW_CUSTOMER_INTL", [])
    rep.check(s, "AML_NEW_CUSTOMER_INTL (all defaults): newly onboarded customer with intl >= 50,000",
              len(rows) == 1 and rows[0]["CUSTOMER_ID"] == 2001 and rows[0]["DAYS_SINCE_ONBOARD"] == 0, rows)
    chk = today - dt.timedelta(days=10)
    txn(A, chk, "DEBIT", 100, bal=500, ts=dt.datetime.combine(chk, dt.time(10)))
    txn(A, chk, "DEBIT", 800, bal=-300, ts=dt.datetime.combine(chk, dt.time(11)))
    txn(B, chk, "CREDIT", 100, bal=1000, ts=dt.datetime.combine(chk, dt.time(9)))
    rows = t.udtf("DAILY_BALANCE_SUMMARY", [chk])
    rep.check(s, "DAILY_BALANCE_SUMMARY: latest txn per account, then aggregate (CHECKING: 2 accounts, total 700)",
              len(rows) == 1 and rows[0]["ACCOUNT_COUNT"] == 2 and num(rows[0]["TOTAL_BALANCE"]) == 700, rows)
    rows = t.udtf("DAILY_NEGATIVE_BALANCE_ALERT", [chk])
    rep.check(s, "DAILY_NEGATIVE_BALANCE_ALERT: account in overdraft reported once",
              len(rows) == 1 and rows[0]["ACCOUNT_ID"] == "ACCT-NO-100001" and num(rows[0]["SORT_AMOUNT"]) == -300, rows)
    expected = t.scalar(f"""SELECT COUNT(*) FROM BANKING_DW.FACT_TRANSACTION ft JOIN BANKING_DW.DIM_ACCOUNT a
        ON a.ACCOUNT_KEY = ft.ACCOUNT_KEY AND a.CURRENT_FLAG = 'Y' WHERE ft.CUSTOMER_KEY = {A['CUSTOMER_KEY']}
        AND ft.TRANSACTION_DATE BETWEEN DATEADD('day', -30, CURRENT_DATE()) AND CURRENT_DATE()""")
    rows = t.udtf("CUSTOMER_TXN_HISTORY", [1001])
    rep.check(s, "CUSTOMER_TXN_HISTORY(1001) with default 30-day window matches direct count",
              len(rows) == expected and expected > 0 and all(isinstance(x["TXN_DATE"], str) for x in rows),
              f"{len(rows)} vs {expected}")
    rows = t.udtf("CUSTOMER_TXN_HISTORY", kwargs={"CUST_ID": 1001, "TXN_TYPE": "CREDIT"})
    rep.check(s, "CUSTOMER_TXN_HISTORY TXN_TYPE filter", rows and all(x["TRANSACTION_TYPE"] == "CREDIT" for x in rows), len(rows))

    # --- Snowflake-only semantics ------------------------------------------
    if t.name == "snowflake":
        rep.check(s, "COLLATE 'en-ci': FIRST_NAME = 'ERIK' matches 'Erik'",
                  t.scalar("SELECT COUNT(*) FROM BANKING_DW.DIM_CUSTOMER WHERE FIRST_NAME = 'ERIK'") >= 1)
        f = t.query("SELECT TRIM(TO_CHAR(1234567.5, '999,999,990.00')) A, TRIM(TO_CHAR(0.5, '999,999,990.00')) B, "
                    "TRIM(TO_CHAR(-42, 'S999,999,990.00')) C")[0]
        rep.check(s, "TO_CHAR masks render like Teradata FORMAT", (f["A"], f["B"], f["C"]) == ("1,234,567.50", "0.50", "-42.00"), f)
    else:
        rep.note(s, "COLLATE 'en-ci' and TO_CHAR numeric masks", "SKIPPED",
                 "emulator strips collation and ignores TO_CHAR formats; verified only with --target snowflake")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--target", choices=["emulator", "snowflake"], default="emulator")
    ap.add_argument("--report", help="write JSON report to this path")
    args = ap.parse_args()

    rep = Report()
    lint(rep)
    t = connect(args.target)
    print(f"\nTarget: {t.name}")
    if t.name == "emulator":
        for _, _, why in EMULATOR_SHIMS:
            print(f"  emulator shim: {why}")
    deploy(t, rep)
    load_seeds(t, rep)
    reconcile(t, rep)
    results = checksums(t, rep)
    try:
        scenarios(t, rep)
    except Exception as exc:
        rep.check("Behavioural checks", "scenario run aborted", False, f"{type(exc).__name__}: {exc}")

    passed = sum(1 for i in rep.items if i["status"] == "PASS")
    print(f"\nSummary ({t.name}): {passed} passed, {len(rep.failed)} failed, "
          f"{sum(1 for i in rep.items if i['status'] in ('N/A', 'SKIPPED'))} not applicable/skipped")
    if args.report:
        Path(args.report).write_text(json.dumps({"target": t.name, "checks": rep.items, "checksums": results},
                                                indent=2, default=str) + "\n")
    sys.exit(1 if rep.failed else 0)


if __name__ == "__main__":
    main()
