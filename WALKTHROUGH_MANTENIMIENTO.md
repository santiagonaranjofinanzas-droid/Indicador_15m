# 🏴 Hoja de Ruta: Black Knight Aut System — Operación Institucional

Este documento describe el proceso completo para levantar, operar y mantener el sistema en producción.

---

## 📂 Arquitectura de Archivos

### Archivos del Proyecto (Tu Carpeta de Trabajo)
```
C:\Users\NuevoAdmin\Desktop\15m - HMM\
├── Black_Knight_Aut_System_MT5\          ← Código fuente MQL5
│   ├── Black_Knight_Aut_System_Master.mq5   (Expert Advisor)
│   ├── Black_Knight_Aut_System_Engine.mq5   (Indicador Base)
│   └── Black_Knight_Aut_System_Core.mqh     (Librería Matemática)
│
└── Entorno_institucional\Python\          ← Oráculo IA
    ├── quant_server.py                      (Servidor TCP en vivo)
    ├── ml_engine\
    │   ├── train_meta_model.py              (Entrenador XGBoost)
    │   ├── meta_model.json                  (Cerebro entrenado)
    │   └── scaler.pkl                       (Normalizador de datos)
    └── logs\
        └── Black_Knight_Telemetry.csv       (Datos de entrenamiento)
```

### Carpeta de MetaTrader 5 (Tu Terminal Activo)
```
C:\Users\NuevoAdmin\AppData\Roaming\MetaQuotes\Terminal\
  6FBEE76C719DC78AB2AE839B5A0C7442\MQL5\
    ├── Experts\
    │   └── Black_Knight_Aut_System_Master.mq5  ← COMPILAR AQUÍ (F7)
    ├── Indicators\
    │   └── Black_Knight_Aut_System_Engine.mq5
    └── Include\
        ├── Black_Knight_Aut_System_Core.mqh
        └── Trade\   ← Librería Estándar de MT5
```

### Telemetría (Datos que genera el EA)
```
C:\Users\NuevoAdmin\AppData\Roaming\MetaQuotes\Terminal\Common\Files\
  └── Black_Knight_Telemetry.csv   ← El EA escribe aquí automáticamente
```

---

## 🔧 Tabla de Movimiento de Archivos

| Archivo | Origen | Destino en MT5 |
| :--- | :--- | :--- |
| `Black_Knight_Aut_System_Master.mq5` | `...\Black_Knight_Aut_System_MT5\` | `...\6FBEE76...\MQL5\Experts\` |
| `Black_Knight_Aut_System_Engine.mq5` | `...\Black_Knight_Aut_System_MT5\` | `...\6FBEE76...\MQL5\Indicators\` |
| `Black_Knight_Aut_System_Core.mqh` | `...\Black_Knight_Aut_System_MT5\` | `...\6FBEE76...\MQL5\Include\` |
| `Black_Knight_Telemetry.csv` | `...\Terminal\Common\Files\` | `...\Python\logs\` |

> **REGLA:** Cada vez que modifiques un archivo .mq5, debes: (1) copiarlo a la carpeta de MT5 y (2) pulsar F7 en MetaEditor para recompilar.

---

## 🚀 FLUJO DE LANZAMIENTO AL 100%

### PASO 1: Verificar que Python esté listo
```powershell
cd "C:\Users\NuevoAdmin\Desktop\15m - HMM\Entorno_institucional\Python"
pip install xgboost scikit-learn pandas joblib
```

### PASO 2: Levantar el Servidor de IA (Oráculo XGBoost)
```powershell
cd "C:\Users\NuevoAdmin\Desktop\15m - HMM\Entorno_institucional\Python"
python quant_server.py
```
**✅ Verificación:** Debes ver `XGBoost Meta-Model loaded and server listening on port 8888`

> ⚠️ **IMPORTANTE:** Este script debe quedar corriendo en segundo plano mientras el bot opera. Si cierras la terminal, el XGBoost se desconecta.

### PASO 3: Abrir MetaTrader 5
1. Abre tu MetaTrader 5 (el de la cuenta Axi-US50-Demo o tu cuenta real).
2. Asegúrate de que el botón **"Algo Trading"** en la barra superior esté en **VERDE**.

### PASO 4: Cargar el EA en un Gráfico
1. Abre un gráfico de **XAUUSD** en temporalidad **M15**.
2. En el panel "Navegador" (lado izquierdo), busca `Expert Advisors > Black_Knight_Aut_System_Master`.
3. Arrastra el EA al gráfico.
4. En la ventana de parámetros:
   - Pestaña **"Común":** Marca "Permitir Algo Trading" y "Permitir importar DLL".
   - Pestaña **"Parámetros de Entrada":**
     - `Activar filtro XGBoost` = `true` (solo si el servidor Python está corriendo)
     - `Magic Number` = `30001`
     - Los demás parámetros déjalos en los valores optimizados (ver sección de optimización).
5. Haz clic en **OK**.

### PASO 5: Verificar Conexión
En la pestaña **"Expertos"** (parte inferior de MT5), deberías ver:
```
Black_Knight_Aut_System Master EA V30.0 Initialized successfully.
XGBoost Oracle Connected Successfully.
```

**🎉 El sistema está 100% operativo.**

---

## 📅 CICLO DE MANTENIMIENTO (Semanal o Mensual)

### Fase 1: Optimización de Parámetros (Cada Domingo)

**Objetivo:** Encontrar los mejores valores de SL, sensibilidad y R:R para el mercado actual.

1. **Abrir el Probador de Estrategias:** `Ctrl + R` o menú `Ver > Probador de Estrategias`.
2. **Configurar:**
   - **Expert:** `Black_Knight_Aut_System_Master`
   - **Symbol:** `XAUUSD.pro`
   - **Temporalidad:** `M15`
   - **Date:** Últimos **3 a 6 meses** (NO "Entire history")
   - **Modelling:** `1 minute OHLC` (rápido y confiable para M15)
   - **Optimization:** `Fast genetic based algorithm` + `Sharpe Ratio max`
3. **Variables a optimizar** (marcar la casilla ☑):
   - `Multiplicador de Volatilidad para SL`: Start=1.5, Stop=4.0, Step=0.25
   - `Min ML Strength for Entry`: Start=0.25, Stop=0.55, Step=0.05
   - `Ratio Riesgo/Beneficio`: Start=1.5, Stop=3.5, Step=0.25
   - `Risk per Trade (%)`: Start=0.5, Stop=2.0, Step=0.25
4. **Ejecutar:** Clic en "Start" y esperar (5-30 min con la versión optimizada).
5. **Extraer Resultados:**
   - Ve a la pestaña **"Optimization Results"**.
   - Ordena por **Sharpe Ratio** (clic en la columna).
   - Haz **clic derecho** en la mejor fila → **"Set input parameters"**.
   - Opcionalmente: **"Save..."** para guardar como archivo `.set`.

### Fase 2: Re-entrenamiento de la IA (Cada 1-2 Semanas)

**Objetivo:** Enseñar al XGBoost cuáles son las condiciones ganadoras actuales.

1. **Localizar la Telemetría:**
   - En MT5: `Archivo > Abrir Carpeta de Datos`.
   - Sube un nivel (carpeta `Terminal`).
   - Entra en `Common > Files`.
   - Busca `Black_Knight_Telemetry.csv`.

2. **Mover el archivo:**
   ```powershell
   Copy-Item "C:\Users\NuevoAdmin\AppData\Roaming\MetaQuotes\Terminal\Common\Files\Black_Knight_Telemetry.csv" "C:\Users\NuevoAdmin\Desktop\15m - HMM\Entorno_institucional\Python\logs\" -Force
   ```

3. **Entrenar el modelo:**
   ```powershell
   cd "C:\Users\NuevoAdmin\Desktop\15m - HMM\Entorno_institucional\Python"
   python ml_engine/train_meta_model.py
   ```
   **✅ Verificación:** Debes ver `Training Complete. ROC-AUC: X.XXXX` y que se creó `meta_model.json`.

4. **Reiniciar el servidor:**
   - Cierra la terminal donde corre `quant_server.py` (Ctrl+C).
   - Vuelve a ejecutar: `python quant_server.py`.
   - Ahora el servidor carga el modelo actualizado.

> **NOTA:** Necesitas al menos **50 trades** en el CSV para que el entrenamiento sea válido. Si tienes menos, deja el EA corriendo con `Activar filtro XGBoost = false` hasta acumular suficientes datos.

---

## 🧠 EXPLICACIÓN PROFUNDA: EL XGBOOST

### ¿Qué es?
XGBoost (eXtreme Gradient Boosting) es un algoritmo de Machine Learning que construye cientos de "árboles de decisión" que aprenden de los errores de los anteriores. Es el algoritmo más usado en competiciones de Kaggle y en fondos cuantitativos.

### ¿Cómo funciona en nuestro sistema?

**Arquitectura de 2 Capas (Meta-Labeling de Marcos López de Prado):**

```
┌────────────────────────┐
│     CAPA 1 (MQL5)      │  ← Motor Estadístico
│  Filtro de Kalman      │     Predice DIRECCIÓN
│  HMM + GJR-GARCH       │     (Comprar o Vender)
│  Validación Cruzada    │
└──────────┬─────────────┘
           │ Señal: "COMPRA con strength=0.72"
           ▼
┌────────────────────────┐
│    CAPA 2 (Python)     │  ← Oráculo Inteligente
│    XGBoost Classifier  │     Predice PROBABILIDAD DE ÉXITO
│    10 Features          │     (¿Debería hacer caso a la Capa 1?)
└──────────┬─────────────┘
           │ Respuesta: "78% de probabilidad de ganar"
           ▼
┌────────────────────────┐
│    DECISIÓN FINAL      │
│  Si prob >= 55% → ABRIR│
│  Si prob < 55%  → SKIP │
└────────────────────────┘
```

### ¿Qué features (datos) analiza el XGBoost?

| # | Feature | Qué mide |
|---|---------|----------|
| 1 | `strength` | Fuerza de la señal del motor estadístico |
| 2 | `prob` | Probabilidad del régimen HMM |
| 3 | `sig_proj` | Volatilidad proyectada (GJR-GARCH) |
| 4 | `health` | Salud del sistema (consistencia interna) |
| 5 | `valscore` | Score de validación cruzada |
| 6 | `spread_ratio` | Spread actual vs. Stop Loss esperado |
| 7 | `hour_sin` | Hora del día (componente seno) |
| 8 | `hour_cos` | Hora del día (componente coseno) |
| 9 | `day_sin` | Día de la semana (componente seno) |
| 10 | `day_cos` | Día de la semana (componente coseno) |

### ¿Por qué usar seno/coseno para hora y día?
Porque las 23:00 y las 00:00 son "cercanas" en el tiempo, pero si usamos números lineales (23 vs 0), el modelo las vería como lejanas. La codificación cíclica (seno/coseno) resuelve esto matemáticamente.

### Flujo de Comunicación en Tiempo Real
1. El EA detecta una señal de compra/venta.
2. Empaqueta los 10 features en un JSON y lo envía por TCP al puerto 8888.
3. El servidor Python normaliza los datos con el `scaler.pkl`.
4. El XGBoost genera una probabilidad (0.0 a 1.0).
5. El servidor devuelve `{"xg_confidence": 0.78}` al EA.
6. El EA decide: si >= 0.55 → ejecuta. Si < 0.55 → cancela.

**Todo esto ocurre en milisegundos.**

---

## ⚡ OPTIMIZACIONES DE RENDIMIENTO (Backtesting)

El EA incluye optimizaciones automáticas para el Probador de Estrategias:

1. **Dashboard desactivado:** En backtest, no se dibujan los 9 objetos gráficos (ahorra miles de operaciones de render).
2. **Socket TCP deshabilitado:** No intenta conectar al servidor Python durante backtest (evita timeouts).
3. **Ticks intermedios ignorados:** Si no hay posición abierta y no es una barra nueva, el EA sale inmediatamente (reduce >90% de procesamiento inútil).
4. **Telemetría solo en barras nuevas:** No escanea el historial de deals en cada tick.

**Resultado:** La optimización genética que antes tomaba +1 hora ahora debería completarse en **5-30 minutos**.

### Configuración Recomendada para Optimización Rápida
- **Date:** Últimos 3-6 meses (NO "Entire history")
- **Modelling:** `1 minute OHLC` (no "Every tick based on real ticks")
- **Optimization:** `Fast genetic based algorithm`
- **Criterion:** `Sharpe Ratio max`

---

## 🔑 ARCHIVOS PYTHON: ¿CUÁL EJECUTAR Y CUÁNDO?

| Archivo | Comando | Cuándo |
| :--- | :--- | :--- |
| `quant_server.py` | `python quant_server.py` | **Siempre** que el bot esté operando en vivo |
| `train_meta_model.py` | `python ml_engine/train_meta_model.py` | Cada 1-2 semanas para re-entrenar |

---

## ❓ TROUBLESHOOTING

| Problema | Solución |
| :--- | :--- |
| EA no compila (errores de include) | Verifica que compilas desde la carpeta de MT5, no desde el Desktop |
| "Could not connect to XGBoost Server" | Asegúrate de que `quant_server.py` esté corriendo |
| Optimización muy lenta | Usa "1 minute OHLC" y reduce el rango de fechas a 3-6 meses |
| "Insufficient data for training" | Necesitas al menos 50 trades en el CSV. Deja correr el bot más tiempo |
| EA no abre trades | Revisa que `Algo Trading` esté verde y que `health > InpHealthHardStop` |
