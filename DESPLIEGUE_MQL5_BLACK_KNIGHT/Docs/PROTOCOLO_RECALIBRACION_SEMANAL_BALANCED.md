# Protocolo Semanal de Recalibracion - Perfil Balanced

Date: 2026-04-12
Scope: Black_Knight_Aut_System MT5 (Signal + Master) with Fase 1-4 controls.
Profile: Balanced only.

## 1. Objetivo y Principios

Objetivo: mantener estabilidad del edge con cambios pequenos, trazables y reversibles, evitando sobreajuste.

Principios institucionales:
1. Stability over reactivity.
2. One-change-set per week.
3. Parameter drift must be bounded.
4. Every recalibration must be reproducible and auditable.

## 2. Cadencia Semanal (Horario Operativo)

1. Viernes post-cierre: congelar datos de la semana y generar reporte.
2. Sabado: ejecutar validaciones y propuesta de nuevos parametros.
3. Domingo: comite de aprobacion (Go / No-Go).
4. Lunes pre-apertura: aplicar cambios aprobados y activar monitoreo reforzado.

## 3. Data Freeze y Ventanas de Evaluacion

1. Training window rolling: ultimas 12 semanas.
2. Validation window (recent OOS): ultimas 4 semanas.
3. Stress window: ultimos 5 dias para microestructura y ejecucion.
4. Data freeze inmutable: no se reescriben datos historicos una vez cerrada la semana.

## 4. Gate de Recalibracion (Cuándo se permite recalibrar)

Se recalibra solo si al menos una condicion se cumple:
1. ValScore semanal promedio cae por debajo de 0.62.
2. Health score semanal promedio cae por debajo de 0.60.
3. Execution score promedio cae por debajo de 0.58.
4. Drawdown semanal excede 1.15x el presupuesto interno.

Si ninguna condicion se cumple: mantener parametros (no-touch week).

## 5. Limites de Cambio (Change Control Boundaries)

### 5.1 EA - Black_Knight_Aut_System_Master.mq5 (Balanced)

Base Balanced:
1. InpRiskPercent=0.60
2. InpExecMinHealthy=0.60
3. InpExecMinWarning=0.74
4. InpExecSpreadPenalty=0.35
5. InpTelemetryEmaAlpha=0.20
6. InpHealthHardStop=0.35
7. InpHealthWarn=0.62

Limites maximos por semana:
1. InpRiskPercent: +/-0.10
2. InpExecMinHealthy: +/-0.04
3. InpExecMinWarning: +/-0.04
4. InpExecSpreadPenalty: +/-0.05
5. InpTelemetryEmaAlpha: +/-0.05
6. InpHealthHardStop: +/-0.03
7. InpHealthWarn: +/-0.03

### 5.2 Indicador - Black_Knight_Aut_System_Engine.mq5 (Balanced)

Base Balanced:
1. InpThresh=0.66
2. InpRecalibWindow=500
3. InpJumpSigmaK=3.00
4. InpNuEmaAlpha=0.20
5. InpLambdaEmaAlpha=0.20
6. InpThreshAdaptK=0.12
7. InpStrengthAdaptK=0.18
8. InpValidationWindow=300
9. InpValHealthy=0.70
10. InpValWarning=0.50

Limites maximos por semana:
1. InpThresh: +/-0.03
2. InpRecalibWindow: +/-80
3. InpJumpSigmaK: +/-0.25
4. InpNuEmaAlpha: +/-0.06
5. InpLambdaEmaAlpha: +/-0.06
6. InpThreshAdaptK: +/-0.03
7. InpStrengthAdaptK: +/-0.04
8. InpValidationWindow: +/-60
9. InpValHealthy: +/-0.03
10. InpValWarning: +/-0.03

Regla dura: no cambiar mas de 5 parametros totales por semana.

## 6. Proceso de Recalibracion (Paso a Paso)

1. Compute weekly KPI pack:
- Return, PF, hit-rate, expectancy
- Health avg, ValScore avg, ExecScore avg
- State distribution (HEALTHY/WARNING/DEFENSIVE)

2. Diagnostico causal:
- Si falla ejecucion: ajustar primero InpExecSpreadPenalty o exec minima.
- Si falla calibracion de regime: ajustar InpThresh / InpValidationWindow.
- Si falla estabilidad dinamica: ajustar InpNuEmaAlpha / InpLambdaEmaAlpha.

3. Crear propuesta candidata dentro de limites de cambio.

4. Backtest walk-forward rapido:
- Train 12w / Validate 4w
- Debe mejorar al menos 2 de 3 ejes:
  - ValScore
  - Drawdown control
  - Execution quality

5. Simulacion paper forward 1 semana (shadow mode):
- Sin capital real, solo observacion de estabilidad.

6. Aprobacion final y despliegue lunes.

## 7. Criterios de Aprobacion (Go / No-Go)

Go si todos se cumplen:
1. ValScore promedio >= 0.64
2. Health promedio >= 0.62
3. Execution score promedio >= 0.60
4. DEFENSIVE state <= 20% del tiempo
5. Max drawdown semanal <= budget

No-Go si cualquiera falla.

## 8. Rollback Protocol (Obligatorio)

1. Guardar snapshot de parametros previos antes de aplicar cambios.
2. Trigger de rollback inmediato:
- 2 sesiones consecutivas en DEFENSIVE
- O DD diario > 1.50%
- O Execution score < 0.50 por 2 sesiones
3. Revertir al ultimo baseline aprobado (T-1 week).
4. Abrir incident review de 24h.

## 9. Registro y Auditoria

Cada semana guardar:
1. Week ID
2. Parametros previos y nuevos
3. KPI pre y post
4. Decision log (Go/No-Go + responsable)
5. Resultado de semana siguiente

Formato sugerido: CSV o JSON versionado en repo.

## 10. Plantilla de Decision Semanal

1. Week: YYYY-WW
2. Estado actual: HEALTHY / WARNING / DEFENSIVE
3. Trigger de recalibracion: SI / NO
4. Parametros modificados (max 5):
- P1 old -> new
- P2 old -> new
5. KPI esperado de mejora:
- Metric A: target
- Metric B: target
6. Decision: GO / NO-GO
7. Responsable:
8. Fecha de proxima revision:

## 11. Recomendacion Inicial para Tu Caso (Balanced)

Semana 0 (baseline):
1. No tocar risk percent.
2. Monitorear 2 semanas solo con telemetria.
3. Priorizar ajuste de ejecucion antes que ajuste de modelo.

Semana 1+:
1. Si ExecScore < 0.60: subir InpExecMinHealthy +0.02 y InpExecSpreadPenalty +0.03.
2. Si ValScore < 0.64 y Health estable: subir InpValidationWindow +40.
3. Si Health < 0.62 por ruido: bajar InpNuEmaAlpha y InpLambdaEmaAlpha en 0.03.
