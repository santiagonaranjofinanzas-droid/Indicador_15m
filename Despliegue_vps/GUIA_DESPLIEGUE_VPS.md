# 🏴 Black Knight Aut System — Guía de Despliegue en Producción
**Fecha:** 2026-05-14  
**Versión:** V30.0 + XGBoost L3 Meta-Model  
**Modelo ML:** Entrenado con 226,932 trades (Walk-Forward Purged K-Fold, AUC: 0.6624)

---

## 📋 Parámetros Optimizados (2025-05 → Presente)

| Parámetro | Valor | Descripción |
|-----------|-------|-------------|
| `InpMinStrength` | **0.30** | Fuerza mínima ML para entrada |
| `InpVolMultiplier` | **3.5** | Multiplicador de volatilidad para SL |
| `InpRewardRisk` | **3.0** | Ratio Riesgo/Beneficio (TP = SL × RR) |
| `InpNetworkLatencyMs` | **0** | Sin latencia artificial |
| `InpUsePartials` | **true** | Parciales dinámicos activos |
| `InpMagic` | **202505** | Magic Number (serie optimizada) |
| `InpUseXGBoostGate` | **true** | Filtro XGBoost activo |
| `InpXGMinProb` | **0.55** | Probabilidad mínima IA |

---

## 🚀 Paso a Paso: Despliegue Completo

### PASO 1: Preparar el Entorno Python

```powershell
# En el VPS o PC de producción:
cd C:\BlackKnight\Python          # (o tu directorio de despliegue)
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements.txt
```

### PASO 2: Verificar que el Modelo se Carga

```powershell
python -c "from ml_engine.xgboost_oracle import XGBoostOracle; o = XGBoostOracle(); print('OK' if o.model else 'FAIL')"
```

> Debe imprimir: `XGBoost model loaded...` y luego `OK`

### PASO 3: Levantar el Servidor Quant

```powershell
python quant_server.py
```

> Debes ver:
> ```
> +++ Black_Knight_Aut_System Quant Server (L3 Engine Phase 3 Risk Pipeline) started on 127.0.0.1:8888 +++
> +++ HTTP Server (Strategy Tester Fallback) started on 127.0.0.1:8889 +++
> ```

**⚠️ IMPORTANTE:** Esta ventana NO se puede cerrar mientras el sistema opera. En VPS, usa `nohup` (Linux) o Task Scheduler (Windows).

### PASO 4: Configurar MetaTrader 5

1. **Copiar archivos MQL5:**
   - `MQL5/Experts/Black_Knight_Aut_System_Master.mq5` → `%MT5_DIR%/MQL5/Experts/`
   - `MQL5/Indicators/Black_Knight_Aut_System_Engine.mq5` → `%MT5_DIR%/MQL5/Indicators/`
   - `MQL5/Include/Black_Knight_Aut_System_Core.mqh` → `%MT5_DIR%/MQL5/Include/`

2. **Compilar** ambos archivos (.mq5) desde MetaEditor (`Ctrl+F7`).

3. **Permisos de Red:**
   - `Herramientas > Opciones > Asesores Expertos`
   - ✅ Marcar "Permitir WebRequest para las siguientes URL"
   - Agregar: `http://127.0.0.1:8888`

### PASO 5: Cargar el EA en el Gráfico

1. Abre gráfico: **XAUUSD M15** (u otro activo optimizado)
2. Arrastra `Black_Knight_Aut_System_Master` al gráfico.
3. **Cargar Parámetros:** En la pestaña "Parámetros de entrada", haz clic en **"Cargar"** y selecciona:
   - `MQL5/Presets/Black_Knight_Optimized_2025.set`
4. Click **Aceptar**.
5. Verificar que el botón **"Algo Trading"** esté en VERDE.

### PASO 6: Cargar Telemetría Inicial (Opcional pero recomendado)

Para que el sistema tenga "memoria" histórica:
1. Copia `Data/Black_Knight_Telemetry.csv` desde tu PC.
2. Pégalo en el VPS en: `%MT5_DIR%/Terminal/Common/Files/`.

### PASO 7: Verificar Conexión

En la pestaña "Expertos" de MT5 debes ver:
```
XGBoost Oracle Connected Successfully.
[AUDIT] Scientific Audit CSV initialized.
Black_Knight_Aut_System Master EA V30.0 Initialized successfully.
```

---

## 📁 Estructura de Archivos

```
Despliegue_vps/
├── MQL5/
│   ├── Experts/
│   │   └── Black_Knight_Aut_System_Master.mq5  (EA principal)
│   ├── Indicators/
│   │   └── Black_Knight_Aut_System_Engine.mq5  (Motor HMM/GARCH)
│   └── Include/
│       └── Black_Knight_Aut_System_Core.mqh    (Librería compartida)
├── Python/
│   ├── quant_server.py                          (Servidor de inferencia)
│   ├── requirements.txt                         (Dependencias)
│   ├── core_math/                               (GARCH, Kalman, HMM)
│   ├── risk_evt/                                (Kelly, EVT, Corwin-Schultz)
│   └── ml_engine/
│       ├── xgboost_oracle.py                    (Motor de inferencia XGBoost)
│       ├── meta_model.json                      (Modelo entrenado)
│       ├── scaler.pkl                           (Escalador StandardScaler)
│       └── training_report.json                 (Reporte de entrenamiento)
├── GUIA_DESPLIEGUE_VPS.md                       (Este documento)
├── DOCUMENTACION_SISTEMA.md                     (Documentación técnica)
└── CERTIFICADO_CALIDAD_ML.md                    (Validación del modelo)
```

---

## 🔧 Mantenimiento

### Re-entrenamiento del Modelo
Ejecutar periódicamente (cada 1-2 meses) con datos frescos:
```powershell
python ml_engine/retrain_production.py
```
Luego reiniciar `quant_server.py` para cargar el nuevo modelo.

### Monitoreo
- **Logs Python:** Consola del servidor muestra cada evaluación
- **Audit CSV:** `Common/Files/XGBoost_Scientific_Audit.csv` registra cada decisión
- **Telemetría:** `Common/Files/Black_Knight_Telemetry.csv` almacena features para re-entrenamiento futuro

### Troubleshooting
| Problema | Solución |
|----------|----------|
| EA no conecta al servidor | Verificar que `quant_server.py` está corriendo y el firewall permite `127.0.0.1:8888` |
| `XGBoost Oracle: OFFLINE` | Reiniciar `quant_server.py`, verificar que el puerto 8888 está libre |
| Win Rate bajo | Subir `InpXGMinProb` a 0.60-0.65 (menos trades, más selectivos) |
| Muchos trades bloqueados | Bajar `InpXGMinProb` a 0.50 (más trades, menos selectivos) |

---

## 📊 Métricas de Validación del Modelo Actual

| Métrica | Valor |
|---------|-------|
| Dataset | 226,932 trades |
| OOS AUC | 0.6624 |
| OOS Brier | 0.2111 |
| Win Rate @ 0.55 | **89.73%** |
| Profit Factor @ 0.55 (R=1.5) | **13.11** |
| K-Folds | 5 (Walk-Forward Purged, gap=500) |
