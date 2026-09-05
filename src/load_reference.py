"""Chargement du referentiel (instruments et cotations) depuis les CSV.

Usage :
    python src/load_reference.py

Contrairement a l'ingestion des prix, ce script fait un UPSERT :
si une ligne existe deja, elle est mise a jour. C'est voulu, parce
qu'un referentiel se corrige (un nom mal orthographie, un MIC errone)
alors qu'un prix historique, lui, ne se reecrit jamais.
"""

from pathlib import Path

import pandas as pd

from db import get_connection

PROJECT_ROOT = Path(__file__).resolve().parent.parent
INSTRUMENTS_PATH = PROJECT_ROOT / "data" / "instruments.csv"
LISTINGS_PATH = PROJECT_ROOT / "data" / "listings.csv"


UPSERT_INSTRUMENT = """
    INSERT INTO ref.instrument (isin, name, country)
    VALUES (%s, %s, %s)
    ON CONFLICT (isin) DO UPDATE
        SET name = EXCLUDED.name,
            country = EXCLUDED.country,
            updated_at = now()
"""

UPSERT_LISTING = """
    INSERT INTO ref.listing (
        isin, source, vendor_symbol, mic, currency, is_primary, valid_from
    )
    VALUES (%s, %s, %s, %s, %s, %s, %s)
    ON CONFLICT ON CONSTRAINT uq_listing DO UPDATE
        SET isin = EXCLUDED.isin,
            mic = EXCLUDED.mic,
            currency = EXCLUDED.currency,
            is_primary = EXCLUDED.is_primary
"""


def load_reference() -> None:
    instruments = pd.read_csv(INSTRUMENTS_PATH)
    listings = pd.read_csv(LISTINGS_PATH)

    with get_connection() as conn:
        with conn.cursor() as cur:
            for _, r in instruments.iterrows():
                cur.execute(
                    UPSERT_INSTRUMENT,
                    (r["isin"].strip(), r["name"].strip(), r["country"].strip()),
                )

            for _, r in listings.iterrows():
                cur.execute(
                    UPSERT_LISTING,
                    (
                        r["isin"].strip(),
                        r["source"].strip(),
                        r["vendor_symbol"].strip(),
                        r["mic"].strip(),
                        r["currency"].strip(),
                        bool(r["is_primary"]),
                        r["valid_from"],
                    ),
                )

        conn.commit()

        # Verification : reste-t-il des symboles dans raw sans correspondance ?
        with conn.cursor() as cur:
            cur.execute(
                "SELECT source, vendor_symbol, row_count "
                "FROM staging.unmapped_symbols"
            )
            orphans = cur.fetchall()

    print(f"Instruments charges : {len(instruments)}")
    print(f"Cotations chargees  : {len(listings)}")

    if orphans:
        print("\nATTENTION - symboles presents dans raw mais absents du referentiel :")
        for source, symbol, n in orphans:
            print(f"  {source:10s} {symbol:12s} {n} lignes ignorees")
        print("Ces lignes n'apparaitront pas dans staging.price_daily.")
    else:
        print("\nAucun symbole orphelin : tout raw est rattache au referentiel.")


if __name__ == "__main__":
    load_reference()
