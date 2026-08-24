# MANASTINA — Tienda online

Tienda de carteras, bolsos y accesorios. **Llena de Gracia** · Capiatá, Paraguay.

Sitio de una sola página, sin build ni dependencias: se abre directamente en el navegador.

## Cómo verlo en local

```bash
npx serve .
```

Y abrir `Manastina Tienda.dc.html`.

## Estructura

| Archivo | Qué contiene |
|---|---|
| `Manastina Tienda.dc.html` | Toda la interfaz: inicio, tienda, ficha de producto, carrito, nosotros y contacto |
| `datos-manastina.js` | **Catálogo editable**: productos, precios, stock, colores, fotos, marcas, categorías y datos de contacto |
| `assets/` | Fotos del catálogo, logos de marcas y videos |
| `support.js`, `image-slot.js` | Motor de plantillas (no editar) |

## Editar el catálogo

Todo se cambia en `datos-manastina.js`:

```js
{ id: "c01", marca: "Guess", nombre: "Claudia Satchel Guess", categoria: "carteras",
  precio: 620000, nuevo: true, seleccion: false, stock: 5,
  descripcion: "...",
  incluye: "Cartera + documentera",        // solo para los sets
  colores: [{ nombre: "Negro", hex: "#1A1114" }],
  imagenes: ["assets/catalogo/foto-1.jpeg", "assets/catalogo/foto-2.jpeg"] }
```

- La **primera imagen** es la portada; las demás son los otros ángulos.
- `nuevo: true` lo muestra en "Nuevos ingresos" del inicio.
- `seleccion: true` lo muestra en la selección destacada.
- El **filtro de precio** ajusta su tope solo, según el producto más caro.
- Los pedidos se envían por WhatsApp al número definido en `contacto`.
