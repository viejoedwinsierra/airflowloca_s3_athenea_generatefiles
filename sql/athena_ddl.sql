CREATE DATABASE IF NOT EXISTS bigdata;

-- External table for blob_inventory
CREATE EXTERNAL TABLE IF NOT EXISTS bigdata.simulated_blob_inventory (...);

-- External table for events_daily
CREATE EXTERNAL TABLE IF NOT EXISTS bigdata.simulated_events_daily (...);

-- Repair partitions
MSCK REPAIR TABLE bigdata.simulated_blob_inventory;
MSCK REPAIR TABLE bigdata.simulated_events_daily;
