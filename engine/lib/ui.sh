#!/usr/bin/env bash
# engine/lib/ui.sh — messages de progression de l'engine.
#
# TOUT part sur stderr : stdout est réservé à la ligne de résultat JSON.
# Il n'y a plus de prompt : l'engine est non-interactif par construction, il
# est appelé par un worker sans TTY. Toute décision qui était un ui_confirm est
# devenue une clé d'env.json (cf. lib/config.sh) ou un échec fatal.
#
# gum a disparu avec les prompts. Les couleurs restent, elles ne coûtent rien
# et le worker les nettoie (ANSI strip) avant affichage.

readonly C_RESET='\033[0m'
readonly C_BOLD='\033[1m'
readonly C_DIM='\033[2m'
readonly C_NAVY='\033[38;5;25m'
readonly C_GREEN='\033[38;5;35m'
readonly C_YELLOW='\033[38;5;214m'
readonly C_RED='\033[38;5;160m'
readonly C_BLUE='\033[38;5;39m'

ui_step() { printf '%b\n' "\n${C_NAVY}${C_BOLD}━━━ $* ━━━${C_RESET}" >&2; }
ui_info() { printf '%b\n' "${C_BLUE}ℹ${C_RESET}  $*" >&2; }
ui_ok()   { printf '%b\n' "${C_GREEN}✓${C_RESET}  $*" >&2; }
ui_warn() { printf '%b\n' "${C_YELLOW}⚠${C_RESET}  $*" >&2; }
ui_err()  { printf '%b\n' "${C_RED}✗${C_RESET}  $*" >&2; }
ui_skip() { printf '%b\n' "${C_DIM}↷  $* (sauté)${C_RESET}" >&2; }
