"""Execution de tous les controles qualite, avec rapport en sortie.

Usage :
    python src/run_quality_checks.py

Code de sortie 0 si aucun controle bloquant ne remonte d'anomalie,
1 sinon. C'est ce qui permet de brancher ce script sur une CI
(integration continue) : un pipeline dont la qualite se degrade doit
faire echouer la construction, pas passer inapercu.

TROIS NIVEAUX, et la difference est une decision, pas une nuance :

  BLOQUANT   la donnee servie aux consommateurs est fausse.
             Porte sur la couche `clean`, qui doit etre irreprochable.

  A VERIFIER signal ambigu demandant un examen humain. Un saut de
             -22 % peut etre le Brexit ou un split mal applique ;
             seul un humain tranche. Rejeter automatiquement
             supprimerait les seances les plus interessantes.

  OBSERVE    anomalie connue, comprise et deja traitee en amont.
             Suivie pour detecter une derive, sans bloquer.
"""

from db import get_connection

# (nom lisible, vue, severite)
CHECKS = [
    # --- Bloquants : portent sur la couche propre, doivent valoir zero
    ("OHLC incoherent (clean)", "qc.clean_ohlc_violations", "BLOQUANT"),
    ("Hors calendrier (clean)", "qc.clean_off_calendar",    "BLOQUANT"),
    ("Symboles non mappes",     "staging.unmapped_symbols", "BLOQUANT"),
    ("Taux de change absent",   "staging.missing_fx",       "BLOQUANT"),

    # --- A verifier : demandent un arbitrage humain
    ("Seances manquantes",      "qc.missing_sessions",      "A VERIFIER"),
    ("Sauts de prix > 20%",     "qc.price_jumps",           "A VERIFIER"),

    # --- Observes : causes connues, traitees par la couche clean
    ("Lignes mises en quarantaine", "qc.excluded_rows",     "OBSERVE"),
    ("Prix figes (source brute)",   "qc.stale_prices",      "OBSERVE"),
]

SAMPLE_LIMIT = 5


def run_checks() -> int:
    failures = 0

    with get_connection() as conn:
        print(f"{'CONTROLE':30s} {'SEVERITE':12s} {'ANOMALIES':>10s}")
        print("-" * 56)

        results = []
        for label, view, severity in CHECKS:
            with conn.cursor() as cur:
                cur.execute(f"SELECT count(*) FROM {view}")
                count = cur.fetchone()[0]

            print(f"{label:30s} {severity:12s} {count:>10d}")

            if count > 0:
                results.append((label, view, severity, count))
                if severity == "BLOQUANT":
                    failures += 1

        # Repartition des exclusions par motif
        print("\n--- Motifs de mise en quarantaine")
        with conn.cursor() as cur:
            cur.execute(
                "SELECT reason, row_count, symbols, first_date, last_date "
                "FROM qc.exclusion_summary"
            )
            rows = cur.fetchall()
            if rows:
                for reason, n, symbols, d0, d1 in rows:
                    print(f"    {reason:30s} {n:5d} lignes, "
                          f"{symbols} symboles, {d0} -> {d1}")
            else:
                print("    aucune")

        # Detail des controles non nuls
        for label, view, severity, count in results:
            if severity == "OBSERVE":
                continue
            print(f"\n--- {label} ({severity}) : {count} anomalies")
            with conn.cursor() as cur:
                cur.execute(f"SELECT * FROM {view} LIMIT {SAMPLE_LIMIT}")
                columns = [d.name for d in cur.description]
                print("    " + " | ".join(columns))
                for row in cur.fetchall():
                    print("    " + " | ".join(str(v) for v in row))
            if count > SAMPLE_LIMIT:
                print(f"    ... et {count - SAMPLE_LIMIT} autres")

        # Volumetrie : combien de lignes survivent au nettoyage
        print("\n--- Volumetrie")
        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM staging.price_daily")
            total = cur.fetchone()[0]
            cur.execute("SELECT count(*) FROM staging.price_daily_clean")
            clean = cur.fetchone()[0]
        pct = 100.0 * clean / total if total else 0.0
        print(f"    brut  : {total:7d} lignes")
        print(f"    propre: {clean:7d} lignes ({pct:.2f} % conservees)")

        # Fraicheur, a titre indicatif
        print("\n--- Fraicheur (jours depuis la derniere seance)")
        with conn.cursor() as cur:
            cur.execute(
                "SELECT vendor_symbol, last_event_date, days_since_last_session "
                "FROM qc.freshness ORDER BY days_since_last_session DESC LIMIT 5"
            )
            for symbol, last_date, days in cur.fetchall():
                print(f"    {symbol:10s} {last_date}  ({days} jours)")

    print()
    if failures:
        print(f"ECHEC : {failures} controle(s) bloquant(s) en anomalie.")
        return 1

    print("Tous les controles bloquants sont au vert.")
    return 0


if __name__ == "__main__":
    raise SystemExit(run_checks())
