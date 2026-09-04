/* ------------------------------------------------------------------
   Build de MANASTINA para hosting propio (Hostinger / Apache).
   Uso:  node build.js
   Genera la carpeta build/ lista para subir a public_html.
------------------------------------------------------------------ */
const fs = require('fs');
const path = require('path');

const SITIO = 'https://manastina.com';   // dominio de producción
const OUT = 'build';

/* Se vacía el contenido en vez de borrar la carpeta: en Windows es muy común
   que algo la tenga tomada (el explorador, un servidor local, el antivirus) y
   entonces borrarla falla con EPERM aunque los archivos de adentro sí se
   puedan reemplazar. */
if (fs.existsSync(OUT)) {
  for (const entrada of fs.readdirSync(OUT)) {
    fs.rmSync(path.join(OUT, entrada), { recursive: true, force: true });
  }
} else {
  fs.mkdirSync(OUT, { recursive: true });
}

/* Datos de Supabase para el cobro online. Salen de pagopar/config.env, que no
   se sube a git. La anon key es pública por diseño: puede ir en el HTML.
   La clave privada de PagoPar NO pasa por acá — vive solo en el servidor. */
function leerConfig(archivo) {
  if (!fs.existsSync(archivo)) return {};
  const conf = {};
  for (const linea of fs.readFileSync(archivo, 'utf8').split(/\r?\n/)) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(linea.trim());
    if (m && !/COMPLETAR/.test(m[2])) conf[m[1]] = m[2].trim();
  }
  return conf;
}
const conf = leerConfig(path.join('pagopar', 'config.env'));
const SB_URL = conf.SUPABASE_PROJECT_URL || 'https://api.neura.com.py';
const SB_ANON = conf.SUPABASE_ANON_KEY || '';

if (!SB_ANON) {
  console.warn('  aviso: sin SUPABASE_ANON_KEY en pagopar/config.env — el botón de PagoPar queda oculto');
}

function inyectarSupabase(txt, esHtmlSuelto) {
  const decl = esHtmlSuelto ? 'var' : 'const';
  return txt
    .replace(
      new RegExp(decl + ' SUPABASE_URL = "[^"]*";'),
      decl + ' SUPABASE_URL = "' + SB_URL + '";'
    )
    .replace(
      new RegExp(decl + ' SUPABASE_ANON = "[^"]*";'),
      decl + ' SUPABASE_ANON = "' + SB_ANON + '";'
    );
}

/* Las tarifas de envío viven en config.env. Acá se copian al HTML: al objeto
   TARIFAS_ENVIO y también a las etiquetas del <select>, para que el precio que
   ve el cliente y el que cobra el servidor no puedan desfasarse. */
function sincronizarEnvios(txt) {
  let tarifas;
  try {
    tarifas = JSON.parse(conf.ENVIO_TARIFAS_JSON || '{}');
  } catch (e) {
    console.warn('  aviso: ENVIO_TARIFAS_JSON no es JSON válido; se dejan las tarifas del HTML');
    return txt;
  }
  if (!Object.keys(tarifas).length) return txt;

  txt = txt.replace(
    /const TARIFAS_ENVIO = \{[^;]*\};/,
    'const TARIFAS_ENVIO = ' + JSON.stringify(tarifas) + ';'
  );

  // <option value="capiata">Capiatá — Gs. 10.000</option>
  return txt.replace(
    /(<option value="([a-z0-9-]+)">)([^<—]+)(?: — [^<]*)?(<\/option>)/g,
    (todo, abre, clave, nombre, cierra) => {
      if (!(clave in tarifas)) return todo;
      const gs = 'Gs. ' + Number(tarifas[clave]).toLocaleString('es-PY').replace(/,/g, '.');
      return abre + nombre.trim() + ' — ' + gs + cierra;
    }
  );
}

// 1) la página pasa a llamarse index.html y apunta al dominio real
let html = fs.readFileSync('Manastina Tienda.dc.html', 'utf8');
html = html.replace(/const SITIO = "[^"]*";/, 'const SITIO = "' + SITIO + '";');
html = inyectarSupabase(html, false);
html = sincronizarEnvios(html);
fs.writeFileSync(path.join(OUT, 'index.html'), html);

// 1b) página de retorno de PagoPar
let pago = fs.readFileSync('pago.html', 'utf8');
pago = inyectarSupabase(pago, true);
fs.writeFileSync(path.join(OUT, 'pago.html'), pago);

// 2) scripts y datos
for (const f of ['support.js', 'image-slot.js', 'datos-manastina.js']) {
  fs.copyFileSync(f, path.join(OUT, f));
}

// 3) imágenes y videos
fs.cpSync('assets', path.join(OUT, 'assets'), { recursive: true });

// 4) una página por producto, con Open Graph para la vista previa de WhatsApp
global.window = {};
require(process.cwd() + '/datos-manastina.js');
const datos = window.MANASTINA_DATOS;
const cats = {};
datos.categorias.forEach(c => { cats[c.id] = c.nombre; });
const fmt = n => 'Gs. ' + Number(n).toLocaleString('es-PY').replace(/,/g, '.');
const esc = t => String(t).replace(/&/g, '&amp;').replace(/</g, '&lt;')
                          .replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/* La tienda se llena desde el ERP (Edge Function `catalogo`). Para que el
   "Consultar por WhatsApp" muestre el preview con la foto real del producto,
   WhatsApp necesita scrapear un HTML en manastina.com con og:image apuntando
   a la foto. Como el HTML de la home usa un og:image generico (el logo), se
   genera al build una pagina chiquita por producto en /p/<codigo>.html:

   - Trae los productos del ERP con el mismo endpoint que usa la tienda.
   - Escribe una pagina con og:title/og:image/og:url y un meta-refresh a la
     ficha del producto (?p=<codigo>). WhatsApp lee los meta, el visitante
     humano cae en la ficha.

   Si el ERP no responde (offline, sin ANON), se sigue con los productos
   hardcodeados en datos-manastina.js (que hoy es lista vacia). El build no
   falla nunca por esto. */
async function traerProductosDelErp() {
  if (!SB_ANON) return [];
  try {
    const res = await fetch(SB_URL + '/functions/v1/catalogo', {
      headers: { apikey: SB_ANON, Authorization: 'Bearer ' + SB_ANON },
    });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    const j = await res.json();
    return Array.isArray(j?.productos) ? j.productos : [];
  } catch (e) {
    console.warn('  aviso: no se pudo leer el catalogo del ERP (' + e.message + '), se omiten las paginas /p/');
    return [];
  }
}

const dirP = path.join(OUT, 'p');
fs.mkdirSync(dirP, { recursive: true });

function escribirFichaProducto(p, opts) {
  opts = opts || {};
  /* La foto principal puede venir como URL absoluta (ERP) o como path
     relativo (datos-manastina.js). En ambos casos WhatsApp necesita URL
     absoluta con https, asi que se completa cuando hace falta. */
  /* El endpoint /catalogo del ERP devuelve la portada en `imagen` (string) y
     la galeria completa en `imagenes` (array, puede estar vacio). Los
     productos hardcodeados en datos-manastina.js solo tienen `imagenes`. Se
     prueba en ese orden para siempre agarrar la mejor. */
  const primeraFoto = (p.imagenes && p.imagenes[0])
    || p.imagen
    || opts.fotoFallback
    || 'assets/manastina-logo-completo.png';
  const img = /^https?:\/\//i.test(primeraFoto)
    ? primeraFoto
    : SITIO + '/' + primeraFoto.split(' ').join('%20');
  const titulo = p.nombre + ' · ' + fmt(p.precio);
  const nombreCat = opts.nombreCategoria || cats[p.categoria] || '';
  const desc = (p.marca ? p.marca + ' · ' : '') + nombreCat + '. ' + (p.descripcion || '');
  const destino = SITIO + '/?p=' + encodeURIComponent(p.id);
  const doc = [
    '<!DOCTYPE html>', '<html lang="es">', '<head>', '<meta charset="utf-8">',
    '<title>' + esc(titulo) + ' — MANASTINA</title>',
    '<meta name="description" content="' + esc(desc) + '">',
    '<meta property="og:type" content="product">',
    '<meta property="og:site_name" content="MANASTINA">',
    '<meta property="og:title" content="' + esc(titulo) + '">',
    '<meta property="og:description" content="' + esc(desc) + '">',
    '<meta property="og:image" content="' + img + '">',
    '<meta property="og:url" content="' + destino + '">',
    '<meta name="twitter:card" content="summary_large_image">',
    '<meta name="twitter:image" content="' + img + '">',
    '<link rel="canonical" href="' + destino + '">',
    '<meta http-equiv="refresh" content="0; url=' + destino + '">',
    '<script>location.replace(' + JSON.stringify(destino) + ');</script>',
    '</head>',
    '<body style="font-family:system-ui,sans-serif;background:#F9F1EA;color:#331821;text-align:center;padding:40px">',
    '<p>Abriendo <strong>' + esc(p.nombre) + '</strong>…</p>',
    '<p><a href="' + destino + '">Ver en la tienda</a></p>',
    '</body>', '</html>'
  ].join('\n');
  const nombreArchivo = String(p.id).replace(/[^a-zA-Z0-9._-]/g, '_') + '.html';
  fs.writeFileSync(path.join(dirP, nombreArchivo), doc);
}

datos.productos.forEach(p => escribirFichaProducto(p));

/* Async top-level: se resuelve la promesa antes de terminar el build. */
(async () => {
  const delErp = await traerProductosDelErp();
  /* Mapa de nombre de categoria por clave, tal como devuelve el endpoint
     /catalogo, para que la descripcion salga con el nombre y no la clave. */
  const catsErp = {};
  try {
    const res = SB_ANON ? await fetch(SB_URL + '/functions/v1/catalogo', {
      headers: { apikey: SB_ANON, Authorization: 'Bearer ' + SB_ANON },
    }) : null;
    if (res && res.ok) {
      const j = await res.json();
      (j.categorias || []).forEach(c => { catsErp[c.id] = c.nombre; });
    }
  } catch { /* ya se avisa arriba */ }

  const idsYaEscritos = new Set(datos.productos.map(p => String(p.id)));
  let escritos = 0;
  for (const p of delErp) {
    if (!p || !p.id) continue;
    if (idsYaEscritos.has(String(p.id))) continue;
    escribirFichaProducto(p, { nombreCategoria: catsErp[p.categoria] });
    escritos++;
  }

  // 5) catálogo en JSON — lo lee la Edge Function "crear-pago" para validar
  //    los precios del lado del servidor y no confiar en lo que manda el navegador
  const catalogo = datos.productos.concat(delErp).map(p => ({
    id: p.id,
    nombre: p.nombre,
    precio: p.precio,
    stock: p.stock,
  }));
  fs.writeFileSync(
    path.join(OUT, 'catalogo.json'),
    JSON.stringify(catalogo, null, 2)
  );

  const total = fs.readdirSync(OUT).length;
  console.log('build listo en ' + OUT + '/  ·  ' + datos.productos.length + ' productos locales + ' + escritos + ' productos del ERP  ·  ' + total + ' entradas en la raíz');
})();

// 6) configuración de Apache e instructivo
fs.copyFileSync('htaccess.txt', path.join(OUT, '.htaccess'));
fs.copyFileSync('LEEME-hostinger.txt', path.join(OUT, 'LEEME-hostinger.txt'));
