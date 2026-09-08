#!/usr/bin/env bash
# engine/lib/units.sh — conversion des unités Kubernetes vers les unités Docker.
#
# Kubernetes exprime le CPU en millicores ("200m") et la mémoire en puissances
# de 2 ("128Mi"). Docker Compose veut des cœurs décimaux ("0.2") et un suffixe
# binaire minuscule ("128m" = 128 MiB).
#
# Les deux fonctions impriment le résultat sur stdout et renvoient 0 ; en cas
# d'entrée invalide elles n'impriment rien et renvoient 1 (à l'appelant de
# décider s'il applique un défaut ou s'il échoue).

# k8s_cpu_to_docker "200m" → "0.2"
k8s_cpu_to_docker() {
  local v="${1:-}"
  [[ -n "$v" ]] || return 1

  if [[ "$v" =~ ^([0-9]+)m$ ]]; then
    # Millicores → cœurs, avec 3 décimales puis nettoyage des zéros inutiles.
    local milli="${BASH_REMATCH[1]}"
    local out
    out=$(LC_ALL=C awk -v m="$milli" 'BEGIN { printf "%.3f", m / 1000 }')
    # Nettoyage des zéros de queue : 0.200 → 0.2, 2.000 → 2
    out=$(LC_ALL=C printf '%s' "$out" | LC_ALL=C sed -e 's/0*$//' -e 's/\.$//')
    printf '%s' "$out"
    return 0
  fi

  if [[ "$v" =~ ^[0-9]+$ ]] || [[ "$v" =~ ^[0-9]*\.[0-9]+$ ]]; then
    printf '%s' "$v"
    return 0
  fi

  return 1
}

# k8s_mem_to_docker "128Mi" → "128m"
k8s_mem_to_docker() {
  local v="${1:-}"
  [[ -n "$v" ]] || return 1

  local num unit mib
  if [[ "$v" =~ ^([0-9]+)(Ki|Mi|Gi|K|M|G|k|m|g)?$ ]]; then
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]:-}"
  else
    return 1
  fi

  case "$unit" in
    Ki)      mib=$(( num / 1024 )) ;;
    Mi|m|"") mib="$num" ;;
    Gi|g)    mib=$(( num * 1024 )) ;;
    K|k)     mib=$(( num * 1000 / 1048576 )) ;;
    M)       mib=$(( num * 1000000 / 1048576 )) ;;
    G)       mib=$(( num * 1000000000 / 1048576 )) ;;
    *)       return 1 ;;
  esac

  (( mib < 6 )) && mib=6   # Docker refuse une limite mémoire sous 6 MiB
  printf '%sm' "$mib"
}
