#!/usr/bin/env bash
###############################################################################
#  Détection automatique du container runtime (Docker ou Podman)
#  Usage: source scripts/_container-runtime.sh
#
#  Après sourcing, les variables suivantes sont disponibles :
#    CONTAINER_RT        — "podman" ou "docker"
#    CONTAINER_COMPOSE   — "podman compose" ou "docker compose"
###############################################################################

detect_container_runtime() {
  if command -v podman &>/dev/null && podman info &>/dev/null; then
    CONTAINER_RT="podman"
  elif command -v docker &>/dev/null && docker info &>/dev/null; then
    CONTAINER_RT="docker"
  else
    # Don't fail when sourced — only the consumers that *need* a runtime
    # (creedengo) should fail. Pure HTTP API analysis works without Docker.
    CONTAINER_RT=""
    CONTAINER_COMPOSE=""
    if [ "${CONTAINER_RT_REQUIRED:-0}" = "1" ]; then
      echo "❌ Aucun container runtime trouvé (ni docker ni podman)." >&2
      echo "   Installez un manager de container (Docker, Podman, Rancher Desktop, …) et réessayez." >&2
      exit 1
    fi
    echo "ℹ️  Aucun container runtime détecté — les fonctionnalités Creedengo seront désactivées." >&2
    return 0
  fi

  CONTAINER_COMPOSE="$CONTAINER_RT compose"
  echo "🐳 Container runtime détecté : $CONTAINER_RT"
}

detect_container_runtime

