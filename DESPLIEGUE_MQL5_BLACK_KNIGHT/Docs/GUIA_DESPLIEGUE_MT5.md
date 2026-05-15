# Guía de Instalación: Black Knight Aut System (MT5)

He consolidado todos los archivos necesarios en la carpeta `DESPLIEGUE_MQL5_BLACK_KNIGHT`. Sigue estos pasos para instalar el sistema correctamente en tu terminal MetaTrader 5.

## 📁 Paso 1: Localizar la Carpeta de Datos de MT5
1. Abre tu **MetaTrader 5**.
2. En el menú superior, ve a **Archivo (File)** -> **Abrir Carpeta de Datos (Open Data Folder)**.
3. Se abrirá una ventana del explorador de Windows. Entra en la carpeta llamada **MQL5**.

## 🚚 Paso 2: Copiar los Archivos
Copia el contenido de la carpeta que he creado (`DESPLIEGUE_MQL5_BLACK_KNIGHT`) hacia la carpeta de datos de MT5 de la siguiente manera:

- **Experts**: Copia los archivos dentro de `DESPLIEGUE_MQL5_BLACK_KNIGHT/Experts/` a la carpeta `MQL5/Experts/` de tu MT5.
- **Indicators**: Copia los archivos dentro de `DESPLIEGUE_MQL5_BLACK_KNIGHT/Indicators/` a la carpeta `MQL5/Indicators/` de tu MT5.
- **Include**: Copia el archivo `.mqh` de `DESPLIEGUE_MQL5_BLACK_KNIGHT/Include/` a la carpeta `MQL5/Include/` de tu MT5.

## 🛠 Paso 3: Compilación
1. Regresa a MetaTrader 5.
2. Abre el **MetaEditor** (Presiona `F4` o haz clic en el icono del libro amarillo con un birrete).
3. En el navegador del MetaEditor (izquierda), busca la carpeta **Indicators** y abre `Black_Knight_Aut_System_Engine.mq5`. Haz clic en **Compilar (Compile)** en la parte superior.
4. Luego, en la carpeta **Experts**, abre `Black_Knight_Aut_System_Master.mq5` y haz clic en **Compilar**.
   - *Nota: Asegúrate de que no haya errores en la pestaña "Errores" abajo.*

## ⚙️ Paso 4: Configuración Final en MT5
1. Cierra el MetaEditor y vuelve a MT5.
2. En la ventana **Navegador (Navigator)** (`Ctrl+N`), haz clic derecho en "Asesores Expertos" y selecciona **Actualizar (Refresh)**.
3. **IMPORTANTE**: Ve a **Herramientas (Tools)** -> **Opciones (Options)** -> **Asesores Expertos**.
   - Marca la casilla **Permitir WebRequest para las siguientes URLs**.
   - Añade `http://127.0.0.1:8888` (o la dirección de tu servidor Python).
   - Asegúrate de que **Permitir Trading Algorítmico** esté activado.

## 🚀 Paso 5: Lanzamiento
1. Arrastra el **Black_Knight_Aut_System_Engine** a un gráfico de 15 minutos (M15).
2. Arrastra el **Black_Knight_Aut_System_Master** al mismo gráfico (o a otro si prefieres).
3. Asegúrate de que el servidor Python (`quant_server.py`) esté corriendo antes de activar el EA.

---

> [!IMPORTANT]
> **Modo Recolección de Datos**
> Por defecto, el EA Master tiene el parámetro `InpUseXGBoostGate` en `false`. Déjalo así mientras realizas el backtest para generar el archivo `Black_Knight_Telemetry.csv` necesario para entrenar tu modelo por primera vez.
