"""Ingestion des prix quotidiens depuis yfinance vers raw.price_daily.

Usage :
    python src/ingest_prices.py                  # depuis 2015-01-01
    python src/ingest_prices.py --start 2024-01-01
    python src/ingest_prices.py --symbols AIR.PA SAP.DE

Le script est IDEMPOTENT : le relancer deux fois de suite n'ajoute
aucune ligne la deuxieme fois. C'est la contrainte UNIQUE en base qui
le garantit, pas le code Python.
"""

import argparse
import datetime as dt
import hashlib
from pathlib import Path

import pandas as pd
import yfinance as yf

from db import get_connection

PROJECT_ROOT = Path(__file__).resolve().parent.parent
UNIVERSE_PATH = PROJECT_ROOT / "data" / "universe.csv"

SOURCE = "yfinance"

# Heure a laquelle on considere qu'un cours de cloture europeen est
# publiquement connaissable. 22h00 UTC est une approximation prudente
# (les places europeennes ferment entre 16h30 et 17h35 UTC).
# On affinera avec les vrais calendriers d'echange a l'etape 4.
AVAILABILITY_HOUR_UTC = 22


def compute_hash(row: dict) -> str:
    """Empreinte des valeurs numeriques d'une ligne.

    Si le fournisseur corrige un prix demain, le hash changera et la
    nouvelle ligne sera acceptee en base : on aura capture la revision.
    """
    parts = []
    for field in ["open", "high", "low", "close", "adj_close", "volume"]:
        value = row[field]
        parts.append("NULL" if value is None else f"{value:.6f}")
    raw_string = "|".join(parts)
    return hashlib.sha256(raw_string.encode("utf-8")).hexdigest()


def to_float(value):
    """Convertit en float, en transformant les valeurs manquantes en None.

    pandas represente les manquants par NaN, que PostgreSQL ne comprend
    pas. NULL est la bonne traduction cote base.
    """
    if value is None or pd.isna(value):
        return None
    return float(value)


def fetch_symbol(vendor_symbol: str, start: str, end: str) -> pd.DataFrame:
    """Recupere l'historique quotidien d'un symbole.

    auto_adjust=False est important : on veut a la fois le prix brut
    (Close) et le prix ajuste (Adj Close), pour pouvoir observer plus
    tard les reecritures retroactives de l'ajustement.
    """
    df = yf.download(
        vendor_symbol,
        start=start,
        end=end,
        interval="1d",
        auto_adjust=False,
        progress=False,
    )
    return df


def build_rows(vendor_symbol: str, currency: str, df: pd.DataFrame) -> list[tuple]:
    """Transforme le DataFrame yfinance en lignes pretes pour l'INSERT."""
    rows = []

    # Quand on telecharge un seul symbole, yfinance peut quand meme
    # renvoyer des colonnes a deux niveaux. On aplatit pour simplifier.
    if isinstance(df.columns, pd.MultiIndex):
        df.columns = df.columns.get_level_values(0)

    for index_date, r in df.iterrows():
        event_date = index_date.date()

        record = {
            "open": to_float(r.get("Open")),
            "high": to_float(r.get("High")),
            "low": to_float(r.get("Low")),
            "close": to_float(r.get("Close")),
            "adj_close": to_float(r.get("Adj Close")),
            "volume": to_float(r.get("Volume")),
        }

        # Une ligne sans prix de cloture n'a aucune valeur : on l'ignore.
        if record["close"] is None:
            continue

        available_at = dt.datetime.combine(
            event_date,
            dt.time(hour=AVAILABILITY_HOUR_UTC),
            tzinfo=dt.timezone.utc,
        )

        rows.append(
            (
                SOURCE,
                vendor_symbol,
                event_date,
                record["open"],
                record["high"],
                record["low"],
                record["close"],
                record["adj_close"],
                int(record["volume"]) if record["volume"] is not None else None,
                currency,
                available_at,
                compute_hash(record),
            )
        )

    return rows


INSERT_SQL = """
    INSERT INTO raw.price_daily (
        source, vendor_symbol, event_date,
        open, high, low, close, adj_close, volume,
        currency, available_at, payload_hash
    )
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    ON CONFLICT ON CONSTRAINT uq_price_daily DO NOTHING
"""


def ingest(symbols: list[str] | None, start: str, end: str) -> None:
    universe = pd.read_csv(UNIVERSE_PATH)
    if symbols:
        universe = universe[universe["vendor_symbol"].isin(symbols)]

    if universe.empty:
        print("Aucun symbole a traiter. Verifie data/universe.csv.")
        return

    with get_connection() as conn:
        for _, u in universe.iterrows():
            vendor_symbol = u["vendor_symbol"]
            started_at = dt.datetime.now(dt.timezone.utc)
            status, error_message = "success", None
            rows = []
            inserted = 0

            try:
                df = fetch_symbol(vendor_symbol, start, end)
                rows = build_rows(vendor_symbol, u["currency"], df)

                with conn.cursor() as cur:
                    for row in rows:
                        cur.execute(INSERT_SQL, row)
                        # rowcount vaut 1 si la ligne a ete inseree,
                        # 0 si elle a ete ignoree comme doublon.
                        inserted += cur.rowcount

            except Exception as exc:
                status = "error"
                error_message = str(exc)
                print(f"  ERREUR {vendor_symbol}: {exc}")

            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO raw.ingestion_log (
                        source, vendor_symbol, started_at, finished_at,
                        rows_fetched, rows_inserted, status, error_message
                    ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
                    """,
                    (
                        SOURCE,
                        vendor_symbol,
                        started_at,
                        dt.datetime.now(dt.timezone.utc),
                        len(rows),
                        inserted,
                        status,
                        error_message,
                    ),
                )

            conn.commit()
            print(f"{vendor_symbol:10s} recues={len(rows):5d} inserees={inserted:5d}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Ingestion des prix quotidiens.")
    parser.add_argument("--start", default="2015-01-01")
    parser.add_argument(
        "--end", default=(dt.date.today() + dt.timedelta(days=1)).isoformat()
    )
    parser.add_argument("--symbols", nargs="*", default=None)
    args = parser.parse_args()

    print(f"Ingestion {SOURCE} du {args.start} au {args.end}\n")
    ingest(args.symbols, args.start, args.end)


if __name__ == "__main__":
    main()
