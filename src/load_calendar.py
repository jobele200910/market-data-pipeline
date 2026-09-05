"""Chargement des calendriers d'echange dans ref.exchange_session.

Usage :
    python src/load_calendar.py
    python src/load_calendar.py --start 2015-01-01 --end 2026-12-31

La librairie exchange_calendars connait, pour chaque place, les jours
de cotation reels : jours feries nationaux, demi-seances du 24 et du
31 decembre, fermetures exceptionnelles.

Sans cette reference, impossible de distinguer une donnee manquante
d'un jour ou la bourse etait simplement fermee.
"""

import argparse
import datetime as dt

import exchange_calendars as xcals
import pandas as pd

from db import get_connection

# Les MIC utilises dans data/listings.csv.
# exchange_calendars nomme ses calendriers d'apres ces memes codes.
MICS = ["XPAR", "XETR", "XAMS", "XMIL", "XMAD", "XLON", "XSWX"]


INSERT_SQL = """
    INSERT INTO ref.exchange_session (mic, session_date)
    VALUES (%s, %s)
    ON CONFLICT (mic, session_date) DO NOTHING
"""


def load_calendars(mics: list[str], start: str, end: str) -> None:
    with get_connection() as conn:
        for mic in mics:
            try:
                calendar = xcals.get_calendar(mic)
                sessions = calendar.sessions_in_range(
                    pd.Timestamp(start), pd.Timestamp(end)
                )
            except Exception as exc:
                print(f"{mic:6s} ERREUR : {exc}")
                continue

            inserted = 0
            with conn.cursor() as cur:
                for session in sessions:
                    cur.execute(INSERT_SQL, (mic, session.date()))
                    inserted += cur.rowcount

            conn.commit()
            print(
                f"{mic:6s} seances={len(sessions):5d} inserees={inserted:5d}"
                f"  ({sessions[0].date()} -> {sessions[-1].date()})"
            )


def main() -> None:
    parser = argparse.ArgumentParser(description="Chargement des calendriers.")
    parser.add_argument("--start", default="2015-01-01")
    parser.add_argument("--end", default=dt.date.today().isoformat())
    parser.add_argument("--mics", nargs="*", default=MICS)
    args = parser.parse_args()

    print(f"Calendriers d'echange du {args.start} au {args.end}\n")
    load_calendars(args.mics, args.start, args.end)


if __name__ == "__main__":
    main()
