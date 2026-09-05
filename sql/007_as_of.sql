-- =====================================================================
-- Etape 4b : correction de la requete as-of.
--
-- Constat : la premiere version filtrait sur `ingested_at <= as_of`,
-- ce qui renvoyait zero ligne pour toute date anterieure a la creation
-- de la base. Le resultat etait correct mais inutilisable.
--
-- La cause est structurelle : notre historique a ete RECHARGE APRES
-- COUP (backfill), il n'a pas ete accumule au fil de l'eau. Deux
-- questions differentes se posent donc, et les deux sont legitimes :
--
--   1. "Qu'est-ce qui etait PUBLIQUEMENT CONNAISSABLE a cette date ?"
--      -> filtre sur available_at seul.
--      C'est la question du chercheur qui rejoue une strategie et
--      veut eviter le look-ahead bias.
--
--   2. "Que contenait NOTRE BASE a cette date ?"
--      -> filtre sur available_at ET ingested_at.
--      C'est la question de l'audit : reproduire a l'identique un
--      resultat produit ce jour-la, retards de chargement compris.
--
-- La fonction accepte donc un second parametre. Par defaut elle
-- repond a la question 1, qui est celle du cas d'usage courant.
-- =====================================================================

DROP FUNCTION IF EXISTS staging.price_as_of(TIMESTAMPTZ);

CREATE OR REPLACE FUNCTION staging.price_as_of(
    p_as_of              TIMESTAMPTZ,
    p_restrict_to_loaded BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    event_date      DATE,
    isin            CHAR(12),
    vendor_symbol   TEXT,
    currency        TEXT,
    close           NUMERIC,
    adj_close       NUMERIC,
    volume          BIGINT,
    available_at    TIMESTAMPTZ,
    ingested_at     TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $$
    WITH known AS (
        SELECT DISTINCT ON (r.source, r.vendor_symbol, r.event_date)
            r.event_date,
            r.vendor_symbol,
            r.source,
            r.currency,
            r.close,
            r.adj_close,
            r.volume,
            r.available_at,
            r.ingested_at
        FROM raw.price_daily r
        WHERE r.available_at <= p_as_of
          -- Le second filtre ne s'applique qu'en mode audit.
          AND (NOT p_restrict_to_loaded OR r.ingested_at <= p_as_of)
        ORDER BY r.source, r.vendor_symbol, r.event_date,
                 r.ingested_at DESC, r.id DESC
    )
    SELECT
        k.event_date,
        li.isin,
        k.vendor_symbol,
        c.major_code,
        round(k.close     * c.factor_to_major, 4),
        round(k.adj_close * c.factor_to_major, 4),
        k.volume,
        k.available_at,
        k.ingested_at
    FROM known k
    JOIN ref.listing li
          ON li.source = k.source
         AND li.vendor_symbol = k.vendor_symbol
    JOIN ref.currency c ON c.code = li.currency;
$$;


-- =====================================================================
-- Vue de detail des lignes suspectes signalees par les controles,
-- pour pouvoir les examiner sans reecrire la requete a chaque fois.
-- =====================================================================
CREATE OR REPLACE VIEW qc.suspect_rows AS
SELECT
    'prix nul'          AS issue,
    p.vendor_symbol,
    p.event_date,
    p.open, p.high, p.low, p.close, p.volume
FROM staging.price_daily p
WHERE p.open = 0 OR p.high = 0 OR p.low = 0 OR p.close = 0

UNION ALL

SELECT
    'volume nul'        AS issue,
    p.vendor_symbol,
    p.event_date,
    p.open, p.high, p.low, p.close, p.volume
FROM staging.price_daily p
WHERE p.volume = 0

ORDER BY vendor_symbol, event_date;
