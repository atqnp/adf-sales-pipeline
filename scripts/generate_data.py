"""Generate the sample sales CSVs for the ADF lab (orders, customers, products, dates).

orders.csv deliberately contains a few dirty rows so the Mapping Data Flow
in Module 3 has something to do:
  - 2 rows with an empty order_id   -> removed by the Filter step
  - 3 duplicated order_ids          -> removed by the Aggregate (dedup) step
"""
import csv
import random
from datetime import date, datetime, timedelta
from pathlib import Path

random.seed(42)
OUT = Path(__file__).resolve().parent.parent / "data"
OUT.mkdir(exist_ok=True)

# END stays in the past: modified_at runs up to ~30h after an order, and a
# future modified_at would push the watermark ahead of real updates.
START, END = date(2026, 1, 1), date(2026, 10, 25)
REGIONS = ["Tokyo", "Osaka", "Kuala Lumpur", "Penang", "Singapore"]
SEGMENTS = ["Consumer", "Corporate", "Small Business"]
CATEGORIES = {
    "Electronics": [("Wireless Mouse", 2980), ("USB-C Hub", 4580), ("Mechanical Keyboard", 12800), ("27in Monitor", 38900)],
    "Office": [("A4 Paper 500", 690), ("Gel Pen 10pk", 980), ("Desk Organizer", 2480)],
    "Furniture": [("Ergonomic Chair", 45800), ("Standing Desk", 62000), ("Bookshelf", 15800)],
}


def write(name, header, rows):
    with open(OUT / name, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    print(f"{name}: {len(rows)} rows")


customers = [
    (f"C{i:04d}", f"Customer {i:04d}", random.choice(REGIONS), random.choice(SEGMENTS),
     (START - timedelta(days=random.randint(0, 900))).isoformat())
    for i in range(1, 201)
]
write("customers.csv", ["customer_id", "customer_name", "region", "segment", "signup_date"], customers)

products, n = [], 1
for cat, items in CATEGORIES.items():
    for pname, price in items:
        products.append((f"P{n:03d}", pname, cat, price))
        n += 1
write("products.csv", ["product_id", "product_name", "category", "list_price"], products)

dates, d = [], START
while d <= END:
    dates.append((d.strftime("%Y%m%d"), d.isoformat(), d.year, (d.month - 1) // 3 + 1, d.month,
                  d.strftime("%B"), d.isoweekday(), d.strftime("%A"), int(d.isoweekday() >= 6)))
    d += timedelta(days=1)
write("dates.csv", ["date_key", "date", "year", "quarter", "month", "month_name",
                    "day_of_week", "day_name", "is_weekend"], dates)

price = {p[0]: p[3] for p in products}
orders = []
for i in range(1, 2001):
    od = START + timedelta(days=random.randint(0, (END - START).days))
    pid = random.choice(products)[0]
    unit = round(price[pid] * random.choice([1, 1, 1, 0.9, 0.8]))
    modified = datetime.combine(od, datetime.min.time()) + timedelta(hours=random.randint(8, 30), minutes=random.randint(0, 59))
    orders.append([f"O{i:06d}", od.isoformat(), random.choice(customers)[0], pid,
                   random.randint(1, 5), unit, modified.isoformat(sep=" ")])

# Dirty rows for the Data Flow lab
orders.append(["", "2026-05-01", "C0001", "P001", 1, 2980, "2026-05-01 10:00:00"])
orders.append(["", "2026-06-15", "C0002", "P002", 2, 4580, "2026-06-15 11:00:00"])
for dup in random.sample(orders[:2000], 3):
    orders.append(list(dup))
write("orders.csv", ["order_id", "order_date", "customer_id", "product_id",
                     "quantity", "unit_price", "modified_at"], orders)
