-- =====================================================================
-- Etape 4 : calendriers d'echange, controles qualite, requete as-of.
--
-- Jusqu'ici on ne pouvait detecter que ce qui etait present et faux.
-- Une ligne ABSENTE ne laisse aucune trace : pour la voir, il faut une
-- reference externe disant quels jours auraient du exister.
-- C'est le role des calendriers d'echange.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS qc;


-- ---------------------------------------------------------------------
-- Seances de bourse attendues, par place
-- Alimentee par src/load_calendar.py depuis la librairie
-- exchange_calendars (jours feries nationaux, demi-seances comprises).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.exchange_session (
    mic             CHAR(4) NOT NULL,
    session_date    DATE    NOT NULL,
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (mic, session_date)
);


-- =====================================================================
-- CONTROLE 1 - Couverture : ce que l'on a effectivement par symbole
-- =====================================================================
CREATE OR REPLACE VIEW qc.coverage AS
SELECT
    p.vendor_symbol,
    p.mic,
    p.currency,
    count(*)            AS row_count,
    min(p.event_date)   AS first_date,
    max(p.event_date)   AS last_date
FROM staging.price_daily p
GROUP BY p.vendor_symbol, p.mic, p.currency
ORDER BY p.vendor_symbol;


-- =====================================================================
-- CONTROLE 2 - Seances manquantes
--
-- Le controle le plus important du lot : il detecte une ABSENCE.
-- On borne la comparaison a la periode reellement couverte par chaque
-- symbole, sinon toutes les seances anterieures au premier jour
-- disponible seraient signalees a tort.
-- =====================================================================
CREATE OR REPLACE VIEW qc.missing_sessions AS
WITH coverage AS (
    SELECT vendor_symbol, mic, min(event_date) AS d0, max(event_date) AS d1
    FROM staging.price_daily
    GROUP BY vendor_symbol, mic
)
SELECT
    c.vendor_symbol,
    c.mic,
    s.session_date,
    to_char(s.session_date, 'Day') AS weekday
FROM coverage c
JOIN ref.exchange_session s
      ON s.mic = c.mic
     AND s.session_date BETWEEN c.d0 AND c.d1
LEFT JOIN staging.price_daily p
      ON p.vendor_symbol = c.vendor_symbol
     AND p.event_date = s.session_date
WHERE p.event_date IS NULL
ORDER BY c.vendor_symbol, s.session_date;


-- =====================================================================
-- CONTROLE 3 - Seances inattendues
--
-- L'inverse : une ligne de prix un jour ou la place etait fermee.
-- Signale soit une erreur du fournisseur, soit un calendrier de
-- reference incomplet. Les deux meritent une verification.
-- =====================================================================
CREATE OR REPLACE VIEW qc.unexpected_sessions AS
SELECT
    p.vendor_symbol,
    p.mic,
    p.event_date,
    to_char(p.event_date, 'Day') AS weekday,
    p.close
FROM staging.price_daily p
LEFT JOIN ref.exchange_session s
      ON s.mic = p.mic
     AND s.session_date = p.event_date
WHERE s.session_date IS NULL
ORDER BY p.vendor_symbol, p.event_date;


-- =====================================================================
-- CONTROLE 4 - Coherence interne des barres OHLC
--
-- Par construction, le plus haut de la seance doit etre superieur ou
-- egal a l'ouverture, a la cloture et au plus bas. Une violation est
-- une erreur certaine du fournisseur, pas une interpretation.
-- =====================================================================
CREATE OR REPLACE VIEW qc.ohlc_violations AS
SELECT
    p.vendor_symbol,
    p.event_date,
    p.open, p.high, p.low, p.close, p.volume,
    CASE
        WHEN p.high < p.low                       THEN 'high < low'
        WHEN p.high < p.open OR p.high < p.close  THEN 'high inferieur a open ou close'
        WHEN p.low  > p.open OR p.low  > p.close  THEN 'low superieur a open ou close'
        WHEN p.close <= 0 OR p.open <= 0          THEN 'prix nul ou negatif'
        WHEN p.volume < 0                         THEN 'volume negatif'
    END AS reason
FROM staging.price_daily p
WHERE p.high < p.low
   OR p.high < p.open OR p.high < p.close
   OR p.low  > p.open OR p.low  > p.close
   OR p.close <= 0 OR p.open <= 0
   OR p.volume < 0
ORDER BY p.vendor_symbol, p.event_date;


-- =====================================================================
-- CONTROLE 5 - Prix figes
--
-- Trois clotures identiques d'affilee sur une grande capitalisation
-- liquide est tres improbable. Signale typiquement un flux gele :
-- le fournisseur recopie la derniere valeur connue au lieu de
-- signaler une absence de donnee. Panne silencieuse par excellence.
-- =====================================================================
CREATE OR REPLACE VIEW qc.stale_prices AS
WITH seq AS (
    SELECT
        vendor_symbol,
        event_date,
        close,
        lag(close, 1) OVER w AS close_1,
        lag(close, 2) OVER w AS close_2
    FROM staging.price_daily
    WINDOW w AS (PARTITION BY vendor_symbol ORDER BY event_date)
)
SELECT vendor_symbol, event_date, close
FROM seq
WHERE close = close_1 AND close = close_2
ORDER BY vendor_symbol, event_date;


-- =====================================================================
-- CONTROLE 6 - Sauts de prix anormaux
--
-- Variation journaliere superieure a 20 % sur le prix ajuste.
-- Ce controle ne prouve rien a lui seul : un vrai choc de marche
-- produit le meme signal qu'une erreur de donnee. Il sert a
-- declencher une verification humaine, pas a rejeter automatiquement.
-- Une division par un split non pris en compte apparait typiquement ici.
-- =====================================================================
CREATE OR REPLACE VIEW qc.price_jumps AS
WITH returns AS (
    SELECT
        vendor_symbol,
        event_date,
        adj_close,
        lag(adj_close) OVER (
            PARTITION BY vendor_symbol ORDER BY event_date
        ) AS prev_adj_close
    FROM staging.price_daily
)
SELECT
    vendor_symbol,
    event_date,
    prev_adj_close,
    adj_close,
    round((adj_close / prev_adj_close - 1) * 100, 2) AS pct_change
FROM returns
WHERE prev_adj_close > 0
  AND abs(adj_close / prev_adj_close - 1) > 0.20
ORDER BY abs(adj_close / prev_adj_close - 1) DESC;


-- =====================================================================
-- CONTROLE 7 - Fraicheur
--
-- Combien de jours se sont ecoules depuis la derniere seance chargee.
-- Repond a "le chargement de ce matin a-t-il vraiment eu lieu ?".
-- =====================================================================
CREATE OR REPLACE VIEW qc.freshness AS
SELECT
    vendor_symbol,
    max(event_date)                          AS last_event_date,
    current_date - max(event_date)           AS days_since_last_session,
    max(ingested_at)                         AS last_ingested_at
FROM staging.price_daily
GROUP BY vendor_symbol
ORDER BY days_since_last_session DESC;


-- =====================================================================
-- REQUETE AS-OF : reconstruire ce que l'on savait a un instant donne
--
-- C'est l'aboutissement des trois horodatages poses a l'etape 1.
-- Deux filtres, et les deux sont necessaires :
--
--   available_at <= as_of : l'information etait publiquement
--       connaissable. Un cours de cloture du 15 mars n'existait pas
--       a 9h le 15 mars.
--   ingested_at <= as_of  : nous l'avions effectivement en base.
--       Si on charge en retard, on ne peut pas pretendre l'avoir eue
--       plus tot.
--
-- Le DISTINCT ON garde ensuite la derniere REVISION connue a cette
-- date, et non la revision actuelle. Rejouer une etude au 3 mars 2020
-- redonne donc exactement les chiffres dont on disposait ce jour-la,
-- corrections ulterieures exclues.
-- =====================================================================
CREATE OR REPLACE FUNCTION staging.price_as_of(p_as_of TIMESTAMPTZ)
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
          AND r.ingested_at  <= p_as_of
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
