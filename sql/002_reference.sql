-- =====================================================================
-- Couche REF : le referentiel.
-- Contrairement a raw, ces tables sont modifiables : ce sont des
-- donnees de reference que l'on corrige et enrichit dans le temps.
--
-- Modele en trois tables :
--   instrument -> l'entreprise / le titre (identifie par son ISIN)
--   listing    -> une cotation de cet instrument sur une place donnee
--   currency   -> les devises et leurs sous-unites (GBp, ZAc, ILA...)
--
-- Un instrument peut avoir plusieurs listings : Airbus cote a Paris,
-- Francfort et Madrid sous le meme ISIN mais trois symboles differents.
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS ref;


-- ---------------------------------------------------------------------
-- Devises et sous-unites
--
-- Londres cote en pence (GBp), soit des centiemes de livre (GBP).
-- Plutot que de coder cette regle en dur dans Python, on la declare
-- ici comme une donnee. On peut ainsi ajouter une nouvelle devise
-- sans toucher au code.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.currency (
    code            TEXT PRIMARY KEY,       -- 'EUR', 'GBp', 'CHF'
    major_code      TEXT NOT NULL,          -- l'unite principale : GBp -> GBP
    factor_to_major NUMERIC(20, 10) NOT NULL,  -- GBp -> GBP : 0.01
    description     TEXT
);

INSERT INTO ref.currency (code, major_code, factor_to_major, description) VALUES
    ('EUR', 'EUR', 1,    'Euro'),
    ('CHF', 'CHF', 1,    'Franc suisse'),
    ('GBP', 'GBP', 1,    'Livre sterling'),
    ('GBp', 'GBP', 0.01, 'Pence sterling : centieme de livre'),
    ('USD', 'USD', 1,    'Dollar americain'),
    ('SEK', 'SEK', 1,    'Couronne suedoise'),
    ('DKK', 'DKK', 1,    'Couronne danoise'),
    ('NOK', 'NOK', 1,    'Couronne norvegienne')
ON CONFLICT (code) DO NOTHING;


-- ---------------------------------------------------------------------
-- Instruments : une ligne par titre, identifie par son ISIN
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.instrument (
    isin            CHAR(12) PRIMARY KEY,   -- ex: NL0000235190
    name            TEXT NOT NULL,
    country         CHAR(2),                -- pays d'incorporation, ex: 'NL'
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- Un ISIN fait 12 caracteres : 2 lettres de pays, 9 alphanumeriques,
    -- 1 chiffre de controle. On refuse en base tout ce qui n'a pas cette
    -- forme : une erreur de saisie est bloquee ici, pas decouverte plus tard.
    CONSTRAINT ck_isin_format CHECK (isin ~ '^[A-Z]{2}[A-Z0-9]{9}[0-9]$')
);


-- ---------------------------------------------------------------------
-- Listings : une ligne par (instrument, place, fournisseur)
--
-- valid_from / valid_to permettent de gerer les changements de symbole.
-- Si Facebook devient Meta et passe de FB a META, on ferme la premiere
-- ligne et on en ouvre une seconde : l'historique reste interpretable.
-- valid_to a NULL signifie "toujours en vigueur".
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.listing (
    listing_id      BIGSERIAL PRIMARY KEY,
    isin            CHAR(12) NOT NULL REFERENCES ref.instrument (isin),
    source          TEXT NOT NULL,          -- 'yfinance', 'stooq'
    vendor_symbol   TEXT NOT NULL,          -- 'AIR.PA'
    mic             CHAR(4),                -- 'XPAR', 'XLON', 'XSWX'
    currency        TEXT NOT NULL REFERENCES ref.currency (code),
    is_primary      BOOLEAN NOT NULL DEFAULT TRUE,  -- cotation principale ?
    valid_from      DATE NOT NULL DEFAULT '1900-01-01',
    valid_to        DATE,

    CONSTRAINT uq_listing UNIQUE (source, vendor_symbol, valid_from)
);

CREATE INDEX IF NOT EXISTS ix_listing_isin ON ref.listing (isin);
CREATE INDEX IF NOT EXISTS ix_listing_symbol ON ref.listing (source, vendor_symbol);
