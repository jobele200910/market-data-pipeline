# Journal de bord

Ce fichier note ou j'en suis, ce que j'ai appris, et ce qui devra
figurer dans le README final. Il sert a reprendre le projet apres une
pause et documente les decisions pour un lecteur exterieur.

---

## Etat actuel

Etape 3 en cours (taux de change BCE et conversion en euro).
Prochaine etape : 4 - controles qualite et calendriers d'echange.

---

## Ce qui est en place

**Etape 1 - Ingestion des prix**
- PostgreSQL 16 dans Docker, port 5433
- Schema `raw` append-only, trois horodatages : `event_date` (jour
  concerne), `available_at` (quand l'info etait connaissable),
  `ingested_at` (quand je l'ai chargee)
- 15 actions europeennes depuis 2015 via yfinance
- Idempotence par contrainte UNIQUE incluant `payload_hash` : rejouer
  n'insere rien, mais une correction du fournisseur cree une nouvelle
  ligne, donc la revision est capturee automatiquement
- `raw.ingestion_log` : une ligne par execution

**Etape 2 - Referentiel**
- Schema `ref` : `instrument` (par ISIN), `listing` (une cotation par
  place et fournisseur), `currency` (devises et sous-unites)
- `staging.price_daily` : derniere revision, rattachement a l'ISIN,
  GBp -> GBP, arrondi a 4 decimales
- `staging.unmapped_symbols` : rend visibles les symboles de `raw`
  absents du referentiel, qui disparaitraient sinon silencieusement

**Etape 3 - Taux de change**
- `raw.fx_rate_daily` : taux BCE, meme modele append-only
- `staging.price_daily_eur` : conversion en euro par jointure LATERAL
  sur le dernier taux connu a la date de seance
- `fx_age_days` : anciennete du taux applique, pour rendre visible le
  report de taux plutot que de le masquer
- `staging.missing_fx` : lignes sans taux applicable

---

## POINTS A INTEGRER AU README (etape 5)

### Limites connues et assumees
- **yfinance n'est pas une API officielle.** Non documentee, sujette
  au rate limiting et susceptible de casser sans preavis. Retenue pour
  la couverture europeenne gratuite ; la BCE illustre par contraste ce
  qu'apporte un fournisseur officiel.
- **Biais du survivant.** L'univers est fige sur la composition
  actuelle des indices. Les societes sorties de cote sur la periode
  sont absentes, ce qui biaise a la hausse toute etude de performance.
- **ISIN saisis manuellement.** Non sources aupres d'un referentiel
  officiel. A verifier sur Euronext / Deutsche Boerse / pages
  investisseurs. Lecon a expliciter : une donnee de reference se
  source, elle ne se saisit pas.
- **`available_at` des prix est une approximation** (22h00 UTC).
  Sera affine avec les vrais horaires de cloture par place.
- **Migrations SQL appliquees a la main.** Ne passe pas a l'echelle ;
  un outil de migration (Flyway, Alembic) suivrait quelles migrations
  ont deja tourne. Evolution identifiee.

### Decisions d'architecture a expliquer
- **Pourquoi trois horodatages** et ce que coute la bitemporalite.
- **Idempotence garantie en base, pas en Python** : la contrainte
  tient meme si quelqu'un insere par un autre chemin.
- **La regle GBp -> GBP est une donnee** (`ref.currency`) et non un
  `if` dans le code : modifiable sans toucher au code, auditable.
- **Instrument, listing et venue separes** : Airbus cote a Paris,
  Francfort et Madrid sous un meme ISIN. C'est ce qui permet
  d'ajouter un fournisseur sans rien casser.
- **Les oublis sont rendus visibles**, jamais silencieux :
  `unmapped_symbols`, `missing_fx`, `fx_age_days`. Une absence que
  personne ne remarque est le pire comportement possible.

### Pieges de donnees rencontres, avec exemples dates
- **GBp vs GBP.** AZN.L cotait 12114 le 27/08/2026, soit 121,14 GBP.
  Sans normalisation, tout classement ou ponderation est faux d'un
  facteur 100 et rien ne plante.
- **Bruit de virgule flottante venu de la source.** yfinance renvoie
  203.399994 pour 203.40. Choisir NUMERIC en base ne repare pas ce qui
  arrive deja approximatif : nettoye par arrondi en staging.
- **Convention de cotation FX.** La BCE cote a l'incertain depuis
  l'euro : la valeur est le nombre d'unites etrangeres pour 1 EUR, donc
  on DIVISE pour convertir vers l'euro. Multiplier donnerait un
  resultat plausible donc indetectable. La colonne se nomme
  `rate_per_eur` pour inscrire la convention dans le schema.
- **Calendriers differents par place.** Paris 2983 seances, Francfort
  et Milan 2962, Londres 2945, Zurich 2929 sur 2015-2026. Un controle
  de gaps compare au mauvais calendrier produit des fausses alertes.
- **Berchtoldstag** : les suisses demarrent au 05/01/2015, pas au 02.
- **TARGET n'est pas un calendrier boursier.** La BCE ne publie pas le
  Vendredi saint, le lundi de Paques ni le 1er mai, alors que certaines
  places cotent. D'ou le report du dernier taux connu, sans jamais
  utiliser un taux futur (look-ahead bias).

### Sections a ecrire
- Schema d'architecture (raw / ref / staging, et les flux)
- **"Ajouter une source"** avec un exemple reel : c'est la traduction
  directe de la reduction du time-to-production
- Data dictionary des tables et vues
- Runbook d'incident : "la source X n'a pas livre ce matin"
- Demarrage en une commande (`docker compose up`)

---

## Points ouverts

- [ ] Verifier les ISIN aupres de sources officielles
- [ ] NESN.SW a 2929 lignes, NOVN.SW 2928, meme calendrier : un jour
      manque. A tracer a l'etape 4.
- [ ] Confirmer la sortie de `fx_age_days > 3` et identifier les jours
      concernes

---

## Suite prevue

4. Controles qualite, calendriers d'echange, requete point-in-time
5. README, schema d'architecture, section "ajouter une source"
6. Donnee alternative (pageviews Wikipedia)
7. Reconciliation entre deux fournisseurs
8. Couche de service `get(...)` pour les chercheurs
9. Prototypage modele

---

## Rituel de reprise

```powershell
cd C:\Users\...\Documents\GitHub
docker compose up -d
.venv\Scripts\activate
docker exec -it mdp_postgres psql -U mdp -d marketdata -c "\dt raw.*"
```

Une commande a la fois : PowerShell met les lignes collees en attente
et les execute dans un ordre imprevisible.
