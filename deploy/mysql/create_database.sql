-- One-time provisioning script — run once as root to create the app's
-- database and a dedicated, least-privilege user (never run the app as root).
--
--   "C:\Program Files\MySQL\MySQL Server 8.0\bin\mysql.exe" -u root -p < deploy\mysql\create_database.sql
--
-- Edit CHANGE_ME_STRONG_PASSWORD below before running, then put the same
-- password into your .env as DB_PASSWORD.

CREATE DATABASE IF NOT EXISTS mt5_signals
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

CREATE USER IF NOT EXISTS 'mt5_app'@'localhost'
    IDENTIFIED BY 'CHANGE_ME_STRONG_PASSWORD';

GRANT ALL PRIVILEGES ON mt5_signals.* TO 'mt5_app'@'localhost';

FLUSH PRIVILEGES;
