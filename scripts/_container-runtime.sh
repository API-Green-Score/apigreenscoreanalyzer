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
    echo "❌ Aucun container runtime trouvé (ni docker ni podman)." >&2
    echo "   Installez Manager de container comme (Docker, Podman, Rancher Desktop ... ou votre manager de container preferé),  et réessayez." >&2
    exit 1
  fi

  CONTAINER_COMPOSE="$CONTAINER_RT compose"
  echo "🐳 Container runtime détecté : $CONTAINER_RT"
}

detect_container_runtime

