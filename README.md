# Airflow Blob Storage Simulation Project

## Overview
Big Data simulation project using:
- EC2 (VM) + Docker + Apache Airflow
- S3 as Data Lake
- Athena for metadata and analytics

Generated on: 2026-02-18

## Architecture

Airflow DAG (daily):
1. Simulates transactional blob storage behavior
2. Generates CSV datasets (blob_inventory & events_daily)
3. Uploads to S3 (partitioned by dt)
4. Updates Athena metadata

## S3 Structure

s3://<bucket>/simulated-data/
  blob_inventory/dt=YYYY-MM-DD/
  events_daily/dt=YYYY-MM-DD/
  athena-results/

## Key Parameters

- λ = 1000 (normal daily transactions)
- k = 3 (incident amplification factor)
- p_incident = 0.05
- p_ok = 0.02
- p_fail = 0.10

## Datasets

blob_inventory → file-level metadata
events_daily → daily aggregated metrics

