-- ============================================================================
-- 0002_performance_indexes.sql
-- Performance indexes for hot query paths.
-- Idempotent: each ADD INDEX is gated against information_schema, so running
-- the file again is a no-op. Pure SQL — no DELIMITER directive — so sqlc can
-- parse this file alongside the rest of pkg/db/migrations/.
-- ============================================================================

-- Pattern repeated per index:
--   SET @s := IF(<index already exists>, 'SELECT 1', '<the ALTER>');
--   PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ---- P1: must add now ------------------------------------------------------

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='user' AND index_name='uq_user_username'),
  'SELECT 1',
  'ALTER TABLE `user` ADD UNIQUE KEY `uq_user_username` (`username`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='refresh_token' AND index_name='uq_rt_token_hash'),
  'SELECT 1',
  'ALTER TABLE `refresh_token` ADD UNIQUE KEY `uq_rt_token_hash` (`token_hash`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='bill' AND index_name='idx_bill_merchant_state_date'),
  'SELECT 1',
  'ALTER TABLE `bill` ADD INDEX `idx_bill_merchant_state_date` (`merchant_id`, `state`, `effective_date`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='bill' AND index_name='idx_bill_client_date'),
  'SELECT 1',
  'ALTER TABLE `bill` ADD INDEX `idx_bill_client_date` (`client_id`, `effective_date`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='purchase_bill' AND index_name='idx_pb_supplier_date'),
  'SELECT 1',
  'ALTER TABLE `purchase_bill` ADD INDEX `idx_pb_supplier_date` (`supplier_id`, `effective_date`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='purchase_bill_product' AND index_name='idx_pbprod_bill'),
  'SELECT 1',
  'ALTER TABLE `purchase_bill_product` ADD INDEX `idx_pbprod_bill` (`bill_id`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='product' AND index_name='idx_product_store_active_qty'),
  'SELECT 1',
  'ALTER TABLE `product` ADD INDEX `idx_product_store_active_qty` (`store_id`, `is_deleted`, `quantity`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='supplier' AND index_name='idx_supplier_company_active'),
  'SELECT 1',
  'ALTER TABLE `supplier` ADD INDEX `idx_supplier_company_active` (`company_id`, `is_deleted`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='client' AND index_name='idx_client_active_name'),
  'SELECT 1',
  'ALTER TABLE `client` ADD INDEX `idx_client_active_name` (`is_deleted`, `name`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='cash_voucher' AND index_name='idx_cv_merchant_date_state'),
  'SELECT 1',
  'ALTER TABLE `cash_voucher` ADD INDEX `idx_cv_merchant_date_state` (`merchant_id`, `effective_date`, `state`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='orders' AND index_name='idx_orders_store_status'),
  'SELECT 1',
  'ALTER TABLE `orders` ADD INDEX `idx_orders_store_status` (`store_id`, `status`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

-- ---- P2: should add --------------------------------------------------------

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='bill_payment' AND index_name='idx_billpay_recorded_by'),
  'SELECT 1',
  'ALTER TABLE `bill_payment` ADD INDEX `idx_billpay_recorded_by` (`recorded_by`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='purchase_bill_payment' AND index_name='idx_pbpay_recorded_by'),
  'SELECT 1',
  'ALTER TABLE `purchase_bill_payment` ADD INDEX `idx_pbpay_recorded_by` (`recorded_by`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;

SET @s := IF(EXISTS(SELECT 1 FROM information_schema.statistics
  WHERE table_schema=DATABASE() AND table_name='uploaded_files' AND index_name='idx_uploaded_by_date'),
  'SELECT 1',
  'ALTER TABLE `uploaded_files` ADD INDEX `idx_uploaded_by_date` (`uploaded_by`, `created_at`)');
PREPARE stmt FROM @s; EXECUTE stmt; DEALLOCATE PREPARE stmt;
