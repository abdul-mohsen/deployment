-- ============================================================================
-- 0003_keyset_indexes.sql
-- Composite indexes that support keyset pagination on the list endpoints.
--
-- Why these specific indexes:
--   The seek predicate is `WHERE (sort_value, id) < (?, ?)
--                          ORDER BY sort_value DESC, id DESC LIMIT N+1`.
--   For that to run as a single index range scan (no filesort, no temp
--   table) we need an index whose leading columns match the ORDER BY.
--   InnoDB silently appends the PK to every secondary index, so a key
--   on `(effective_date)` already sorts ties by `id` for free — but
--   declaring `(effective_date DESC, id DESC)` explicitly lets the
--   optimizer use the index in the natural scan direction, avoiding a
--   backward range scan that some older 8.0 minor versions still cost
--   higher than a filesort. (MySQL 8.0+ supports descending indexes;
--   we already pin to 8.0 in compose.)
--
-- The previously-shipped `(merchant_id, effective_date)` keys are kept
-- — they are still useful for any per-creator queries (dashboards,
-- audit). They do NOT serve the new list seek because `merchant_id`
-- (which actually stores the creator user id, not a tenant id) is not
-- in the WHERE clause of the new list queries.
--
-- Idempotent: `CREATE INDEX IF NOT EXISTS` (MySQL 8.0.29+) makes each
-- statement a no-op on a second run, so we no longer need the
-- per-index information_schema gate that 0002 used.
-- ============================================================================

CREATE INDEX IF NOT EXISTS `idx_bill_keyset`
    ON `bill` (`effective_date` DESC, `id` DESC);

CREATE INDEX IF NOT EXISTS `idx_pb_keyset`
    ON `purchase_bill` (`effective_date` DESC, `id` DESC);

CREATE INDEX IF NOT EXISTS `idx_cv_keyset`
    ON `cash_voucher` (`effective_date` DESC, `id` DESC);

-- Sorted by created_at DESC for the list page. Same DESC-DESC composite
-- so the seek is one index range read.
CREATE INDEX IF NOT EXISTS `idx_orders_keyset`
    ON `orders` (`created_at` DESC, `id` DESC);

-- Sorted by updated_at DESC, id DESC (matches existing GetClients ORDER BY
-- and surfaces recently-touched clients first, the existing UX contract).
CREATE INDEX IF NOT EXISTS `idx_client_keyset`
    ON `client` (`is_deleted`, `updated_at` DESC, `id` DESC);

-- supplier, product, branch, stores list pages all sort by `id DESC` only.
-- The InnoDB primary key already serves that scan order natively — no
-- additional index needed for the seek itself. The existing per-tenant
-- filter indexes (idx_supplier_company_active, idx_product_store_active_qty)
-- still match their respective handler filters.
