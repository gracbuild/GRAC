"""Reads the workbook into plain rows keyed by the spec's field keys."""
import datetime
import openpyxl
from spec import ENTITIES

import os
# The populated registry workbook. Set ORG_REGISTRY_WORKBOOK, or put it
# beside this script as GRAC_Organization_Registry.xlsx.
WB_PATH = os.environ.get("ORG_REGISTRY_WORKBOOK",
                         os.path.join(os.path.dirname(os.path.abspath(__file__)), "GRAC_Organization_Registry.xlsx"))
HEADER_ROW = 4  # data sheets: row 4 holds the column headers

def norm(v):
    if v is None:
        return None
    if isinstance(v, datetime.datetime):
        return v.date().isoformat()
    if isinstance(v, datetime.date):
        return v.isoformat()
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    s = str(v).strip()
    return s or None

def load():
    wb = openpyxl.load_workbook(WB_PATH, data_only=True)
    data = {}
    for ent in ENTITIES:
        ws = wb[ent["sheet"]]
        headers = [norm(c.value) for c in ws[HEADER_ROW]]
        idx = {h: i for i, h in enumerate(headers) if h}
        rows = []
        for r in ws.iter_rows(min_row=HEADER_ROW + 1, values_only=True):
            vals = [norm(x) for x in r]
            if not any(vals):
                continue
            row = {"_sheet_row": None}
            for f in ent["fields"]:
                if f["app"]:
                    continue
                if f["label"] not in idx:
                    raise SystemExit(f"{ent['sheet']}: header not found: {f['label']!r}")
                row[f["key"]] = vals[idx[f["label"]]] if idx[f["label"]] < len(vals) else None
            rows.append(row)
        data[ent["key"]] = rows
        # every workbook header must be mapped (nothing silently dropped)
        mapped = {f["label"] for f in ent["fields"]}
        unmapped = [h for h in headers if h and h not in mapped]
        if unmapped:
            raise SystemExit(f"{ent['sheet']}: unmapped headers {unmapped}")
    # masters (sheet 15): row 4 = group names
    ws = wb["15 Masters & Codes"]
    groups = [norm(c.value) for c in ws[4]]
    masters = {g: [] for g in groups if g}
    for r in ws.iter_rows(min_row=5, values_only=True):
        for g, v in zip(groups, r):
            v = norm(v)
            if g and v and v not in masters[g]:
                masters[g].append(v)
    return data, masters
