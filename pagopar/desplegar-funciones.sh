#!/usr/bin/env bash
# =============================================================================
# MANASTINA · Desplegar las Edge Functions en el Supabase propio
# =============================================================================
# Se corre EN EL SERVIDOR, no en tu máquina.
#
#   scp pagopar/desplegar-funciones.sh root@SERVIDOR:/root/
#   ssh root@SERVIDOR
#   bash /root/desplegar-funciones.sh
#
# O directo, sin copiar nada:
#
#   curl -fsSL https://raw.githubusercontent.com/bartsilvera12-gif/manastina-tienda/main/pagopar/desplegar-funciones.sh | bash
#
# Qué hace: baja el repo, copia las funciones a la carpeta que sirve el
# contenedor de Supabase, y lo reinicia. No toca la base ni ningún otro
# servicio.
#
# Las variables de entorno NO se cargan acá: van en el .env de Docker.
# El script te dice cuáles faltan antes de reiniciar.
# =============================================================================
set -euo pipefail

DOCKER_DIR="${DOCKER_DIR:-/root/supabase/docker}"
REPO_DIR="${REPO_DIR:-/root/manastina-tienda}"
REPO_URL="https://github.com/bartsilvera12-gif/manastina-tienda.git"

FUNCIONES=(catalogo crear-pago estado-pago pagopar-webhook)

azul()  { printf '\n\033[1;34m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
aviso() { printf '  \033[33m!\033[0m %s\n' "$*"; }
error() { printf '  \033[31m✗\033[0m %s\n' "$*"; }

# --- 1. Comprobaciones -------------------------------------------------------
azul "1. Revisando el servidor"

if [ ! -d "$DOCKER_DIR" ]; then
  error "No existe $DOCKER_DIR"
  echo "     Si Supabase está en otra ruta:  DOCKER_DIR=/otra/ruta bash $0"
  exit 1
fi
ok "Supabase en $DOCKER_DIR"

DESTINO="$DOCKER_DIR/volumes/functions"
if [ ! -d "$DESTINO" ]; then
  error "No existe $DESTINO"
  echo "     Esta instalación no sirve funciones desde una carpeta montada."
  echo "     Pasame el docker-compose.yml y vemos cómo desplegarlas."
  exit 1
fi
ok "Carpeta de funciones: $DESTINO"

# --- 2. Traer el código ------------------------------------------------------
azul "2. Trayendo el código de la tienda"

if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" fetch --quiet origin main
  git -C "$REPO_DIR" reset --quiet --hard origin/main
  ok "Actualizado desde GitHub"
else
  git clone --quiet --depth 1 "$REPO_URL" "$REPO_DIR"
  ok "Clonado en $REPO_DIR"
fi

echo "     commit: $(git -C "$REPO_DIR" log --oneline -1)"

# --- 3. Copiar las funciones -------------------------------------------------
azul "3. Copiando las funciones"

ORIGEN="$REPO_DIR/supabase/functions"

# El código compartido va primero: las funciones lo importan con ../_shared/
rm -rf "$DESTINO/_shared"
cp -r "$ORIGEN/_shared" "$DESTINO/_shared"
ok "_shared"

for f in "${FUNCIONES[@]}"; do
  if [ ! -f "$ORIGEN/$f/index.ts" ]; then
    error "falta $ORIGEN/$f/index.ts"
    exit 1
  fi
  rm -rf "${DESTINO:?}/$f"
  cp -r "$ORIGEN/$f" "$DESTINO/$f"
  ok "$f"
done

# --- 4. Variables de entorno -------------------------------------------------
azul "4. Revisando las variables de entorno"

ENV_FILE="$DOCKER_DIR/.env"
# Todas con prefijo MANASTINA_: el .env del servidor es compartido con otros
# clientes que tambien usan PagoPar, y sin prefijo se pisarian entre si.
NECESARIAS=(
  MANASTINA_PAGOPAR_PUBLIC_KEY
  MANASTINA_PAGOPAR_PRIVATE_KEY
  MANASTINA_SITIO_URL
  MANASTINA_SUPABASE_SCHEMA
  MANASTINA_PAGOPAR_RETURN_URL
  MANASTINA_PAGOPAR_WEBHOOK_URL
  MANASTINA_PAGOPAR_VENDEDOR_TELEFONO
  MANASTINA_PAGOPAR_VENDEDOR_DIRECCION
  MANASTINA_ENVIO_TARIFAS_JSON
)

FALTAN=()
for v in "${NECESARIAS[@]}"; do
  if ! grep -q "^${v}=" "$ENV_FILE" 2>/dev/null; then
    FALTAN+=("$v")
  fi
done

if [ ${#FALTAN[@]} -gt 0 ]; then
  aviso "Faltan ${#FALTAN[@]} variables en $ENV_FILE:"
  for v in "${FALTAN[@]}"; do echo "        $v"; done
  echo
  echo "     Copiá el contenido de pagopar/config.env al final de ese archivo."
  echo "     OJO: el .env de Docker no acepta comillas ni espacios alrededor del ="
  echo
  echo "     Además, el contenedor de funciones tiene que recibirlas. En"
  echo "     docker-compose.yml, en el servicio 'functions', bajo environment:"
  echo "       PAGOPAR_PUBLIC_KEY: \${PAGOPAR_PUBLIC_KEY}"
  echo "       ... una línea por variable."
  echo
  aviso "Sin esto las funciones arrancan pero devuelven 503."
else
  ok "Las ${#NECESARIAS[@]} variables están en el .env"
fi

# --- 5. El webhook tiene que entrar sin JWT ----------------------------------
azul "5. Revisando el acceso del webhook"

MAIN="$DESTINO/main/index.ts"
if [ -f "$MAIN" ]; then
  if grep -q "pagopar-webhook" "$MAIN"; then
    ok "main/index.ts ya deja pasar pagopar-webhook"
  else
    aviso "PagoPar no manda la anon key de Supabase: no la tiene."
    echo "     Si el router de main/index.ts exige JWT, el aviso de pago"
    echo "     va a rebotar con 401 y los pedidos nunca se marcan pagados."
    echo
    echo "     Hay que exceptuar SOLO esa función. La autenticación real es"
    echo "     el token SHA1 firmado con la clave privada, que se valida"
    echo "     dentro de la función."
    echo
    echo "     Pasame el contenido de $MAIN y te digo qué línea tocar."
  fi
else
  aviso "No hay main/index.ts; revisá cómo enruta esta instalación."
fi

# --- 6. Reiniciar ------------------------------------------------------------
azul "6. Reiniciando el contenedor de funciones"

cd "$DOCKER_DIR"
if docker compose ps functions >/dev/null 2>&1; then
  docker compose up -d functions
  ok "Contenedor reiniciado"
else
  aviso "No encontré un servicio llamado 'functions'."
  echo "     Servicios disponibles:"
  docker compose ps --services 2>/dev/null | sed 's/^/       /'
fi

azul "Listo"
echo "  Probá que responda:"
echo
echo "    curl -i https://api.neura.com.py/functions/v1/catalogo \\"
echo "      -H \"apikey: LA_ANON_KEY\""
echo
echo "  Tiene que devolver 200 con la lista de productos."
echo "  Si devuelve 503, faltan las variables del paso 4."
echo
echo "  Los logs, si algo falla:"
echo "    docker compose logs -f functions"
