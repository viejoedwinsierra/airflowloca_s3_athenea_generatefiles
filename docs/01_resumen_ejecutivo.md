
# 📘 Proyecto: Implementación de Airflow Lite en AWS Academy

Fecha de generación: 2026-02-20 04:09:26

## 🎯 Objetivo del Proyecto

Implementar Apache Airflow en modo ligero (SequentialExecutor) dentro del entorno AWS Academy,
utilizando EC2 + Docker, optimizado para recursos limitados del sandbox académico.

## 🧠 Alcance

- Creación automatizada de infraestructura EC2
- Configuración de Docker
- Despliegue de Airflow Lite
- Validación operativa
- Diagnóstico de errores comunes

## 🏗 Arquitectura Implementada

EC2 (Amazon Linux)
└── Docker
    ├── PostgreSQL
    ├── Airflow Webserver
    └── Airflow Scheduler

Modo: SequentialExecutor
