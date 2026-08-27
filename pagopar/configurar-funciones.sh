#!/usr/bin/env bash
# =============================================================================
# MANASTINA · Dejar el contenedor de funciones listo
# =============================================================================
# Se corre EN EL SERVIDOR, después de desplegar-funciones.sh:
#
#   curl -fsSL https://raw.githubusercontent.com/bartsilvera12-gif/manastina-tienda/main/pagopar/configurar-funciones.sh | bash
#
# Le engancha al servicio `functions` el archivo de variables del cliente, para
# que las funciones vean sus claves de PagoPar.
#
# Antes de tocar el docker-compose.yml hace una copia con la fecha al lado, y
# si el resultado no es válido la restaura sola.
#
# El control de acceso (VERIFY_JWT) NO se toca acá: si hace falta ajustarlo,
# el script lo detecta y te dice qué pasa, sin modificar nada.
# =============================================================================
set -euo pipefail

DOCKER_DIR="${DOCKER_DIR:-/root/supabase/docker}"
ENV_CLIENTE="${ENV_CLIENTE:-./clientes/manastina.env}"

COMPOSE="$DOCKER_DIR/docker-compose.yml"
ENV_FILE="$DOCKER_DIR/.env"
SELLO="$(date +%Y%m%d-%H%M%S)"

azul()  { printf '\n\033[1;34m%s\033[0m\n' "$*"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$*"; }
aviso() { printf '  \033[33m!\033[0m %s\n' "$*"; }
error() { printf '  \033[31m✗\033[0m %s\n' "$*"; }

# --- 1. El archivo de variables ----------------------------------------------
azul "1. Variables del cliente"

RUTA_ABS="$DOCKER_DIR/${ENV_CLIENTE#./}"
if [ ! -f "$RUTA_ABS" ]; then
  error "No existe $RUTA_ABS"
  exit 1
fi

FALTAN=()
for v in MANASTINA_PAGOPAR_PUBLIC_KEY MANASTINA_PAGOPAR_PRIVATE_KEY \
         MANASTINA_SITIO_URL MANASTINA_SUPABASE_SCHEMA; do
  grep -q "^${v}=" "$RUTA_ABS" || FALTAN+=("$v")
done
if [ ${#FALTAN[@]} -gt 0 ]; then
  error "Al archivo le faltan variables:"
  for v in "${FALTAN[@]}"; do echo "        $v"; done
  exit 1
fi

if grep -qE '^MANASTINA_PAGOPAR_(PUBLIC|PRIVATE)_KEY=PEGA_ACA' "$RUTA_ABS"; then
  error "Las claves siguen con el texto de ejemplo (PEGA_ACA...)."
  echo "     Editá $RUTA_ABS y poné las reales."
  exit 1
fi
ok "$ENV_CLIENTE tiene las claves cargadas"

# --- 2. Engancharlo al servicio ----------------------------------------------
azul "2. Enganchando el archivo al contenedor"

if grep -q "$ENV_CLIENTE" "$COMPOSE"; then
  ok "El servicio ya lo tenía declarado"
else
  cp -p "$COMPOSE" "$COMPOSE.bak-$SELLO"
  ok "copia de seguridad: docker-compose.yml.bak-$SELLO"

  # Se inserta `env_file:` dentro del servicio `functions`, justo antes de su
  # primera clave hija. Se ubica por número de línea para no rozar otro
  # servicio del archivo.
  LINEA_SERVICIO=$(grep -n -m1 '^  functions:' "$COMPOSE" | cut -d: -f1)
  if [ -z "${LINEA_SERVICIO:-}" ]; then
    error "No encontré el servicio 'functions' en $COMPOSE"
    exit 1
  fi

  LINEA_INSERTAR=$(awk -v ini="$LINEA_SERVICIO" \
    'NR > ini && /^    [a-zA-Z_]+:/ { print NR; exit }' "$COMPOSE")

  if [ -z "${LINEA_INSERTAR:-}" ]; then
    error "No pude ubicar dónde insertar dentro de 'functions'"
    exit 1
  fi

  awk -v n="$LINEA_INSERTAR" -v arch="$ENV_CLIENTE" \
    'NR == n {
       print "    # Variables por cliente: un archivo cada uno, asi no se pisan."
       print "    env_file:"
       print "      - " arch
     }
     { print }' "$COMPOSE" > "$COMPOSE.nuevo"

  mv "$COMPOSE.nuevo" "$COMPOSE"
  ok "env_file agregado al servicio functions"
fi

# --- 3. Validar antes de aplicar ---------------------------------------------
azul "3. Validando el docker-compose.yml"

cd "$DOCKER_DIR"
if ! docker compose config </dev/null >/dev/null 2>&1; then
  error "Quedó mal formado. Restauro la copia y no aplico nada."
  [ -f "$COMPOSE.bak-$SELLO" ] && cp -p "$COMPOSE.bak-$SELLO" "$COMPOSE"
  docker compose config 2>&1 | head -20
  exit 1
fi
ok "Archivo válido"

# --- 4. Aplicar --------------------------------------------------------------
azul "4. Levantando el contenedor"

docker compose up -d functions </dev/null
ok "Contenedor levantado"
sleep 4

# --- 5. Comprobar ------------------------------------------------------------
azul "5. Comprobando"

# El </dev/null es imprescindible: este script suele correrse con
# `curl | bash`, asi que bash lo va leyendo de la entrada estandar. Sin
# cerrarsela, `docker compose exec -T` se come el resto del script y todo
# termina en silencio a la mitad.
leer_del_contenedor() {
  local v
  v=$(docker compose exec -T functions printenv "$1" </dev/null 2>/dev/null || true)
  v=${v%%$'\n'*}          # primera línea
  printf '%s' "${v%$'\r'}" # sin el retorno de carro de Windows
}

VISTO=$(leer_del_contenedor MANASTINA_PAGOPAR_PUBLIC_KEY)

if [ -n "$VISTO" ]; then
  ok "El contenedor ve las variables de Manastina"
else
  error "El contenedor NO ve MANASTINA_PAGOPAR_PUBLIC_KEY"
  echo "     Revisá que la ruta $ENV_CLIENTE sea correcta y volvé a correr."
fi

# --- 6. La URL de retorno ----------------------------------------------------
azul "6. URL de retorno"

# Docker Compose reemplaza ${...} también dentro de los archivos de entorno.
# La URL de retorno lleva un marcador que NO es para Docker: lo sustituye
# PagoPar por el código del pedido. Por eso va escapado con doble signo.
RETORNO=$(leer_del_contenedor MANASTINA_PAGOPAR_RETURN_URL)
echo "     ${RETORNO:-(vacía)}"

case "$RETORNO" in
  *'{hash}'*)
    ok "El marcador de PagoPar llegó entero" ;;
  *hash=)
    error "El marcador se perdió: PagoPar no va a poder marcar el pedido."
    echo "     Corregí esa línea en $RUTA_ABS poniéndole doble signo:"
    echo
    echo "       MANASTINA_PAGOPAR_RETURN_URL=https://manastina.com/pago.html?hash=\$\${hash}"
    echo
    echo "     Y volvé a correr este script." ;;
  "")
    aviso "No pude leer la URL de retorno." ;;
  *)
    aviso "La URL de retorno tiene una forma inesperada; revisala." ;;
esac

# --- 7. El control de acceso -------------------------------------------------
azul "7. Control de acceso del webhook"

VERIFICA=$(grep -E '^FUNCTIONS_VERIFY_JWT=' "$ENV_FILE" 2>/dev/null \
  | cut -d= -f2- | tr -d '"' | tr -d "'" || true)
echo "     FUNCTIONS_VERIFY_JWT = ${VERIFICA:-(sin definir)}"

if [ "${VERIFICA:-false}" != "true" ]; then
  ok "No exige JWT: el aviso de PagoPar va a entrar sin problema"
else
  aviso "Exige JWT para TODAS las funciones."
  echo "     PagoPar no tiene la anon key de Supabase, así que su aviso de"
  echo "     pago va a rebotar con 401 y los pedidos nunca se van a marcar"
  echo "     como pagados. El cobro sale bien igual, pero nadie se entera."
  echo
  echo "     Hay que exceptuar SOLO pagopar-webhook en el router."
  echo "     No lo toco automáticamente: ese archivo lo usan todas las"
  echo "     funciones de todos los clientes."
  echo
  echo "     Avisame y te paso el cambio exacto."
fi

azul "Listo"
ANON=$(grep -E '^ANON_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || true)
echo "  Probando el catálogo desde adentro del servidor:"
echo
if [ -n "$ANON" ]; then
  CODIGO=$(curl -s -o /tmp/cat.json -w '%{http_code}' \
    "http://localhost:8000/functions/v1/catalogo" -H "apikey: $ANON" || echo "000")
  echo "    HTTP $CODIGO"
  case "$CODIGO" in
    200) ok "Anda. Primeros productos:"; head -c 300 /tmp/cat.json; echo ;;
    503) aviso "Faltan variables: revisá el paso 1." ;;
    401) aviso "Problema de JWT: mirá el paso 6." ;;
    *)   aviso "Respuesta inesperada. Mirá los logs:"
         echo "       docker compose logs --tail 40 functions" ;;
  esac
  rm -f /tmp/cat.json
else
  aviso "No pude leer ANON_KEY del .env para probar."
fi
