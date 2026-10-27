# secondbrain — especificaciones de movimiento (propuestas)

**Plataforma:** aplicación de escritorio (macOS / Windows).  **Marca:** 03 Red orgánica; cuatro lóbulos asimétricos y una apertura interior. Todas las secuencias deben conservar esa topología.

## A. Aparición al abrir la app (1.6 s, no repetitiva)
- **0.00–0.18 s:** pantalla marfil `#F5F0E8`, solo un halo circular gris salvia difuso, opacidad 0→12%.
- **0.18–0.55 s:** aparece el símbolo con escala 90→98%, opacidad 0→100% y desenfoque gaussiano 16→0 px; no introducir puntos ni una figura diferente.
- **0.55–1.08 s:** los cuatro lóbulos se iluminan sucesivamente (superior, izquierdo, inferior, derecho), variación luminosa máxima de +8%, con desfase de 120 ms. El hueco central conserva su forma.
- **1.08–1.40 s:** escala 98→101.5→100%; llega el texto `secondbrain` mediante un fade 0→100% y desplazamiento vertical de 10→0 px.
- **1.40–1.60 s:** se atenúa halo y pasa a la interfaz mediante crossfade de 200 ms. Curva de salida: cubic-bezier(.16,1,.3,1).
- **Sonido:** ninguno por defecto. Fondo estático. No realizar giros completos ni pulsos agresivos.

## B. Carga de conocimiento (loop 2.0 s)
- El símbolo permanece centrado a 96–112 px en superficies claras u oscuras.
- Una banda de luz recorre, por segmentos, los cuatro lóbulos en sentido horario. Empezar por la parte alta; continuar por derecha, base e izquierda.
- Iluminar de forma superpuesta, jamás apagar tres lóbulos por completo. Oscilación de luminancia entre 92% y 108%; escala global fija.
- Mantener el hueco orgánico central inmóvil: la marca no debe convertirse en una rueda, estrella o un spinner convencional.
- Intensidad más baja para procesos en segundo plano; incluir texto de estado en cargas superiores a 3 s.
- Render a 60 fps; sincronizar por tiempo real, no por contador de frames.

## C. Captura completada (650 ms)
- De 0 a 180 ms: al confirmar nota guardada, escala 100→104%, sombreado +7%.
- 180 a 480 ms: el símbolo retorna 104→100%, una onda difusa de opacidad 12%→0% se expande hasta 1.25×.
- 480 a 650 ms: se recupera el estado basal. No usar confeti, check gigantes o destellos de IA genéricos.

## D. Conexión encontrada (900 ms)
- Inicial: dos pequeños puntos secundarios en lados diferentes del símbolo. Son indicadores periféricos, NO reemplazos del logo.
- 0–500 ms: una línea fina (1.5 px) se dibuja en una curva Bezier uniendo ambos puntos a través del exterior del logo; el centro permanece abierto.
- 500–900 ms: los puntos se fusionan cromáticamente hacia salvia, y la línea se desvanece, dejando el símbolo sin modificaciones.

## E. Estados, tiempo y accesibilidad
- Si el proceso dura <350 ms: evitar un indicador para no producir parpadeo.
- Si dura 350 ms–3 s: mostrar animación sin porcentaje ficticio.
- Si dura >3 s: añadir estado textual basado en etapas reales: `Preparando…`, `Conectando ideas…` o estados determinados por el producto.
- **Reduced motion:** logo fijo; único fade de 150 ms o indicador de texto/avance real.
- **Accesibilidad:** no usar solo color para comunicar guardado/error; mostrar texto y estado accesible.
- **Exportes recomendados:** Rive o Lottie (vectores simplificados), 60 fps, composiciones 256×256 y 512×512. El símbolo renderizado con gradientes detallados puede usarse como PNG/WebP para pantallas de arranque.

**Nota:** los ocho PNG de storyboard son referencias visuales; no son fotogramas exactos de una animación de producción.
