#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
source "$ENGINE_DIR/lib/units.sh"

# --- CPU ---
assert_eq "0.2"  "$(k8s_cpu_to_docker 200m)"   "200m → 0.2"
assert_eq "1.5"  "$(k8s_cpu_to_docker 1500m)"  "1500m → 1.5"
assert_eq "0.05" "$(k8s_cpu_to_docker 50m)"    "50m → 0.05"
assert_eq "1"    "$(k8s_cpu_to_docker 1)"      "1 → 1 (déjà en cœurs)"
assert_eq "0.5"  "$(k8s_cpu_to_docker 0.5)"    "0.5 → 0.5 (déjà décimal)"
assert_eq "2"    "$(k8s_cpu_to_docker 2000m)"  "2000m → 2"
assert_exit_code 1 "cpu vide rejeté" -- k8s_cpu_to_docker ""
assert_exit_code 1 "cpu non numérique rejeté" -- k8s_cpu_to_docker "beaucoup"

# --- Mémoire ---
assert_eq "128m" "$(k8s_mem_to_docker 128Mi)" "128Mi → 128m"
assert_eq "1024m" "$(k8s_mem_to_docker 1Gi)"  "1Gi → 1024m"
assert_eq "64m"  "$(k8s_mem_to_docker 65536Ki)" "65536Ki → 64m"
assert_eq "512m" "$(k8s_mem_to_docker 512m)"  "512m (déjà Docker) → inchangé"
assert_eq "244m" "$(k8s_mem_to_docker 256M)"  "256M décimal → 244m (256 Mo = 244 MiB)"
assert_exit_code 1 "mémoire vide rejetée" -- k8s_mem_to_docker ""
assert_exit_code 1 "mémoire non numérique rejetée" -- k8s_mem_to_docker "plein"

finish
