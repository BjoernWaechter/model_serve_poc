#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$ROOT_DIR/mlflow/.venv"
ENV_FILE="$ROOT_DIR/.env"

if [[ ! -x "$VENV_DIR/bin/jupyter-lab" ]]; then
    echo "jupyter-lab not found in $VENV_DIR/bin" >&2
    exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
    set -o allexport
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +o allexport
else
    echo "warning: $ENV_FILE not found, continuing without it" >&2
fi

cd "$ROOT_DIR"
exec "$VENV_DIR/bin/jupyter-lab" "$@"
