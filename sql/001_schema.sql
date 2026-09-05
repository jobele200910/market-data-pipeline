-- =====================================================================
-- Couche RAW : donnees brutes, jamais modifiees, jamais supprimees.
-- On n'ecrit ici qu'en AJOUT (append-only).
-- Si un fournisseur corrige une valeur, on ajoute une NOUVELLE ligne
-- au lieu d'ecraser l'ancienne. On garde ainsi l'historique complet
-- de ce que le fournisseur nous a dit, et quand il nous l'a dit.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS raw;

CREATE TABLE IF NOT EXISTS raw.price_daily (
    -- Identifiant technique auto-incremente
    id              BIGSERIAL PRIMARY KEY,

    -- ---- D'ou vient la donnee ----------------------------------------
    source          TEXT        NOT NULL,   -- 'yfinance', 'stooq', ...
    vendor_symbol   TEXT        NOT NULL,   -- le code TEL QUE le fournisseur l'ecrit
                                            -- ex: 'AIR.PA' chez yfinance

    -- ---- A quoi la donnee se rapporte --------------------------------
    event_date      DATE        NOT NULL,   -- jour de bourse concerne

    -- ---- Les valeurs -------------------------------------------------
    -- NUMERIC et pas FLOAT : NUMERIC est exact en decimal.
    -- Un FLOAT peut stocker 0.1 comme 0.09999999999999999, ce qui est
    -- inacceptable des qu'on manipule des prix.
    open            NUMERIC(20, 6),
    high            NUMERIC(20, 6),
    low             NUMERIC(20, 6),
    close           NUMERIC(20, 6),
    adj_close       NUMERIC(20, 6),         -- prix ajuste des dividendes/splits
    volume          BIGINT,
    currency        TEXT,                   -- 'EUR', 'GBp', 'CHF', ...

    -- ---- Les trois horodatages (le coeur du modele) -------------------
    -- available_at : a partir de quand cette information etait CONNAISSABLE.
    --   Sert a repondre "que savait-on le 15 mars ?" sans tricher.
    available_at    TIMESTAMPTZ NOT NULL,
    -- ingested_at : quand MOI je l'ai chargee en base.
    --   Sert au debug et au suivi de fraicheur.
    ingested_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- ---- Detection de revision ---------------------------------------
    -- Empreinte des valeurs (open/high/low/close/adj_close/volume).
    -- Deux lignes identiques ont le meme hash, deux lignes differentes non.
    payload_hash    TEXT        NOT NULL,

    -- ---- La contrainte qui fait tout le travail ----------------------
    -- Meme source + meme symbole + meme jour + memes valeurs
    --   => doublon refuse. Rejouer l'ingestion ne cree rien : IDEMPOTENT.
    -- Meme source + meme symbole + meme jour + valeurs DIFFERENTES
    --   => ligne acceptee. On vient de capturer une REVISION du fournisseur.
    CONSTRAINT uq_price_daily
        UNIQUE (source, vendor_symbol, event_date, payload_hash)
);

-- Index de lecture : on interroge presque toujours par symbole puis par date.
CREATE INDEX IF NOT EXISTS ix_price_daily_symbol_date
    ON raw.price_daily (vendor_symbol, event_date);

-- Index pour les requetes "as-of" (que savait-on a telle date ?)
CREATE INDEX IF NOT EXISTS ix_price_daily_available_at
    ON raw.price_daily (available_at);


-- =====================================================================
-- Journal des ingestions : une ligne par execution du script.
-- Permet de repondre a "le chargement de ce matin a-t-il tourne ?".
-- =====================================================================

CREATE TABLE IF NOT EXISTS raw.ingestion_log (
    id              BIGSERIAL PRIMARY KEY,
    source          TEXT        NOT NULL,
    vendor_symbol   TEXT,
    started_at      TIMESTAMPTZ NOT NULL,
    finished_at     TIMESTAMPTZ,
    rows_fetched    INTEGER,                -- lignes recues du fournisseur
    rows_inserted   INTEGER,                -- lignes reellement ajoutees
    status          TEXT        NOT NULL,   -- 'success' | 'error'
    error_message   TEXT
);
