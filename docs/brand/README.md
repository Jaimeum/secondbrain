# secondbrain — Brand kit v1.0

Esta entrega utiliza exclusivamente el **concepto elegido 03 — Red orgánica**, con cuatro lóbulos asimétricos y un espacio negativo central. El nombre oficial es **secondbrain** y el producto es una **desktop app**.

## Carpetas
- **01_icons:** ícono principal basado en el render 03 aprobado (`PRIMARY`), 4096 y tamaños de exportación; versiones vectoriales claras, oscuras y verde; archivos Windows `.ico` y macOS `.iconset`.
- **02_logos:** logotipos y símbolo con versiones SVG y PNG; horizontal, vertical, monocromo y línea.
- **03_brand_graphics:** fondos 4K, pantallas de splash y conceptos de aplicación desktop, todo por separado.
- **04_guidelines:** guía de marca en PDF; reglas cromáticas, de tipografía, uso y producto.
- **05_motion:** guion de movimiento en español, storyboard y ocho referencias de fotogramas.
- **06_source:** recorte del 03 aprobado, conservado como referencia original del concepto.
- **brand_tokens.json:** tokens de diseño.

## Importante: precisión del master
El `PRIMARY` es el arte raster derivado de la imagen elegida en la conversación, escalado para entregar exportes grandes; **no equivale a un render nativo a 4096 píxeles**. Sus tamaños pequeños y su `.ico` parten de ese arte. Los `SVG` constituyen una **reconstrucción vectorial** de la geometría 03 para aplicaciones escalables; conservan el concepto, pero NO son un calco exacto del volumen y las transparencias de la imagen original. Por ello, deben validarse contra el reference master antes del lanzamiento.

Para generar ICNS desde `secondbrain.iconset` en macOS: `iconutil -c icns secondbrain.iconset`. También se puede configurar el `.icns` desde Xcode o el empacador de Electron/Tauri.

Los diseños de interfaz son mockups con contenido ilustrativo, no evidencia de funcionalidades implementadas. El claim `Tu conocimiento, conectado` es una propuesta, no un compromiso definitivo de producto.
