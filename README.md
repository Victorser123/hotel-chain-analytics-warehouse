# Hotel Chain Analytics Warehouse

Data warehouse and analytics layer for an 8-property hotel chain in Peru. Star schema on PostgreSQL, fed by a logged ETL pipeline, serving executive reporting and Power BI dashboards.

---

## Context

Commercial reporting ran from spreadsheets assembled manually each month out of a legacy PMS export. This repository is the schema, pipeline, and query layer that replaced that process with a queryable warehouse.

The work covers three things a data role is usually judged on separately:

- **Modelling** — a dimensional schema that survives the quirks of an untyped legacy source
- **Engineering** — an idempotent, logged, restartable load pipeline
- **Analytics** — reporting views and queries that answer questions the business actually asks

---

## Scale

| | |
|---|---|
| Properties | 8 operating |
| Customers | ~48,000 |
| Bookings | ~70,000 |
| Room-nights | ~130,000 |
| History | 2022 – present |

---

## Architecture

Medallion layout: raw staging, normalised core, pre-aggregated reporting.

```
SOURCE         BRONZE             SILVER              GOLD

┌──────────┐   ┌──────────────┐   ┌──────────────────┐   ┌───────────────────┐
│ Legacy   │   │ bronze_      │   │ clientes         │   │ mv_cliente_       │
│ PMS      │──►│ reservas_raw │──►│ reservas         │──►│ metricas          │
│          │   │              │   │ reservas_detalle │   │ v_ocupabilidad_*  │
│ Excel    │   │ untyped      │   │ hoteles          │   │ v_produccion_*    │
│ export   │   │ mirror       │   │ + 4 dimensions   │   │ v_health_check    │
└──────────┘   └──────────────┘   └──────────────────┘   └───────────────────┘

Pipeline:  delete_bronze_rango()  →  batch insert  →  refresh_silver()  →  refresh_gold()
```

### Star schema

```
                          ┌────────────────┐
                          │   dim_fecha    │
                          │   2021 – 2035  │
                          └───────┬────────┘
                                  │
  ┌────────────┐          ┌───────▼────────┐          ┌────────────┐
  │  hoteles   │─────────►│                │◄─────────│  clientes  │
  └────────────┘          │    reservas    │          └────────────┘
                          │ booking header │
  ┌────────────┐          │                │          ┌────────────┐
  │ dim_asesor │─────────►│                │◄─────────│ dim_canal  │
  └────────────┘          └───────┬────────┘          └────────────┘
                                  │ 1:N
                          ┌───────▼─────────────┐
                          │ reservas_detalle    │
                          │    room-night       │
                          └───────▲─────────────┘
                                  │
                       ┌──────────┴───────────┐
                       │ dim_tipo_habitacion  │
                       └──────────────────────┘
```

---

## Design decisions worth explaining

### Composite primary key

The source PMS recycles booking IDs every calendar year. The booking ID alone is not unique, so the primary key on `reservas` is `(id_reserva_origen, anio_creacion)` and every child foreign key carries both columns. Identifying this before the first production load avoided silently merging bookings from different years.

### Two measurement frames

Hospitality reporting runs on two clocks:

- **Occupancy** — attributed to the night of stay
- **Production** — attributed to the date the booking was sold

A booking made in January for a July stay belongs to January production and July occupancy. Keeping the two frames separate is what makes the numbers reconcile, so they live in separate view files and never mix.

### Deliberate denormalisation against fan-out

Joining the booking header to its room-night detail multiplies header rows by the number of nights. Any `SUM()` over a header column after that join is inflated. Rather than relying on every future query author to remember this, the ETL computes booking totals, check-in, check-out and night counts from the detail rows and writes them back to the header — so header-grain reports never need the join at all.

### Room-number collision offset

The natural unique key `(booking, year, date, room)` is violated by legitimate source rows where one room is billed twice on the same night under different SKUs. Dropping those rows would lose revenue; dropping the constraint would lose integrity. The ETL detects collisions with `ROW_NUMBER()` and offsets the room number by +1000 per duplicate, keeping both.

### Dimension-driven filtering

Non-lodging SKUs — event boxes, entrance tickets, zones — were originally excluded by a hardcoded 15-item `NOT IN` list copy-pasted into every occupancy view. Adding one SKU meant editing all of them. `dim_tipo_habitacion` categorises them once; the views filter on the category.

### Always joining on the whole composite key

The corollary of the composite primary key, and the easiest thing in this schema to get wrong. `reservas_detalle` carries a composite foreign key, so a join written as

```sql
JOIN reservas_detalle rd ON r.id_reserva_origen = rd.id_reserva_origen
```

cross-multiplies every recycled booking against the detail rows of its namesakes in other years. Nothing errors; revenue simply inflates, and it inflates most in the multi-year comparisons where the recycling is densest. Both key columns, every time.

### Joining on IDs, never on names

The source system exports the same sales agent under several accent-corrupted spellings. `dim_asesor` is keyed on the source user ID, and every join uses it. A name-based join fragments one person into several rows and quietly understates their performance.

### Functional indexes on the staging layer, and why they need a wrapper

Bronze stores dates as text in `DD/MM/YYYY` to stay a faithful mirror of the untyped source. The incremental delete filters on the parsed date, and a plain index on the text column is not usable for that predicate — the index has to be built on the same expression the planner sees.

Indexing `TO_DATE()` directly does not work either:

```
ERROR: functions in index expression must be marked IMMUTABLE
```

`TO_DATE()` is only `STABLE`, because for some format masks its result depends on session settings. `'DD/MM/YYYY'` has no such dependence, so `f_fecha()` wraps that single call and is declared `IMMUTABLE`. The delete predicate calls the same wrapper — an expression index is only usable when the query spells the expression exactly the way the index was built. `EXPLAIN` on the delete now reports an Index Scan with `Index Cond: (f_fecha("FECHA") >= ... AND f_fecha("FECHA") <= ...)`.

---

## Repository structure

Laid out by medallion layer, so a file's position states which layer it belongs to.

```
hotel-chain-analytics-warehouse/
├── sql/
│   ├── bronze/
│   │   ├── 01_landing_table.sql       Landing table + immutable date parser
│   │   ├── 02_indexes.sql             Expression indexes for the reload window
│   │   └── 03_delete_rango.sql        delete_bronze_rango()
│   ├── silver/
│   │   ├── 01_core_tables.sql         Fact and entity tables, composite key
│   │   ├── 02_dimensions.sql          Dimension DDL + static loads
│   │   ├── 03_indexes.sql             Index strategy with per-index rationale
│   │   ├── 04_refresh_silver.sql      refresh_silver()
│   │   └── 05_derived_dimensions.sql  Agent and room-type loads (post-pipeline)
│   ├── gold/
│   │   ├── 01_mv_cliente_metricas.sql Customer lifetime metrics
│   │   ├── 02_fact_reservas.sql       Flat room-night fact for the BI layer
│   │   ├── 03_occupancy_views.sql     Stay-date reporting
│   │   ├── 04_production_views.sql    Sale-date reporting and agent ranking
│   │   ├── 05_refresh_gold.sql        refresh_gold()
│   │   └── 06_quality_views.sql       13 automated health checks
│   └── ops/
│       ├── etl_log.sql                Audit log written by every pipeline step
│       └── grants_rls.sql             Role model, RLS, PII containment
└── queries/
    ├── 01_daily_occupancy_pivot.sql
    ├── 02_yoy_multiyear_comparison.sql
    ├── 03_post_stay_survey_list.sql
    ├── 04_property_vs_network_adr.sql
    └── 05_repeat_guest_intervals.sql
```

### Execution order

The dimensional layer has a genuine circular dependency: two dimensions derive their contents from loaded fact data. The bootstrap is therefore two-phase, with the derived loads isolated in their own file rather than mixed into the DDL:

```bash
psql "$DB" -f sql/ops/etl_log.sql
psql "$DB" -f sql/bronze/01_landing_table.sql
psql "$DB" -f sql/bronze/02_indexes.sql
psql "$DB" -f sql/bronze/03_delete_rango.sql
psql "$DB" -f sql/silver/01_core_tables.sql
psql "$DB" -f sql/silver/02_dimensions.sql
psql "$DB" -f sql/silver/03_indexes.sql
psql "$DB" -f sql/silver/04_refresh_silver.sql
#   load the property master and the first bronze batch here
psql "$DB" -c "SELECT * FROM refresh_silver(3.75);"
psql "$DB" -f sql/silver/05_derived_dimensions.sql
psql "$DB" -f sql/gold/01_mv_cliente_metricas.sql
psql "$DB" -f sql/gold/02_fact_reservas.sql
psql "$DB" -f sql/gold/03_occupancy_views.sql
psql "$DB" -f sql/gold/04_production_views.sql
psql "$DB" -f sql/gold/05_refresh_gold.sql
psql "$DB" -f sql/gold/06_quality_views.sql
psql "$DB" -f sql/ops/grants_rls.sql
```

---

## The ETL pipeline

Four functions, callable as RPC endpoints, run in sequence on every load:

| Step | Function | What it does |
|---|---|---|
| 1 | `delete_bronze_rango(f_min, f_max)` | Clears the reload window from staging, filtered on stay date |
| 2 | *(external loader)* | Posts raw rows to bronze in batches |
| 3 | `refresh_silver(tc_dolar)` | Deduplicates, normalises currency, backfills header aggregates |
| 4 | `refresh_gold()` | Refreshes `mv_cliente_metricas` and `fact_reservas` |

Every function writes an `etl_log` row on entry and updates it on exit with row counts and elapsed seconds. The `EXCEPTION` block records `SQLERRM` before re-raising, so a failed load leaves a diagnosable trail rather than vanishing.

The exchange rate is a **parameter**, not a stored constant, so historical reloads replay at the rate that was in force instead of silently repricing old bookings.

### Failure modes the design guards against

**Wrong date column in incremental deletes.** Filtering the reload window by creation date rather than stay date removes records that were created inside the window but belong outside it, with no error raised. The function filters on stay date, and the reason is commented inline.

**Deduplicating on a recycled key.** When the source recycles booking IDs across years, deduplicating on the ID alone collapses distinct bookings into one. The dedup key includes the year, and row counts are reconciled against the staging layer after every load.

---

## Data quality monitoring

`v_health_check` runs thirteen validations and returns a count plus a traffic-light status for each, so a single `SELECT` answers whether today's data can be trusted:

referential integrity (orphaned bookings, orphaned detail rows, missing hotels) · value sanity (negative amounts, outlier totals, impossible date ranges) · dimension completeness (unenriched hotels, plus channels, agents and room types present in the data and absent from their dimension) · uniqueness (duplicate national IDs) · load integrity (Bronze-to-Silver row reconciliation) · pipeline freshness (last load status and age)

Checks are written against the *fact* tables, not the dimensions. An earlier version counted `dim_canal` rows flagged unclassified — but that dimension loads from a fixed seed list in which no row carries that value, so the count was structurally always zero and the check could never fire. What has to be detected is a value present in the data and missing from the dimension.

Thresholds are set per check rather than globally. An orphaned record is critical at any count because it means referential integrity broke. A hotel without a city is a warning — a new property simply has not been enriched yet.

`v_carga_stats` tracks success rate and duration trend per process over a rolling 30 days. A creeping average duration is the early warning that a step is about to time out.

---

## Analytical queries

| Query | Question it answers | Techniques |
|---|---|---|
| `01_daily_occupancy_pivot` | Today's occupancy and revenue at every property, side by side | Conditional aggregation with `FILTER (WHERE)`, aggregate-safe dimension carry with `MAX()` |
| `02_yoy_multiyear_comparison` | How does this month compare against the same month in prior years? | Multi-year conditional pivot, null-safe growth rate |
| `03_post_stay_survey_list` | Which guests just checked out, and what is a usable number for each? | `DISTINCT ON` for one row per guest, regex phone normalisation, `split_part` name extraction |
| `04_property_vs_network_adr` | How does each property's nightly rate compare against the chain? | Uncorrelated scalar subquery as an explicit denominator |
| `05_repeat_guest_intervals` | Among guests who came back, how far apart are their stays? | Self-join on ordered stays, `ROW_NUMBER` and `COUNT(*) OVER`, post-window filtering |

Seasonality in this chain is pronounced, which is why the multi-year query compares like month against like month rather than against the previous month.

---

## Tech stack

PostgreSQL 15 on Supabase · PL/pgSQL for the pipeline · PostgREST for RPC invocation · Excel VBA loader · Power BI consuming the gold layer

---

## Notes

The SQL is published; the data is not. Business targets, customer records and the operator's name have been excluded or replaced. Numeric IDs appearing in query filters are internal keys with no external meaning.

Two things a reader should know before running this against real data: the landing table is created by the loader rather than by a migration, so its DDL here is reconstructed from how every column is consumed and should be checked against `information_schema`; and `hoteles` has to be populated by hand, because `cantidad_hab` is the denominator of every occupancy figure and exists nowhere in the source system.

---

## Author

**Victor Sernaque** — Commercial Analyst at a hotel chain in Peru, focused on business analysis and systems redesign. Built and owns this warehouse end to end: dimensional modelling, ETL pipeline, and the reporting layer.

[LinkedIn](https://linkedin.com/in/victor-moises-sernaque-carrasco)

---

## License

MIT — free to reference for learning purposes.
