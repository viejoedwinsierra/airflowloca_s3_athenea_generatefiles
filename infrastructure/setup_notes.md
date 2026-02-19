# Infrastructure Notes

EC2:
- Ubuntu
- Docker + Airflow
- IAM Role: LabInstanceProfile

S3:
- Partitioned by dt

Athena:
- External tables
- MSCK REPAIR for partitions
