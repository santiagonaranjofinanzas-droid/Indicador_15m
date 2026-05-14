# Entorno Institucional - Despliegue Demo

## Alcance de auditoria aplicada
- Endurecimiento del servidor TCP Python para framing robusto y validacion de payloads.
- Correccion de estabilidad numerica en riesgo EVT/Kelly y spread implicito.
- Correccion de fuga de estado en validacion walk-forward purgada.
- Endurecimiento del bridge OMS en MQL5 para ejecucion y mensajeria.
- Versionado reproducible de dependencias Python.

## 1) Pre-requisitos
- MetaTrader 5 abierto con AutoTrading habilitado.
- Python virtualenv del workspace activo en `.venv`.
- Cuenta DEMO conectada y simbolo habilitado (ejemplo: XAUUSD).

## 2) Instalacion de dependencias
Desde la raiz del workspace:

```powershell
& ".venv/Scripts/python.exe" -m pip install -r "Entorno_institucional/Python/requirements.txt"
```

## 3) Preflight tecnico
Ejecutar chequeo rapido del motor:

```powershell
& ".venv/Scripts/python.exe" "Entorno_institucional/Python/demo_preflight.py"
```

Resultado esperado: JSON con `"preflight":"ok"`.

## 4) Levantar servidor demo

```powershell
& "Entorno_institucional/Python/start_demo_server.ps1" -Host "127.0.0.1" -Port 8888 -LogLevel INFO
```

Variables opcionales disponibles en [Entorno_institucional/Python/.env.example](Entorno_institucional/Python/.env.example).

## 5) Configurar EA OMS en MT5
Archivo: [Entorno_institucional/MQL5/Experts/Black_Knight_Aut_System_OMS.mq5](Entorno_institucional/MQL5/Experts/Black_Knight_Aut_System_OMS.mq5)

Parametros recomendados para DEMO inicial:
- `InpHost`: `127.0.0.1`
- `InpPort`: `8888`
- `InpMagic`: `40001`
- `InpRisk`: `0.5` a `1.0`

## 6) Checklist go-live demo
- [ ] Python server responde `ready` tras warmup.
- [ ] OMS cambia a estado activo (sin errores de socket).
- [ ] Primeras senales llegan con `direction` y `optimal_f` validos.
- [ ] Ordenes se ejecutan con SL/TP y volumen dentro de limites del broker.
- [ ] Monitoreo de logs por al menos 1 sesion completa antes de escalar riesgo.

## 7) Rollback rapido
- Detener servidor Python.
- Retirar EA del chart o desactivar AutoTrading.
- Reducir `InpRisk` y reiniciar con preflight + nueva sesion de observacion.
