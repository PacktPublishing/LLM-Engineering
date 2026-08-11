#!/usr/bin/env bash
# Local setup + verification for LLM Engineer's Handbook.
#
# Usage:
#   ./scripts/local_setup.sh              # verify only
#   ./scripts/local_setup.sh --setup      # install deps, create .env, start Mongo/Qdrant, then verify
#   ./scripts/local_setup.sh --setup --with-zenml
#   ./scripts/local_setup.sh --help
#
# Exit codes:
#   0  all checked requirements passed
#   1  one or more checks failed
#   2  invalid arguments / not run from repo

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DO_SETUP=0
WITH_ZENML=0
PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
FAILURES=()

# Preferred Python for this project (.python-version = 3.11.8)
REQUIRED_PYTHON_MAJOR_MINOR="3.11"
PYENV_PYTHON="${PYENV_ROOT:-$HOME/.pyenv}/versions/3.11.8/bin/python"
REQUIRED_API_KEYS=(OPENAI_API_KEY HUGGINGFACE_ACCESS_TOKEN COMET_API_KEY)

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
else
  C_RESET=""; C_GREEN=""; C_RED=""; C_YELLOW=""; C_BOLD=""; C_DIM=""
fi

usage() {
  cat <<'EOF'
Local setup / verification for LLM Engineer's Handbook

Usage:
  ./scripts/local_setup.sh [options]

Options:
  --setup         Create Poetry env, install deps (--without aws), copy .env,
                  install pre-commit hooks, start Mongo + Qdrant
  --with-zenml    Also start local ZenML server (implies / pairs with --setup)
  --verify        Verify only (default)
  -h, --help      Show this help

Examples:
  ./scripts/local_setup.sh
  ./scripts/local_setup.sh --setup
  ./scripts/local_setup.sh --setup --with-zenml
EOF
}

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  printf "%sPASS%s  %s\n" "$C_GREEN" "$C_RESET" "$1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  FAILURES+=("$1")
  printf "%sFAIL%s  %s\n" "$C_RED" "$C_RESET" "$1"
}

warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  printf "%sWARN%s  %s\n" "$C_YELLOW" "$C_RESET" "$1"
}

info() {
  printf "%s%s%s\n" "$C_DIM" "$1" "$C_RESET"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

version_ge() {
  # version_ge A B  -> true if A >= B (dotted numeric)
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

find_python311() {
  if [[ -x "$PYENV_PYTHON" ]]; then
    echo "$PYENV_PYTHON"
    return 0
  fi
  if have_cmd pyenv && pyenv which python >/dev/null 2>&1; then
    local p
    p="$(pyenv which python 2>/dev/null || true)"
    if [[ -n "$p" ]] && "$p" -c "import sys; raise SystemExit(0 if sys.version_info[:2]==(3,11) else 1)" 2>/dev/null; then
      echo "$p"
      return 0
    fi
  fi
  if have_cmd python3.11; then
    echo "$(command -v python3.11)"
    return 0
  fi
  return 1
}

ensure_poetry_uses_311() {
  local py
  py="$(find_python311)" || {
    echo "Python 3.11 not found. Install with: pyenv install 3.11.8" >&2
    return 1
  }
  poetry env use "$py" >/dev/null
}

env_key_status() {
  # prints: missing | placeholder | set
  local key="$1"
  local file="$2"
  if [[ ! -f "$file" ]]; then
    echo "missing"
    return
  fi
  local line val
  line="$(grep -E "^${key}=" "$file" | head -n1 || true)"
  if [[ -z "$line" ]]; then
    echo "missing"
    return
  fi
  val="${line#*=}"
  val="${val%\"}"
  val="${val#\"}"
  val="$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "$val" || "$val" == "str" ]]; then
    echo "placeholder"
  else
    echo "set"
  fi
}

# ---------------- arg parse ----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup) DO_SETUP=1; shift ;;
    --with-zenml) WITH_ZENML=1; DO_SETUP=1; shift ;;
    --verify) DO_SETUP=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

printf "%sLLM Engineer's Handbook — local setup / verify%s\n" "$C_BOLD" "$C_RESET"
info "Repo: $ROOT_DIR"
echo

# ---------------- setup (optional) ----------------
if [[ "$DO_SETUP" -eq 1 ]]; then
  printf "%s== Setup ==%s\n" "$C_BOLD" "$C_RESET"

  if ! have_cmd poetry; then
    fail "Poetry is required for setup. Install Poetry 1.8.x first."
    exit 1
  fi

  info "Configuring Poetry to use Python ${REQUIRED_PYTHON_MAJOR_MINOR}..."
  if ensure_poetry_uses_311; then
    pass "Poetry env set to Python ${REQUIRED_PYTHON_MAJOR_MINOR}"
  else
    fail "Could not configure Poetry Python ${REQUIRED_PYTHON_MAJOR_MINOR}"
    exit 1
  fi

  info "Installing dependencies (poetry install --without aws)..."
  poetry install --without aws
  pass "Dependencies installed"

  info "Installing pre-commit hooks..."
  poetry run pre-commit install
  pass "pre-commit hooks installed"

  if [[ ! -f .env ]]; then
    cp .env.example .env
    pass "Created .env from .env.example"
    warn "Fill OPENAI_API_KEY, HUGGINGFACE_ACCESS_TOKEN, COMET_API_KEY in .env"
  else
    pass ".env already exists"
  fi

  if ! have_cmd docker; then
    fail "Docker is required to start Mongo/Qdrant"
    exit 1
  fi
  if ! docker info >/dev/null 2>&1; then
    fail "Docker daemon is not running. Start Docker Desktop, then re-run with --setup"
    exit 1
  fi

  info "Starting MongoDB + Qdrant (docker compose up -d)..."
  docker compose up -d
  pass "docker compose up -d completed"

  # Give Mongo a moment after first boot
  sleep 3

  if [[ "$WITH_ZENML" -eq 1 ]]; then
    info "Starting local ZenML server..."
    if [[ "$(uname -s)" == "Darwin" ]]; then
      export OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES
    fi
    # Best-effort: logout old local server, then login
    poetry run zenml logout --local >/dev/null 2>&1 || true
    if poetry run zenml login --local; then
      pass "ZenML local server started (dashboard usually http://localhost:8237)"
    else
      warn "ZenML local server failed to start (Mongo/Qdrant may still be fine)"
    fi
  fi

  echo
fi

# ---------------- verify ----------------
printf "%s== Verify ==%s\n" "$C_BOLD" "$C_RESET"

# Tools
if have_cmd git; then
  pass "Git installed ($(git --version | awk '{print $3}'))"
else
  fail "Git not found"
fi

if [[ -d "/Applications/Google Chrome.app" ]] || have_cmd google-chrome || have_cmd google-chrome-stable || have_cmd chromium; then
  pass "Chrome/Chromium available (needed for Selenium crawlers)"
else
  warn "Chrome/Chromium not found — Medium/LinkedIn crawlers may fail"
fi

PYTHON311=""
if PYTHON311="$(find_python311)"; then
  pass "Python 3.11 available ($("$PYTHON311" --version 2>&1) @ $PYTHON311)"
else
  fail "Python 3.11 not found (need 3.11.x; pyenv install 3.11.8 recommended)"
fi

if have_cmd poetry; then
  POETRY_VER="$(poetry --version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
  if [[ -n "$POETRY_VER" ]] && version_ge "$POETRY_VER" "1.8.0" && ! version_ge "$POETRY_VER" "2.0.0"; then
    pass "Poetry $POETRY_VER (1.8.x)"
  elif [[ -n "$POETRY_VER" ]]; then
    warn "Poetry $POETRY_VER found; project targets >=1.8.3 and <2.0"
  else
    pass "Poetry installed ($(poetry --version 2>/dev/null))"
  fi
else
  fail "Poetry not found (install 1.8.x)"
fi

if have_cmd docker; then
  if docker info >/dev/null 2>&1; then
    SERVER_VER="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
    CLIENT_VER="$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)"
    pass "Docker running (client ${CLIENT_VER:-?} / server ${SERVER_VER:-?})"
    if [[ -n "$SERVER_VER" ]] && ! version_ge "$SERVER_VER" "27.0.0"; then
      warn "Docker server $SERVER_VER < 27 — README recommends >=27.1.1"
    fi
  else
    fail "Docker installed but daemon not running / unable to start"
  fi
else
  fail "Docker not found"
fi

if docker compose version >/dev/null 2>&1; then
  pass "Docker Compose available ($(docker compose version 2>/dev/null | head -n1))"
elif have_cmd docker-compose; then
  pass "docker-compose available ($(docker-compose --version 2>/dev/null))"
else
  fail "Docker Compose not found"
fi

# Poetry project env + imports
if have_cmd poetry; then
  if ensure_poetry_uses_311 >/dev/null 2>&1; then
    ENV_PY_VER="$(poetry run python --version 2>/dev/null || true)"
    if echo "$ENV_PY_VER" | grep -q "3.11"; then
      pass "Poetry env Python OK ($ENV_PY_VER)"
    else
      fail "Poetry env is not Python 3.11 ($ENV_PY_VER)"
    fi

    if poetry run python -c "import zenml, pymongo, qdrant_client, fastapi, langchain, torch" >/dev/null 2>&1; then
      ZVER="$(poetry run python -c 'import zenml; print(zenml.__version__)' 2>/dev/null || echo '?')"
      pass "Core Python packages import OK (zenml $ZVER)"
    else
      fail "Core packages missing — run: ./scripts/local_setup.sh --setup"
    fi

    if [[ -f .git/hooks/pre-commit ]]; then
      pass "pre-commit hook installed"
    else
      warn "pre-commit hook missing — run: poetry run pre-commit install"
    fi
  else
    fail "Could not activate Poetry env with Python 3.11"
  fi
fi

# .env
if [[ -f .env ]]; then
  pass ".env exists"
  for key in "${REQUIRED_API_KEYS[@]}"; do
    status="$(env_key_status "$key" .env)"
    case "$status" in
      set) pass "$key is set" ;;
      placeholder) fail "$key is still a placeholder (edit .env)" ;;
      missing) fail "$key missing from .env" ;;
    esac
  done
  if grep -qE '^USE_QDRANT_CLOUD=false' .env 2>/dev/null; then
    pass "USE_QDRANT_CLOUD=false (local Qdrant)"
  else
    warn "USE_QDRANT_CLOUD is not false — cloud Qdrant may be expected"
  fi
else
  fail ".env missing — run: ./scripts/local_setup.sh --setup  (or cp .env.example .env)"
fi

# Infra containers
MONGO_NAME="llm_engineering_mongo"
QDRANT_NAME="llm_engineering_qdrant"

if docker info >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' | grep -qx "$MONGO_NAME"; then
    if docker exec "$MONGO_NAME" mongosh --quiet -u llm_engineering -p llm_engineering \
      --authenticationDatabase admin --eval 'db.runCommand({ ping: 1 })' >/dev/null 2>&1; then
      pass "MongoDB healthy ($MONGO_NAME on :27017)"
    else
      fail "MongoDB container up but ping failed"
    fi
  else
    fail "MongoDB container not running — run: ./scripts/local_setup.sh --setup"
  fi

  if docker ps --format '{{.Names}}' | grep -qx "$QDRANT_NAME"; then
    if curl -fsS http://127.0.0.1:6333/readyz >/dev/null 2>&1; then
      pass "Qdrant healthy ($QDRANT_NAME on :6333)"
    else
      fail "Qdrant container up but /readyz failed"
    fi
  else
    fail "Qdrant container not running — run: ./scripts/local_setup.sh --setup"
  fi
fi

# ZenML (informational unless --with-zenml / server expected)
if have_cmd poetry && poetry run python -c "import zenml" >/dev/null 2>&1; then
  if curl -fsS http://127.0.0.1:8237 >/dev/null 2>&1; then
    pass "ZenML dashboard reachable (http://localhost:8237)"
  else
    warn "ZenML local server not running (optional). Start with: ./scripts/local_setup.sh --setup --with-zenml"
  fi
fi

# ---------------- summary ----------------
echo
printf "%s== Summary ==%s\n" "$C_BOLD" "$C_RESET"
printf "  passed: %s%d%s   failed: %s%d%s   warnings: %s%d%s\n" \
  "$C_GREEN" "$PASS_COUNT" "$C_RESET" \
  "$C_RED" "$FAIL_COUNT" "$C_RESET" \
  "$C_YELLOW" "$WARN_COUNT" "$C_RESET"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  echo
  echo "Failed checks:"
  for item in "${FAILURES[@]}"; do
    echo "  - $item"
  done
  echo
  info "Quick fix tips:"
  info "  ./scripts/local_setup.sh --setup"
  info "  Edit .env with real API keys"
  info "  Start Docker Desktop if the daemon is down"
  exit 1
fi

echo
pass "Local environment looks ready for Mongo/Qdrant + local data/RAG work."
info "Training / full LLM inference still need AWS SageMaker later."
exit 0
