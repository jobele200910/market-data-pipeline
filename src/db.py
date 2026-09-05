"""Connexion a PostgreSQL.

Un seul endroit qui sait comment se connecter. Tous les autres scripts
importent get_connection() depuis ici. Si le mot de passe change, on ne
modifie qu'un fichier.
"""

import os
from pathlib import Path

import psycopg
from dotenv import load_dotenv

# Charge les variables du fichier .env situe a la racine du projet
PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env")


def get_connection() -> psycopg.Connection:
    """Ouvre une connexion a la base et la renvoie.

    A utiliser avec 'with', pour que la connexion se ferme toute seule :

        with get_connection() as conn:
            ...
    """
    return psycopg.connect(
        host=os.environ["POSTGRES_HOST"],
        port=os.environ["POSTGRES_PORT"],
        user=os.environ["POSTGRES_USER"],
        password=os.environ["POSTGRES_PASSWORD"],
        dbname=os.environ["POSTGRES_DB"],
    )


if __name__ == "__main__":
    # Test rapide : python src/db.py
    with get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT version();")
            print("Connexion OK ->", cur.fetchone()[0])
