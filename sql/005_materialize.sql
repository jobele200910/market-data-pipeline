-- =====================================================================
-- Etape 3b : optimisation.
--
-- Probleme constate : `staging.price_daily_eur` utilise une jointure
-- LATERAL, donc une sous-requete executee une fois par ligne. Comme
-- `staging.fx_rate_daily` etait une vue ordinaire, elle etait
-- integralement recalculee a chaque appel : 45 000 lignes de prix
-- multipliees par 9 000 taux, soit des centaines de millions
-- d'operations pour une seule requete.
--
-- Solution : transformer la vue des taux en VUE MATERIALISEE.
-- Une vue materialisee stocke physiquement son resultat et accepte
-- des index. La sous-requete LATERAL devient une recherche indexee.
--
-- CONTREPARTIE, a documenter dans le README : une vue materialisee
-- est un instantane. Elle ne se met pas a jour toute seule. Il faut
-- lancer REFRESH apres chaque ingestion de taux, sinon on travaille
-- sur des donnees perimees sans s'en apercevoir.
-- =====================================================================

-- PostgreSQL refuse de supprimer un objet dont un autre depend.
-- On demonte donc dans l'ordre inverse de la construction.
DROP VIEW IF EXISTS staging.missing_fx;
DROP VIEW IF EXISTS staging.price_daily_eur;
DROP VIEW IF EXISTS staging.fx_rate_daily;


-- ---------------------------------------------------------------------
-- Taux de change : derniere revision connue, stockee physiquement
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW staging.fx_rate_daily AS
SELECT DISTINCT ON (f.source, f.series_key, f.event_date)
    f.event_date,
    f.currency,
    f.base_currency,
    f.rate_per_eur,
    f.source,
    f.available_at,
    f.ingested_at
FROM raw.fx_rate_daily f
ORDER BY f.source, f.series_key, f.event_date,
         f.ingested_at DESC, f.id DESC;

-- Index unique : indispensable pour pouvoir utiliser un jour
-- REFRESH ... CONCURRENTLY, qui rafraichit sans bloquer les lecteurs.
CREATE UNIQUE INDEX ix_fx_staging_unique
    ON staging.fx_rate_daily (source, currency, event_date);

-- Index de recherche : c'est celui qui rend le LATERAL rapide.
-- L'ordre DESC correspond exactement au ORDER BY de la sous-requete,
-- ce qui permet a PostgreSQL de lire la premiere entree et s'arreter.
CREATE INDEX ix_fx_staging_lookup
    ON staging.fx_rate_daily (currency, event_date DESC);


-- ---------------------------------------------------------------------
-- Prix convertis en euro (identique, recree apres la suppression)
-- ---------------------------------------------------------------------
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

FROM staging.price_daily p
LEFT JOIN LATERAL (
    SELECT x.event_date, x.rate_per_eur
    FROM staging.fx_rate_daily x
    WHERE x.currency = p.currency
      AND x.event_date <= p.event_date
    ORDER BY x.event_date DESC
    LIMIT 1
) f ON TRUE;


-- ---------------------------------------------------------------------
-- Controle : lignes sans taux applicable
-- ---------------------------------------------------------------------
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


-- ---------------------------------------------------------------------
-- Index sur la couche raw : accelere le DISTINCT ON de staging.price_daily
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_price_daily_dedup
    ON raw.price_daily (source, vendor_symbol, event_date, ingested_at DESC);
