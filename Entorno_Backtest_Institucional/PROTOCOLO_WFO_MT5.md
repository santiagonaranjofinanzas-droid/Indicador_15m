# Protocolo Institucional WFO - Arquitectura de 3 Particiones (Hold-Out Ciego)

Este protocolo define el rigor científico para validar el Black Knight System. Suprime el **Meta-Overfitting**, la Fuga de Microestructura (Latency Bias) y evalúa el Poder Estadístico de la muestra.

---

## FASE 1: Entrenamiento Base L1 (In-Sample EA) - Ventana $T_A$
Optimización de parámetros estocásticos (HMM, GARCH) buscando entropía poblacional.

1. **Objetivo de Optimización:** No busques el máximo Profit Factor. Busca el conjunto de parámetros que ofrezca **Alto Recall (Alta Frecuencia de Trades)**. XGBoost necesita varianza y falsos positivos para aprender a separar las clases.
2. **Deflated Sharpe Ratio (Heurística IS):** Dado que MT5 no exporta la varianza de todos los individuos evaluados por el Algoritmo Genético, asume un sesgo de pruebas múltiples severo. La estrategia base L1 debe lograr un *Sharpe Ratio* In-Sample inusualmente alto (Ej. $> 2.0$) para sobrevivir a la penalización teórica del DSR.

---

## FASE 2: Ingesta del Oráculo (In-Sample L3) - Ventana $T_B$
Se genera la telemetría OOS para L1 y se entrena el modelo de Machine Learning.

1. Ejecuta el EA en un *Single Test* sobre $T_B$ (FUTURO cronológico de $T_A$).
2. Renombra la salida a `Telemetry_TB.csv` y entrena a XGBoost usando `bt_model_freezer.py`.
3. Esto genera `meta_model_frozen.json` (Modelo $\Phi^*$). **El hiperplano queda congelado**. 

---

## FASE 3: La Prueba del Ácido (True Out-Of-Sample) - Ventana $T_C$
La validación final. La IA inferirá sobre la Ventana $T_C$, nunca vista por $T_A$ ni $T_B$.

1. **Latencia Inyectada (Anti-Lookahead Mecánico):** Configura el parámetro `InpNetworkLatencyMs = 65` en el EA. Esto obligará al Strategy Tester a deslizar el precio real imitando el lag TCP del servidor Python, revelando la rentabilidad real con *slippage* estocástico.
2. Ejecuta el EA conectado al socket de Python.
3. **Control MinTRL (Minimum Track Record Length):** 
   - Al finalizar, verifica el número de trades ($N$) ejecutados en $T_C$.
   - Si el XGBoost fue muy restrictivo y $N < 50$ (o por debajo de tu MinTRL calculado vía asimetría/curtosis), el *Sharpe Ratio* obtenido **carece de significancia estadística**. El sistema no se aprueba.
4. **Stress Test Distribucional:** Extrae los retornos de $T_C$ y aplica *Block Bootstrapping* en Python. Si el límite inferior de confianza (95%) del *Sharpe Bootstrappeado* es $< 0$, la estrategia falla.

**Regla Estricta:** Si $T_C$ falla por rentabilidad, baja significancia ($< MinTRL$) o riesgo de cola, **SE DESTRUYE EL PIPELINE**. Está terminantemente prohibido usar los resultados de $T_C$ para reajustar los parámetros en $T_A$.
