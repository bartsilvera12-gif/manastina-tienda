/* ------------------------------------------------------------------
   Build de MANASTINA para hosting propio (Hostinger / Apache).
   Uso:  node build.js
   Genera la carpeta build/ lista para subir a public_html.
------------------------------------------------------------------ */
const fs = require('fs');
const path = require('path');

const SITIO = 'https://manastina.com';   // dominio de producción
const OUT = 'build';

fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });

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

// 1) la página pasa a llamarse index.html y apunta al dominio real
let html = fs.readFileSync('Manastina Tienda.dc.html', 'utf8');
html = html.replace(/const SITIO = "[^"]*";/, 'const SITIO = "' + SITIO + '";');
html = inyectarSupabase(html, false);
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

const dirP = path.join(OUT, 'p');
fs.mkdirSync(dirP, { recursive: true });

datos.productos.forEach(p => {
  const rel = (p.imagenes[0] || 'assets/manastina-logo-completo.png').split(' ').join('%20');
  const img = SITIO + '/' + rel;
  const titulo = p.nombre + ' · ' + fmt(p.precio);
  const desc = (p.marca ? p.marca + ' · ' : '') + (cats[p.categoria] || '') + '. ' + p.descripcion;
  const destino = SITIO + '/?p=' + p.id;
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
  fs.writeFileSync(path.join(dirP, p.id + '.html'), doc);
});

// 5) catálogo en JSON — lo lee la Edge Function "crear-pago" para validar
//    los precios del lado del servidor y no confiar en lo que manda el navegador
const catalogo = datos.productos.map(p => ({
  id: p.id,
  nombre: p.nombre,
  precio: p.precio,
  stock: p.stock,
}));
fs.writeFileSync(
  path.join(OUT, 'catalogo.json'),
  JSON.stringify(catalogo, null, 2)
);

// 6) configuración de Apache e instructivo
fs.copyFileSync('htaccess.txt', path.join(OUT, '.htaccess'));
fs.copyFileSync('LEEME-hostinger.txt', path.join(OUT, 'LEEME-hostinger.txt'));

const total = fs.readdirSync(OUT).length;
console.log('build listo en ' + OUT + '/  ·  ' + datos.productos.length + ' productos  ·  ' + total + ' entradas en la raíz');
