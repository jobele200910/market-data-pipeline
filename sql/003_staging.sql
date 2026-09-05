-- =====================================================================
-- Couche STAGING : la donnee brute rendue exploitable.
--
-- Trois traitements appliques ici :
--   1. Deduplication des revisions : raw peut contenir plusieurs lignes
--      pour un meme (source, symbole, date) si le fournisseur a corrige
--      ses chiffres. On ne garde que la plus recemment ingeree.
--   2. Rattachement au referentiel : on remplace le symbole du
--      fournisseur par l'ISIN, identifiant stable et universel.
--   3. Normalisation de devise : GBp -> GBP (facteur 0.01).
--
-- C'est une VUE, pas une table : elle ne stocke rien et se recalcule
-- a chaque interrogation. Toujours coherente avec raw, au prix d'un
-- peu de temps de calcul. On la materialisera si besoin plus tard.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS staging;

CREATE OR REPLACE VIEW staging.price_daily AS
WITH latest AS (
    -- DISTINCT ON est propre a PostgreSQL : il garde la PREMIERE ligne
    -- de chaque groupe, selon l'ordre du ORDER BY. En triant par
    -- ingested_at decroissant, on obtient la version la plus recente.
    SELECT DISTINCT ON (p.source, p.vendor_symbol, p.event_date)
        p.source,
        p.vendor_symbol,
        p.event_date,
        p.open, p.high, p.low, p.close, p.adj_close, p.volume,
        p.currency,
        p.available_at,
        p.ingested_at
    FROM raw.price_daily p
    ORDER BY p.source, p.vendor_symbol, p.event_date,
             p.ingested_at DESC, p.id DESC
)
SELECT
    l.event_date,
    li.isin,
    i.name,
    li.mic,
    l.source,
    l.vendor_symbol,

    -- Devise apres normalisation : une ligne GBp devient GBP
    c.major_code AS currency,

    -- Prix convertis dans l'unite principale, puis arrondis a 4 decimales.
    -- L'arrondi elimine le bruit de virgule flottante venu du fournisseur
    -- (203.399994 redevient 203.4). Le type NUMERIC garantit ensuite
    -- que ce nombre reste exact dans tous les calculs.
    round(l.open      * c.factor_to_major, 4) AS open,
    round(l.high      * c.factor_to_major, 4) AS high,
    round(l.low       * c.factor_to_major, 4) AS low,
    round(l.close     * c.factor_to_major, 4) AS close,
    round(l.adj_close * c.factor_to_major, 4) AS adj_close,

    -- Le volume est un nombre de titres : jamais converti.
    l.volume,

    -- On conserve la valeur d'origine : en cas de doute, on peut
    -- verifier ce que le fournisseur avait reellement envoye.
    l.close    AS close_vendor,
    l.currency AS currency_vendor,

    l.available_at,
    l.ingested_at

FROM latest l
JOIN ref.listing li
      ON li.source = l.source
     AND li.vendor_symbol = l.vendor_symbol
     AND l.event_date >= li.valid_from
     AND (li.valid_to IS NULL OR l.event_date < li.valid_to)
JOIN ref.instrument i ON i.isin = li.isin
JOIN ref.currency  c  ON c.code = li.currency;


-- =====================================================================
-- Controle : symboles presents dans raw mais absents du referentiel.
--
-- La vue ci-dessus utilise des JOIN internes : un symbole non
-- reference disparait silencieusement du resultat. C'est le pire
-- comportement possible, car personne ne remarque une absence.
-- Cette vue rend ces oublis visibles et sera branchee sur les
-- controles qualite a l'etape 4.
-- =====================================================================

CREATE OR REPLACE VIEW staging.unmapped_symbols AS
SELECT
    p.source,
    p.vendor_symbol,
    count(*)            AS row_count,
    min(p.event_date)   AS first_date,
    max(p.event_date)   AS last_date
FROM raw.price_daily p
LEFT JOIN ref.listing li
       ON li.source = p.source
      AND li.vendor_symbol = p.vendor_symbol
WHERE li.listing_id IS NULL
GROUP BY p.source, p.vendor_symbol
ORDER BY p.source, p.vendor_symbol;
