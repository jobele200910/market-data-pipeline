"""Ingestion des taux de change de reference de la BCE.

Usage :
    python src/ingest_fx.py
    python src/ingest_fx.py --currencies GBP CHF USD --start 2015-01-01

Source : ECB Data Portal, API SDMX publique et documentee.
    https://data.ecb.europa.eu

Contraste avec yfinance, a noter dans le README :
  - fournisseur officiel, API stable et versionnee
  - heure de publication connue (vers 16h00 heure de Bruxelles)
  - donnees revisables, ce que notre modele append-only capture
"""

import argparse
import datetime as dt
import hashlib
import io
from zoneinfo import ZoneInfo

import pandas as pd
import requests

from db import get_connection

SOURCE = "ecb"
BASE_CURRENCY = "EUR"

ECB_API = "https://data-api.ecb.europa.eu/service/data/EXR"

# La BCE calcule ses taux lors d'une concertation a 14h15 et les
# publie vers 16h00, heure de Bruxelles. Avant cet horaire, le taux
# du jour n'existe pas encore : c'est ce que traduit available_at.
PUBLICATION_HOUR_CET = 16
BRUSSELS = ZoneInfo("Europe/Brussels")

DEFAULT_CURRENCIES = ["GBP", "CHF", "USD"]


def series_key(currency: str) -> str:
    """Construit l'identifiant de serie SDMX.

    Structure : FREQ.CURRENCY.CURRENCY_DENOM.EXR_TYPE.EXR_SUFFIX
      D     = frequence quotidienne
      GBP   = devise cotee
      EUR   = devise de reference
      SP00  = taux de reference (spot)
      A     = moyenne / valeur observee
    """
    return f"D.{currency}.{BASE_CURRENCY}.SP00.A"


def fetch_series(currency: str, start: str) -> pd.DataFrame:
    """Telecharge une serie de taux au format CSV."""
    url = f"{ECB_API}/{series_key(currency)}"
    params = {"format": "csvdata", "startPeriod": start}

    response = requests.get(url, params=params, timeout=60)
    response.raise_for_status()

    df = pd.read_csv(io.StringIO(response.text))

    # La reponse contient de nombreuses colonnes de metadonnees.
    # Seules la date et la valeur nous interessent.
    keep = ["TIME_PERIOD", "OBS_VALUE"]
    missing = [c for c in keep if c not in df.columns]
    if missing:
        raise ValueError(
            f"Colonnes attendues absentes de la reponse BCE : {missing}. "
            f"Colonnes recues : {list(df.columns)}"
        )

    df = df[keep].dropna()
    df["TIME_PERIOD"] = pd.to_datetime(df["TIME_PERIOD"]).dt.date
    df["OBS_VALUE"] = df["OBS_VALUE"].astype(float)
    return df


def compute_hash(rate: float) -> str:
    return hashlib.sha256(f"{rate:.10f}".encode("utf-8")).hexdigest()


INSERT_SQL = """
    INSERT INTO raw.fx_rate_daily (
        source, series_key, currency, base_currency,
        event_date, rate_per_eur, available_at, payload_hash
    )
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
    ON CONFLICT ON CONSTRAINT uq_fx_rate_daily DO NOTHING
"""


def ingest(currencies: list[str], start: str) -> None:
    with get_connection() as conn:
        for currency in currencies:
            started_at = dt.datetime.now(dt.timezone.utc)
            status, error_message = "success", None
            inserted, fetched = 0, 0

            try:
                df = fetch_series(currency, start)
                fetched = len(df)

                with conn.cursor() as cur:
                    for _, row in df.iterrows():
                        event_date = row["TIME_PERIOD"]
                        rate = row["OBS_VALUE"]

                        # Heure de publication exprimee en heure de
                        # Bruxelles, donc automatiquement correcte
                        # ete comme hiver. Stockee en UTC par PostgreSQL.
                        available_at = dt.datetime.combine(
                            event_date,
                            dt.time(hour=PUBLICATION_HOUR_CET),
                            tzinfo=BRUSSELS,
                        )

                        cur.execute(
                            INSERT_SQL,
                            (
                                SOURCE,
                                series_key(currency),
                                currency,
                                BASE_CURRENCY,
                                event_date,
                                rate,
                                available_at,
                                compute_hash(rate),
                            ),
                        )
                        inserted += cur.rowcount

            except Exception as exc:
                status = "error"
                error_message = str(exc)
                print(f"  ERREUR {currency}: {exc}")

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
                        series_key(currency),
                        started_at,
                        dt.datetime.now(dt.timezone.utc),
                        fetched,
                        inserted,
                        status,
                        error_message,
                    ),
                )

            conn.commit()
            print(f"{currency:6s} recues={fetched:6d} inserees={inserted:6d}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Ingestion des taux BCE.")
    parser.add_argument("--start", default="2015-01-01")
    parser.add_argument("--currencies", nargs="*", default=DEFAULT_CURRENCIES)
    args = parser.parse_args()

    print(f"Ingestion BCE depuis {args.start}\n")
    ingest(args.currencies, args.start)


if __name__ == "__main__":
    main()
