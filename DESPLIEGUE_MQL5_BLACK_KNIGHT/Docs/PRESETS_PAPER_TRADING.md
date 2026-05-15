# Black_Knight_Aut_System MT5 - Institutional Paper Trading Presets

Date: 2026-04-12
Scope: Fase 1-4 already implemented in signal and master EA.
Use: Initial calibration for paper trading only.

## Governance First (Mandatory)

1. Max intraday drawdown stop: 1.50% of account equity.
2. Max weekly drawdown stop: 3.50% of account equity.
3. If state = DEFENSIVE for 3 consecutive sessions, pause deployment and re-validate.
4. No transition to live unless all acceptance metrics are met for at least 8 continuous weeks.

## Acceptance Metrics for Promotion (Paper -> Live)

1. Deflated Sharpe (or robust proxy) > 0.8
2. Profit factor > 1.25
3. Win-rate stability by regime: std deviation < 12 percentage points
4. No single-day loss beyond 1.25x expected daily loss budget
5. Execution score average >= threshold in at least 80% of triggered entries

## Profile A - Conservative (Institutional Capital Preservation)

### EA inputs (Black_Knight_Aut_System_Master.mq5)

InpMinStrength=0.42
InpVolMultiplier=2.80
InpRewardRisk=2.20
InpUsePartials=true
InpRiskPercent=0.35
InpMaxLot=2.00
InpUseHealthRisk=true
InpHealthHardStop=0.40
InpHealthWarn=0.68
InpRiskFloorMult=0.20
InpRiskCeilMult=0.80
InpUseMetaExecution=true
InpExecMinHealthy=0.68
InpExecMinWarning=0.80
InpExecSpreadPenalty=0.45
InpTelemetryEmaAlpha=0.12

### Indicator inputs (Black_Knight_Aut_System_Engine.mq5)

InpRetWindow=24
InpVolWindow=80
InpThresh=0.70
InpGarchOmega=0.000001
InpGarchAlpha=0.04
InpGarchGamma=0.06
InpGarchBeta=0.88
InpLongRunW=180
InpRecalibWindow=700
InpJumpSigmaK=3.50
InpKalmanQ=0.00006
InpKalmanR=0.02000
InpKalmanGate=true
InpOUWindow=90
InpDriftWindow=2500
InpHealthWindow=350
InpNuEmaAlpha=0.12
InpLambdaEmaAlpha=0.10
InpThreshAdaptK=0.16
InpStrengthAdaptK=0.22
InpValidationWindow=420
InpValHealthy=0.75
InpValWarning=0.58
InpMinStrength=0.36

## Profile B - Balanced (Institutional Core Allocation)

### EA inputs (Black_Knight_Aut_System_Master.mq5)

InpMinStrength=0.35
InpVolMultiplier=2.50
InpRewardRisk=2.00
InpUsePartials=true
InpRiskPercent=0.60
InpMaxLot=4.00
InpUseHealthRisk=true
InpHealthHardStop=0.35
InpHealthWarn=0.62
InpRiskFloorMult=0.25
InpRiskCeilMult=1.00
InpUseMetaExecution=true
InpExecMinHealthy=0.60
InpExecMinWarning=0.74
InpExecSpreadPenalty=0.35
InpTelemetryEmaAlpha=0.20

### Indicator inputs (Black_Knight_Aut_System_Engine.mq5)

InpRetWindow=20
InpVolWindow=60
InpThresh=0.66
InpGarchOmega=0.000001
InpGarchAlpha=0.05
InpGarchGamma=0.05
InpGarchBeta=0.88
InpLongRunW=120
InpRecalibWindow=500
InpJumpSigmaK=3.00
InpKalmanQ=0.00010
InpKalmanR=0.01000
InpKalmanGate=true
InpOUWindow=60
InpDriftWindow=2000
InpHealthWindow=250
InpNuEmaAlpha=0.20
InpLambdaEmaAlpha=0.20
InpThreshAdaptK=0.12
InpStrengthAdaptK=0.18
InpValidationWindow=300
InpValHealthy=0.70
InpValWarning=0.50
InpMinStrength=0.30

## Profile C - Aggressive (Research Sleeve Only)

### EA inputs (Black_Knight_Aut_System_Master.mq5)

InpMinStrength=0.30
InpVolMultiplier=2.30
InpRewardRisk=1.80
InpUsePartials=true
InpRiskPercent=1.00
InpMaxLot=8.00
InpUseHealthRisk=true
InpHealthHardStop=0.30
InpHealthWarn=0.58
InpRiskFloorMult=0.35
InpRiskCeilMult=1.05
InpUseMetaExecution=true
InpExecMinHealthy=0.54
InpExecMinWarning=0.68
InpExecSpreadPenalty=0.25
InpTelemetryEmaAlpha=0.28

### Indicator inputs (Black_Knight_Aut_System_Engine.mq5)

InpRetWindow=16
InpVolWindow=48
InpThresh=0.62
InpGarchOmega=0.000001
InpGarchAlpha=0.06
InpGarchGamma=0.05
InpGarchBeta=0.86
InpLongRunW=90
InpRecalibWindow=350
InpJumpSigmaK=2.60
InpKalmanQ=0.00018
InpKalmanR=0.00800
InpKalmanGate=true
InpOUWindow=45
InpDriftWindow=1500
InpHealthWindow=180
InpNuEmaAlpha=0.30
InpLambdaEmaAlpha=0.28
InpThreshAdaptK=0.10
InpStrengthAdaptK=0.15
InpValidationWindow=220
InpValHealthy=0.66
InpValWarning=0.46
InpMinStrength=0.27

## Recommended Rollout Sequence

1. Start with Balanced for 4 weeks in paper.
2. If metrics exceed acceptance thresholds, run Conservative and Balanced in parallel for another 4 weeks.
3. Promote only one profile to live with reduced notional.
4. Keep Aggressive as research sleeve, never as first production profile.

## Daily Operating Checklist

1. Validate state distribution (HEALTHY/WARNING/DEFENSIVE).
2. Validate average execution score and spread ratio.
3. Validate no structural degradation in val score over the last 5 sessions.
4. If two consecutive days close in DEFENSIVE, halt and investigate.

## Weekly Recalibration Protocol

Balanced weekly recalibration process is documented in:

Black_Knight_Aut_System_MT5/PROTOCOLO_RECALIBRACION_SEMANAL_BALANCED.md
