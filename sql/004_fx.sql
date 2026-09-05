-- =====================================================================
-- Etape 3 : taux de change BCE et conversion vers une devise commune.
--
-- Meme philosophie que pour les prix : la couche raw est append-only,
-- l'idempotence vient d'une contrainte UNIQUE incluant le hash des
-- valeurs, et les corrections du fournisseur creent de nouvelles
-- lignes plutot que d'ecraser les anciennes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Taux de change bruts
--
-- CONVENTION DE COTATION - a lire attentivement, c'est ici que se
-- glissent les erreurs les plus couteuses.
--
-- La BCE publie ses taux "a l'incertain depuis l'euro" : la valeur
-- donnee est le nombre d'unites de devise etrangere pour UN euro.
--   GBP = 0.85  signifie  1 EUR = 0.85 GBP
--
-- Pour convertir un montant en GBP vers des euros, on DIVISE :
--   121.14 GBP / 0.85 = 142.52 EUR
--
-- Multiplier au lieu de diviser donnerait 102.97 EUR : un resultat
-- parfaitement plausible, donc indetectable a l'oeil. On nomme la
-- colonne `rate_per_eur` pour que la convention soit inscrite dans
-- le schema lui-meme et non dans un commentaire qu'on oubliera.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.fx_rate_daily (
    id              BIGSERIAL PRIMARY KEY,

    source          TEXT        NOT NULL,   -- 'ecb'
    series_key      TEXT        NOT NULL,   -- 'D.GBP.EUR.SP00.A'
    currency        TEXT        NOT NULL,   -- devise cotee : 'GBP'
    base_currency   TEXT        NOT NULL,   -- devise de base : 'EUR'

    event_date      DATE        NOT NULL,   -- jour du taux
    rate_per_eur    NUMERIC(20, 10) NOT NULL,  -- unites de `currency` pour 1 EUR

    available_at    TIMESTAMPTZ NOT NULL,
    ingested_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    payload_hash    TEXT        NOT NULL,

    CONSTRAINT uq_fx_rate_daily
        UNIQUE (source, series_key, event_date, payload_hash),

    -- Un taux nul ou negatif n'a pas de sens et provoquerait une
    -- division par zero plus loin. On le refuse des l'entree.
    CONSTRAINT ck_fx_rate_positive CHECK (rate_per_eur > 0)
);

CREATE INDEX IF NOT EXISTS ix_fx_currency_date
    ON raw.fx_rate_daily (currency, event_date);


-- ---------------------------------------------------------------------
-- Vue staging : derniere revision connue de chaque taux
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW staging.fx_rate_daily AS
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


-- =====================================================================
-- Prix convertis en euro
--
-- Le probleme a resoudre : la BCE suit le calendrier TARGET, qui ferme
-- le Vendredi saint, le lundi de Paques et le 1er mai. Londres et
-- Zurich cotent certains de ces jours. Il existe donc des seances
-- boursieres sans taux publie le jour meme.
--
-- La regle retenue : utiliser le dernier taux connu A LA DATE DE LA
-- SEANCE. Jamais un taux posterieur, ce qui constituerait un
-- look-ahead bias (utiliser une information qui n'existait pas encore).
--
-- LATERAL permet cela : c'est une sous-requete qui peut faire
-- reference aux colonnes de la requete principale. Pour chaque ligne
-- de prix, elle va chercher le taux le plus recent dont la date est
-- inferieure ou egale a celle de la seance.
-- =====================================================================

CREATE OR REPLACE VIEW staging.price_daily_eur AS
SELECT
    p.event_date,
    p.isin,
    p.name,
    p.mic,
    p.source,
    p.vendor_symbol,

    -- Valeurs dans la devise locale (issues de l'etape 2)
    p.currency        AS currency_local,
    p.close           AS close_local,
    p.adj_close       AS adj_close_local,

    -- Conversion vers l'euro.
    -- L'euro n'a pas de taux publie contre lui-meme : cas traite a part.
    CASE
        WHEN p.currency = 'EUR' THEN p.close
        ELSE round(p.close / f.rate_per_eur, 4)
    END AS close_eur,

    CASE
        WHEN p.currency = 'EUR' THEN p.adj_close
        ELSE round(p.adj_close / f.rate_per_eur, 4)
    END AS adj_close_eur,

    -- Tracabilite de la conversion : quel taux, de quelle date.
    f.rate_per_eur    AS fx_rate_used,
    f.event_date      AS fx_rate_date,

    -- Anciennete du taux utilise, en jours.
    -- 0 = taux du jour meme. 3 = un vendredi applique a un lundi
    -- (week-end), ce qui est normal. Au-dela de 4 ou 5, il y a
    -- probablement un trou dans les donnees de change : ce controle
    -- sera branche sur les alertes qualite a l'etape 4.
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


-- =====================================================================
-- Controle : lignes de prix sans taux de change applicable.
--
-- Cas typique : une seance anterieure au debut de l'historique de
-- change telecharge. La conversion produit alors NULL, qui se
-- propagerait silencieusement dans tout calcul en aval.
-- =====================================================================

CREATE OR REPLACE VIEW staging.missing_fx AS
SELECT
    currency_local,
    count(*)          AS row_count,
    min(event_date)   AS first_date,
    max(event_date)   AS last_date
FROM staging.price_daily_eur
WHERE close_eur IS NULL
GROUP BY currency_local
ORDER BY currency_local;
