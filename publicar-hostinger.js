/* ------------------------------------------------------------------
   Publica el sitio en la rama `hostinger`, que es la que baja Hostinger.
   Uso:  node publicar-hostinger.js

   Hostinger copia la RAIZ de la rama a public_html, asi que esa rama
   tiene que tener index.html y .htaccess sueltos en la raiz. Por eso no
   se publica `main`: ahi el sitio vive en build/ (que no se sube) y
   ademas estan build.js, pagopar/ y supabase/, que son del servidor.
------------------------------------------------------------------ */
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const RAMA = 'hostinger';
const OUT = 'build';
/* Fuera del repo: una carpeta de trabajo adentro confundiria a git y al build. */
const WORKTREE = path.resolve('..', '.deploy-hostinger');

function git(...args) {
  return execFileSync('git', args, { encoding: 'utf8' }).trim();
}

execFileSync('node', ['build.js'], { stdio: 'inherit' });

if (!fs.existsSync(path.join(OUT, 'index.html'))) {
  console.error('No encuentro build/index.html. El build no termino bien.');
  process.exit(1);
}

git('fetch', 'origin', RAMA);
if (!fs.existsSync(WORKTREE)) {
  git('worktree', 'add', WORKTREE, RAMA);
}
execFileSync('git', ['checkout', RAMA], { cwd: WORKTREE, stdio: 'inherit' });
execFileSync('git', ['reset', '--hard', `origin/${RAMA}`], { cwd: WORKTREE, stdio: 'inherit' });

/* El sitio es el build entero: lo que ya no se genera tiene que desaparecer. */
for (const entrada of fs.readdirSync(WORKTREE)) {
  if (entrada === '.git') continue;
  fs.rmSync(path.join(WORKTREE, entrada), { recursive: true, force: true });
}
fs.cpSync(OUT, WORKTREE, { recursive: true });

execFileSync('git', ['add', '-A'], { cwd: WORKTREE, stdio: 'inherit' });
const pendiente = execFileSync('git', ['status', '--porcelain'], { cwd: WORKTREE, encoding: 'utf8' }).trim();
if (!pendiente) {
  console.log('El sitio publicado ya estaba al dia: no hay nada que subir.');
  process.exit(0);
}

const sello = new Date().toISOString().slice(0, 16).replace('T', ' ');
execFileSync('git', ['commit', '-m', `Publicacion del sitio ${sello}`], { cwd: WORKTREE, stdio: 'inherit' });
execFileSync('git', ['push', 'origin', RAMA], { cwd: WORKTREE, stdio: 'inherit' });

console.log(`\nListo. Rama ${RAMA} actualizada. En Hostinger: Git -> Implementar.`);
