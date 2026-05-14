# Integracion y Reentrenamiento Institucional (Black_Knight_Aut_System MT5)

## 1) Integracion de modelos (flujo productivo)

### 1.1 Flujo de decision en tiempo real
1. `Black_Knight_Aut_System_Engine.mq5` calcula features y estado de mercado.
2. El indicador publica buffers institucionales:
   - Regime: `18`
   - Strength: `17`
   - HMM prob: `15`
   - SigProy (vol proyectada): `32`
   - Health: `38`
   - ValScore: `40`
3. `Black_Knight_Aut_System_Master.mq5` consume esos buffers para decidir entrada/salida.
4. La ejecucion usa exclusivamente barra cerrada (`shift=1`) para evitar look-ahead operativo.

### 1.2 Contrato indicador -> EA
- El contrato de buffers debe ser estable en versionado.
- Si cambias un indice de buffer en el indicador, debes actualizar el EA en la misma release.
- Toda release debe mantener compatibilidad con los presets de paper trading.

### 1.3 Gate de produccion
- El EA solo puede abrir posicion si:
  - `state > 0` (no DEFENSIVE)
  - `health >= hard stop`
  - `regime != 0`
  - `strength >= min strength`
  - Meta-execution score supera umbral por estado

## 2) Reentrenamiento / recalibracion (sin leakage)

### 2.1 Dataset y particionado
1. Exportar OHLCV + spread + costos reales por simbolo y timeframe.
2. Particionar con walk-forward purgado (sin solape informativo entre train y test).
3. Mantener OOS estricto en evaluacion de senal:
   - Prediccion en `t-1`
   - Resultado observado en `t`

### 2.2 Parametros que se recalibran
- Volatilidad:
  - `InpGarchAlpha`, `InpGarchGamma`, `InpGarchBeta`
- Regimen:
  - `ExtHMMNu` y anclas de transicion
- Jump process:
  - `ExtJumpLambda`, `ExtJumpMu`
- Umbrales de ejecucion/riesgo:
  - `InpMinStrength`, `InpRiskPercent`, `InpVolMultiplier`, `InpExecMinHealthy`, `InpExecMinWarning`

Nota: en `Black_Knight_Aut_System_Engine.mq5` ya hay controles anti-overfit para recalibracion online:
- Shrinkage a prior (`InpNuPriorWeight`, `InpLambdaPriorWeight`)
- Max step por update (`InpNuMaxStep`, `InpLambdaMaxStep`)
- Suavizado (`InpNuEmaAlpha`, `InpLambdaEmaAlpha`, `InpValEmaAlpha`)

### 2.3 Criterios de aceptacion de nuevo modelo
Promocionar una nueva configuracion solo si cumple en OOS:
- Mejor Sharpe neto ajustado por costos
- Menor max drawdown o igual con mayor retorno
- Estabilidad de Health y ValScore (sin degradacion estructural)
- Robustez en subperiodos y distintos regimenes de volatilidad

### 2.4 Ciclo operativo recomendado
- Semanal: recalibracion ligera y validacion OOS incremental.
- Mensual: recalibracion completa con ventana extendida y stress tests.
- Trimestral: revision estructural de arquitectura y limites de riesgo.

## 3) Despliegue seguro
1. Entrenar/recalibrar en entorno offline.
2. Congelar parametros de release.
3. Validar en paper trading con los presets institucionales.
4. Pasar a produccion con rollout gradual (capital fraccionado).
5. Activar rollback automatico ante breach de drawdown o degradacion persistente de ValScore.

## 4) Checklist de no-regresion
- [ ] Sin look-ahead en decision del EA (shift=1)
- [ ] Sin leakage en score de validacion (t-1 -> t)
- [ ] Ventanas rolling estables por indice absoluto, no por `start`
- [ ] Recalibracion con shrinkage + max-step
- [ ] Validacion de compilacion sin errores
- [ ] Registro de cambios y versionado de parametros
