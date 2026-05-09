-- Idempotent. Unifies table collation, drops legacy phone_digits columns,
-- adds VARCHAR mirrors for numeric sequence_number, and creates filter indexes.

SET @s := IF((SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='bill')         <> 'utf8mb4_unicode_ci', 'ALTER TABLE `bill`         CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='client')       <> 'utf8mb4_unicode_ci', 'ALTER TABLE `client`       CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='supplier')     <> 'utf8mb4_unicode_ci', 'ALTER TABLE `supplier`     CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='purchase_bill')<> 'utf8mb4_unicode_ci', 'ALTER TABLE `purchase_bill`CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='product')      <> 'utf8mb4_unicode_ci', 'ALTER TABLE `product`      CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='user')         <> 'utf8mb4_unicode_ci', 'ALTER TABLE `user`         CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='cash_voucher') <> 'utf8mb4_unicode_ci', 'ALTER TABLE `cash_voucher` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := IF((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='bill'     AND column_name='user_phone_digits')>0, 'ALTER TABLE `bill` DROP COLUMN `user_phone_digits`',     'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='client'   AND column_name='phone_digits')>0,      'ALTER TABLE `client` DROP COLUMN `phone_digits`',          'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='supplier' AND column_name='phone_digits')>0,      'ALTER TABLE `supplier` DROP COLUMN `phone_digits`',        'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='branches' AND column_name='phone_digits')>0,      'ALTER TABLE `branches` DROP COLUMN `phone_digits`',        'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='user'     AND column_name='phone_digits')>0,      'ALTER TABLE `user` DROP COLUMN `phone_digits`',            'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := IF((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='bill'          AND column_name='sequence_number_str')=0,
            'ALTER TABLE `bill`          ADD COLUMN `sequence_number_str`          VARCHAR(32) GENERATED ALWAYS AS (CAST(`sequence_number`          AS CHAR)) VIRTUAL', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='purchase_bill' AND column_name='sequence_number_str')=0,
            'ALTER TABLE `purchase_bill` ADD COLUMN `sequence_number_str`          VARCHAR(32) GENERATED ALWAYS AS (CAST(`sequence_number`          AS CHAR)) VIRTUAL', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.columns WHERE table_schema=DATABASE() AND table_name='purchase_bill' AND column_name='supplier_sequence_number_str')=0,
            'ALTER TABLE `purchase_bill` ADD COLUMN `supplier_sequence_number_str` VARCHAR(64) GENERATED ALWAYS AS (CAST(`supplier_sequence_number` AS CHAR)) VIRTUAL', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;

SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='bill'          AND index_name='idx_bill_user_phone_number')=0,           'CREATE INDEX `idx_bill_user_phone_number` ON `bill` (`user_phone_number`)',                       'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='bill'          AND index_name='idx_bill_sequence_number')=0,             'CREATE INDEX `idx_bill_sequence_number` ON `bill` (`sequence_number`)',                           'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='client'        AND index_name='idx_client_phone')=0,                     'CREATE INDEX `idx_client_phone` ON `client` (`phone`)',                                           'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='client'        AND index_name='idx_client_vat_number')=0,                'CREATE INDEX `idx_client_vat_number` ON `client` (`vat_number`)',                                 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='client'        AND index_name='idx_client_commercial_registration')=0,   'CREATE INDEX `idx_client_commercial_registration` ON `client` (`commercial_registration`)',       'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='supplier'      AND index_name='idx_supplier_phone_number')=0,            'CREATE INDEX `idx_supplier_phone_number` ON `supplier` (`phone_number`(64))',                     'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='supplier'      AND index_name='idx_supplier_vat_number')=0,              'CREATE INDEX `idx_supplier_vat_number` ON `supplier` (`vat_number`(64))',                         'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='supplier'      AND index_name='idx_supplier_commercial_registration')=0, 'CREATE INDEX `idx_supplier_commercial_registration` ON `supplier` (`commercial_registration`)',   'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='purchase_bill' AND index_name='idx_pb_supplier_sequence_number')=0,      'CREATE INDEX `idx_pb_supplier_sequence_number` ON `purchase_bill` (`supplier_sequence_number`)', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='branches'      AND index_name='idx_branches_phone')=0,                   'CREATE INDEX `idx_branches_phone` ON `branches` (`phone`)',                                       'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='user'          AND index_name='idx_user_phone')=0,                       'CREATE INDEX `idx_user_phone` ON `user` (`phone`)',                                               'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='user'          AND index_name='idx_user_email')=0,                       'CREATE INDEX `idx_user_email` ON `user` (`email`(64))',                                           'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='cash_voucher'  AND index_name='idx_cash_voucher_voucher_number')=0,      'CREATE INDEX `idx_cash_voucher_voucher_number` ON `cash_voucher` (`voucher_number`)',             'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='articles'      AND index_name='idx_articles_articleNumber')=0,           'CREATE INDEX `idx_articles_articleNumber` ON `articles` (`articleNumber`(64))',                   'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='articleean'    AND index_name='idx_articleean_eancode_legacy')=0,        'CREATE INDEX `idx_articleean_eancode_legacy` ON `articleean` (`eancode`, `legacyArticleId`)',     'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='bill'          AND index_name='idx_bill_sequence_number_str')=0,         'CREATE INDEX `idx_bill_sequence_number_str` ON `bill` (`sequence_number_str`)',                   'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='purchase_bill' AND index_name='idx_pb_sequence_number_str')=0,           'CREATE INDEX `idx_pb_sequence_number_str` ON `purchase_bill` (`sequence_number_str`)',           'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
SET @s := IF((SELECT COUNT(*) FROM information_schema.statistics WHERE table_schema=DATABASE() AND table_name='purchase_bill' AND index_name='idx_pb_supplier_sequence_number_str')=0,  'CREATE INDEX `idx_pb_supplier_sequence_number_str` ON `purchase_bill` (`supplier_sequence_number_str`)', 'DO 0');
PREPARE st FROM @s; EXECUTE st; DEALLOCATE PREPARE st;
