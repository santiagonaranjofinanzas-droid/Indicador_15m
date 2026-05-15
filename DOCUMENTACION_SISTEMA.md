# Documentación Técnica: Black Knight Trading System (Quantum V30.0)

## 1. Introducción
El Black Knight Trading System es un ecosistema de trading algorítmico de grado institucional que utiliza una arquitectura híbrida entre MQL5 (ejecución y manejo de órdenes) y Python (análisis estocástico y aprendizaje automático).

## 2. Arquitectura de Tres Capas (The Triple-Layer Defense)

### Capa 1: Alpha Generation (Mecánica Estocástica)
Esta capa identifica el régimen del mercado y la dirección probable del precio.
- **Hidden Markov Models (HMM):** Segmenta el mercado en regímenes de baja y alta volatilidad (Trending vs Mean Reverting).
- **GJR-GARCH (1,1):** Modela la asimetría de la volatilidad, permitiendo que el sistema se adapte a "shocks" de mercado y colas pesadas.
- **Adaptive Kalman Filter:** Filtra el ruido del precio en tiempo real para obtener una tendencia suavizada pero con latencia mínima.

### Capa 2: Microstructure & Risk Control (La Defensa)
Antes de ejecutar, el sistema evalúa la viabilidad de la operación basándose en la estructura del mercado.
- **Corwin-Schultz Spread Estimator:** Estima el spread real y la liquidez para evitar entradas en momentos de alto costo transaccional.
- **Fractional Kelly Criterion:** Calcula el tamaño óptimo de la posición basado en la ventaja estadística (edge), protegiendo el capital durante rachas de pérdidas.
- **Extreme Value Theory (EVT):** Utiliza la distribución de Pareto Generalizada para colocar Stop Losses dinámicos basados en la probabilidad de eventos de cola extrema.

### Capa 3: XGBoost Oracle (Meta-Labeling)
El componente final es un oráculo de Inteligencia Artificial.
- **Función:** Actúa como una compuerta binaria. Analiza las características de la señal generada por las Capas 1 y 2 (fuerza, probabilidad, salud del sistema, hora, día).
- **Meta-Labeling:** No predice la dirección, sino la *probabilidad de éxito* de la estrategia base. Si el oráculo predice una probabilidad inferior al umbral (ej. 50%), la señal es bloqueada, incluso si los indicadores técnicos dicen "comprar".

## 3. Gobernanza del Sistema (Health Monitoring)
El sistema genera un **Health Score** continuo. Si el mercado cambia drásticamente (Concept Drift) y las señales dejan de ser precisas, el Health Score baja y el sistema:
1. Reduce el tamaño de los lotes automáticamente.
2. Emite alertas de recalibración.
3. Se detiene si el Health Score cae por debajo del límite de seguridad.

## 4. Comunicación MQL5 <-> Python
La ejecución se realiza mediante sockets de baja latencia.
1. El EA en MT5 envía un JSON con los datos actuales al servidor Python.
2. El servidor Python procesa la señal a través de las capas matemáticas y el oráculo.
3. El servidor responde con un `CONFIDENCE_SCORE` y un multiplicador de riesgo.
4. El EA ejecuta la orden si el score es positivo.

---
*Documento generado para el despliegue institucional del Black Knight System.*
