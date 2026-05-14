# 🌌 Guía del Entorno Black_Knight_Aut_System Quantum V30.0

Este documento detalla la arquitectura y el propósito de cada componente en este ecosistema de trading algorítmico institucional basado en **HMM (Hidden Markov Models)** y **GJR-GARCH**.

---

## 📂 Estructura del Proyecto

### 1. 📂 `Black_Knight_Aut_System_MT5/` (El Frente de Batalla)
Esta es la carpeta principal que contiene el código ejecutable para MetaTrader 5. Es el componente que interactúa directamente con el mercado.
*   **`Black_Knight_Aut_System_Master.mq5`**: El **Agente Maestro**. Es el EA (Expert Advisor) institucional. Gestiona la ejecución, el riesgo dinámico (Risk Throttle) y la telemetría de operaciones.
*   **`Black_Knight_Aut_System_Engine.mq5`**: El **Motor de Señales y Regímenes**. Es un indicador ultra-complejo que implementa el filtro de Hamilton para HMM, la volatilidad GJR-GARCH y filtros de Kalman para detectar el régimen de mercado.
*   **`Black_Knight_Aut_System_Core.mqh`**: La librería de funciones núcleo (Kernel) que comparten el Master y el Signal para asegurar coherencia matemática.

### 2. 📂 `Entorno_institucional/` (La Sala de Máquinas)
Aquí reside la inteligencia pesada y las herramientas de soporte que no pueden ejecutarse eficientemente dentro de MT5.

#### 🐍 `Python/`
El cerebro matemático del sistema. Se encarga de los cálculos que requieren bibliotecas científicas avanzadas.
*   **`quant_server.py`**: El servidor puente. Permite que MetaTrader 5 se comunique con los scripts de Python para obtener parámetros recalibrados o análisis de riesgo en tiempo real.
*   **`core_math/`**: Contiene las implementaciones de modelos como el `heuristic_jump_hmm.py`, que detecta cambios bruscos en el régimen de mercado.
*   **`risk_evt/`**: Especializado en **EVT (Extreme Value Theory)**. Analiza los "eventos de cola" (cisnes negros) para ajustar el riesgo antes de que ocurra una catástrofe.
*   **`validation/`**: Scripts para **Walk-Forward Analysis**. Valida que el modelo siga siendo efectivo a medida que el mercado evoluciona.

#### 📊 `MQL5/`
*   **`Black_Knight_Aut_System_OMS.mq5`**: (Order Management System) Un sistema de gestión de órdenes especializado para entornos institucionales que requieren un control más granular que el EA estándar.

### 3. 📂 `validation/` (El Archivo de Resultados)
Carpeta de salida para todos los procesos de auditoría y validación del sistema.
*   **`oos_best_params.json`**: Almacena los mejores parámetros encontrados durante las pruebas Out-Of-Sample (fuera de muestra).
*   **`oos_institutional_report.json`**: Reporte detallado del rendimiento esperado y métricas de riesgo del alpha bajo condiciones reales.

---

## 🛠️ Flujo de Trabajo Típico

1.  **Recalibración**: Los scripts en `Entorno_institucional/Python/validation` analizan datos históricos para encontrar los parámetros óptimos de HMM.
2.  **Despliegue**: Se activa el `quant_server.py` para servir de puente.
3.  **Ejecución**: Se carga el `Black_Knight_Aut_System_Engine` y el `Black_Knight_Aut_System_Master` en MT5.
4.  **Monitoreo**: El sistema de salud en el `Black_Knight_Aut_System_Master` ajusta el riesgo basándose en la telemetría y el análisis de riesgo de cola proveniente del servidor Python.

---
> [!IMPORTANT]
> **No modificar los archivos en `core_math` o `risk_evt`** sin realizar un backtest walk-forward completo, ya que cualquier cambio en la lógica matemática puede desincronizar la comunicación con los componentes de MT5.
