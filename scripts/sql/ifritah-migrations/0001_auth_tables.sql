-- Migration 0001_auth_tables.sql
--
-- Adds the auth-flow tables that PR #8 (role-based access) introduced:
--
--   * password_reset_tokens — backs ForgotPassword / ResetPassword.
--   * sessions             — invalidated on password reset (force re-login).
--
-- The refresh_token table already exists in pkg/db/schema/schema.sql and is
-- not touched here.
--
-- Apply with your usual MySQL client, e.g.:
--   mysql -h <host> -u <user> -p <db> < pkg/db/migrations/0001_auth_tables.sql
--
-- This file is also read by sqlc (see sqlc.yaml `schema:` list) so that
-- generated code in pkg/db/gen/ knows about these tables. Do not put
-- destructive DROPs here for tables that already exist in production —
-- if you need a follow-up change, write a new 0002_*.sql migration.

CREATE TABLE IF NOT EXISTS `password_reset_tokens` (
  `id` int NOT NULL AUTO_INCREMENT,
  `user_id` int NOT NULL,
  `token` varchar(64) NOT NULL,
  `expires_at` datetime NOT NULL,
  `used_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_prt_token` (`token`),
  KEY `idx_prt_user` (`user_id`),
  KEY `idx_prt_expires` (`expires_at`),
  CONSTRAINT `fk_prt_user` FOREIGN KEY (`user_id`) REFERENCES `user` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS `sessions` (
  `id` char(36) NOT NULL DEFAULT (uuid()),
  `user_id` int NOT NULL,
  `created_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `expires_at` datetime DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_sess_user` (`user_id`),
  CONSTRAINT `fk_sess_user` FOREIGN KEY (`user_id`) REFERENCES `user` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
