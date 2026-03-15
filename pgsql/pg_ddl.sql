CREATE USER root WITH PASSWORD 'admin1';

CREATE DATABASE fraud;

GRANT ALL PRIVILEGES ON DATABASE fraud TO root;

\c fraud;

CREATE TABLE alerts (alertId VARCHAR(255), card_hash VARCHAR(255), country VARCHAR(255), transaction_id VARCHAR(255), rule VARCHAR(255), score FLOAT, details VARCHAR(255), alert_time TIMESTAMP, processing_lag INT, PRIMARY KEY(alertId));

ALTER TABLE alerts OWNER TO root;
