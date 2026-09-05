-- =====================================================================
-- Etape 4c : couche propre et quarantaine.
--
-- Principe : on ne supprime JAMAIS rien de `raw`, qui reste le temoin
-- fidele de ce que le fournisseur a envoye. On ajoute une couche qui
-- ecarte les lignes fautives selon des regles ecrites, et une vue qui
-- montre ce qui a ete ecarte et pourquoi.
--
-- Cette tracabilite est le coeur du sujet : n'importe qui peut filtrer
-- des lignes, peu de gens peuvent dire lesquelles et pour quel motif.
--
-- Defaut identifie chez yfinance : quand une place est fermee, le
-- fournisseur renvoie une ligne de remplissage plutot que rien --
-- les quatre prix egaux a la cloture precedente et un volume nul.
-- Ce seul comportement explique trois de nos controles a la fois.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Qualification de chaque ligne : NULL si valide, motif sinon.
--
-- L'ordre du CASE compte : on retient le motif le plus grave.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW qc.row_quality AS
WITH calendar_coverage AS (
    -- Bornes du calendrier connu, par place. Sans ce garde-fou, une
    -- seance posterieure au dernier jour charge serait signalee a tort
    -- comme hors calendrier.
    SELECT mic, min(session_date) AS d0, max(session_date) AS d1
    FROM ref.exchange_session
    GROUP BY mic
)
SELECT
    p.*,
    CASE
        -- 1. Prix nul ou negatif : impossible, erreur certaine.
        WHEN p.open <= 0 OR p.high <= 0 OR p.low <= 0 OR p.close <= 0
            THEN 'prix nul ou negatif'

        -- 2. Barre OHLC incoherente : le plus haut doit dominer
        --    l'ouverture, la cloture et le plus bas.
        WHEN p.high < p.low
          OR p.high < p.open OR p.high < p.close
          OR p.low  > p.open OR p.low  > p.close
            THEN 'barre OHLC incoherente'

        -- 3. Jour ou la place etait fermee, d'apres le calendrier
        --    officiel de la bourse concernee.
        WHEN s.session_date IS NULL
         AND cc.d0 IS NOT NULL
         AND p.event_date BETWEEN cc.d0 AND cc.d1
            THEN 'hors calendrier de la place'

        ELSE NULL
    END AS quality_flag,

    -- Signal conserve mais NON bloquant : un volume nul sur une
    -- seance ouverte est suspect sans etre impossible (titre tres peu
    -- liquide, suspension de cotation). On le garde et on l'observe.
    (p.volume = 0) AS zero_volume

FROM staging.price_daily p
LEFT JOIN ref.exchange_session s
       ON s.mic = p.mic
      AND s.session_date = p.event_date
LEFT JOIN calendar_coverage cc
       ON cc.mic = p.mic;


-- ---------------------------------------------------------------------
-- Couche propre : ce que les consommateurs doivent utiliser
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW staging.price_daily_clean AS
SELECT
    event_date, isin, name, mic, source, vendor_symbol,
    currency, open, high, low, close, adj_close, volume,
    close_vendor, currency_vendor,
    available_at, ingested_at,
    zero_volume
FROM qc.row_quality
WHERE quality_flag IS NULL;


-- ---------------------------------------------------------------------
-- Quarantaine : ce qui a ete ecarte, et pourquoi
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW qc.excluded_rows AS
SELECT
    quality_flag AS reason,
    vendor_symbol,
    mic,
    event_date,
    open, high, low, close, volume
FROM qc.row_quality
WHERE quality_flag IS NOT NULL
ORDER BY quality_flag, vendor_symbol, event_date;

CREATE OR REPLACE VIEW qc.exclusion_summary AS
SELECT
    quality_flag        AS reason,
    count(*)            AS row_count,
    count(DISTINCT vendor_symbol) AS symbols,
    min(event_date)     AS first_date,
    max(event_date)     AS last_date
FROM qc.row_quality
WHERE quality_flag IS NOT NULL
GROUP BY quality_flag
ORDER BY row_count DESC;


-- =====================================================================
-- Controles sur la couche propre.
-- Par construction ils doivent renvoyer zero : c'est ce qui permet de
-- les classer BLOQUANT sans faire echouer la CI sur des anomalies
-- deja identifiees et traitees en amont.
-- =====================================================================
CREATE OR REPLACE VIEW qc.clean_ohlc_violations AS
SELECT vendor_symbol, event_date, open, high, low, close
FROM staging.price_daily_clean
WHERE high < low
   OR high < open OR high < close
   OR low  > open OR low  > close
   OR open <= 0 OR close <= 0;

CREATE OR REPLACE VIEW qc.clean_off_calendar AS
SELECT c.vendor_symbol, c.mic, c.event_date
FROM staging.price_daily_clean c
LEFT JOIN ref.exchange_session s
       ON s.mic = c.mic AND s.session_date = c.event_date
WHERE s.session_date IS NULL;


-- =====================================================================
-- Prix en euro : desormais construits sur la couche propre.
-- Les vues dependantes sont recreees a l'identique pour le reste.
-- =====================================================================
DROP VIEW IF EXISTS staging.missing_fx;
DROP VIEW IF EXISTS staging.price_daily_eur;

CREATE VIEW staging.price_daily_eur AS
SELECT
    p.event_date,
    p.isin,
    p.name,
    p.mic,
    p.source,
    p.vendor_symbol,

    p.currency        AS currency_local,
    p.close           AS close_local,
    p.adj_close       AS adj_close_local,

    CASE
        WHEN p.currency = 'EUR' THEN p.close
        ELSE round(p.close / f.rate_per_eur, 4)
    END AS close_eur,

    CASE
        WHEN p.currency = 'EUR' THEN p.adj_close
        ELSE round(p.adj_close / f.rate_per_eur, 4)
    END AS adj_close_eur,

    f.rate_per_eur    AS fx_rate_used,
    f.event_date      AS fx_rate_date,

    CASE
        WHEN p.currency = 'EUR' THEN 0
        ELSE (p.event_date - f.event_date)
    END AS fx_age_days,

    p.volume,
    p.available_at,
    p.ingested_at

FROM staging.price_daily_clean p
LEFT JOIN LATERAL (
    SELECT x.event_date, x.rate_per_eur
    FROM staging.fx_rate_daily x
    WHERE x.currency = p.currency
      AND x.event_date <= p.event_date
    ORDER BY x.event_date DESC
    LIMIT 1
) f ON TRUE;

CREATE VIEW staging.missing_fx AS
SELECT
    currency_local,
    count(*)          AS row_count,
    min(event_date)   AS first_date,
    max(event_date)   AS last_date
FROM staging.price_daily_eur
WHERE close_eur IS NULL
GROUP BY currency_local
ORDER BY currency_local;
