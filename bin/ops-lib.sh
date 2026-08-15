#!/usr/bin/env bash
# ops-lib.sh — validation partagée par tous les wrappers claude-ops.
#
# Ce fichier est la frontière de sécurité du projet. Tout ce qui s'y trouve
# s'exécute en root et ne doit RIEN accepter qui n'ait été validé explicitement.
#
# Règle absolue : aucune donnée venant de l'appelant n'atteint un shell.
# Pas de eval, pas de substitution non quotée, pas de construction de commande
# par concaténation de chaînes.

set -euo pipefail
IFS=$'\n\t'

# PATH figé : l'appelant ne doit pas pouvoir nous faire exécuter son propre
# binaire en manipulant son environnement. Sans ça, un PATH hostile transforme
# n'importe quel appel à `docker` en exécution de code arbitraire — en root.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly OPS_CONF_DIR="${OPS_CONF_DIR:-/etc/claude-ops}"
readonly OPS_SERVICES_FILE="${OPS_CONF_DIR}/services.allow"
readonly OPS_MAX_LINES=2000

die() {
  printf 'ops: %s\n' "$1" >&2
  exit 1
}

# --- Validation du nom de service -------------------------------------------
#
# Deux barrières successives, volontairement redondantes :
#   1. une forme syntaxique stricte (rejette tout métacaractère shell)
#   2. une appartenance à l'allowlist (rejette tout ce qui n'est pas prévu)
#
# La barrière 1 seule ne suffit pas : un nom syntaxiquement valide peut désigner
# un conteneur critique. La barrière 2 seule ne suffit pas non plus : elle
# protège mal si le nom transite ensuite par un contexte mal quoté.

ops_validate_name() {
  local name="${1-}"

  [[ -n "$name" ]] || die "nom de service manquant"
  (( ${#name} <= 64 )) || die "nom de service trop long"

  # Liste blanche de caractères. Tout le reste est refusé, y compris
  # ; | & $ ` ( ) < > espace, retour ligne, et les séquences ../
  [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]] \
    || die "nom de service invalide : caractères non autorisés"

  # Refus explicite du point-point, qui passerait la regex ci-dessus
  [[ "$name" != *..* ]] || die "nom de service invalide"

  ops_in_allowlist "$name" || die "service non autorisé : ${name}"

  printf '%s' "$name"
}

# L'allowlist est un fichier root-owned. Les lignes vides et les commentaires
# sont ignorés. La comparaison est stricte : pas de glob, pas de préfixe.
ops_in_allowlist() {
  local candidate="$1" line
  [[ -r "$OPS_SERVICES_FILE" ]] || die "allowlist introuvable : ${OPS_SERVICES_FILE}"

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] || continue
    [[ "$line" == "$candidate" ]] && return 0
  done < "$OPS_SERVICES_FILE"

  return 1
}

# --- Validation d'un entier borné -------------------------------------------

ops_validate_int() {
  local value="${1-}" min="$2" max="$3"

  [[ "$value" =~ ^[0-9]+$ ]] || die "valeur numérique attendue"
  # Retire les zéros de tête pour éviter l'interprétation en octal
  value=$((10#$value))
  (( value >= min && value <= max )) || die "valeur hors bornes (${min}-${max})"

  printf '%s' "$value"
}

# --- Redaction des secrets ---------------------------------------------------
#
# Couvre la menace M3 du modèle de menace : un secret lu pour diagnostiquer
# ne doit pas se retrouver dans un transcript de session.
#
# Ce filtre est une réduction de risque, PAS une garantie. Il attrape les
# formes courantes ; il ne peut pas reconnaître un secret arbitraire. Ne jamais
# considérer qu'une sortie filtrée est sûre à publier telle quelle.

ops_redact() {
  sed -E \
    -e 's/(password|passwd|pwd|secret|token|api[_-]?key|auth|bearer|credential)([[:space:]]*[:=][[:space:]]*|["'"'"']?[[:space:]]*:[[:space:]]*["'"'"']?)[^[:space:],;"'"'"']{4,}/\1\2[REDACTED]/gI' \
    -e 's#(postgres|postgresql|mysql|mongodb|redis|amqp)://[^:]+:[^@]+@#\1://[REDACTED]@#gI' \
    -e 's/\b(eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})\b/[REDACTED_JWT]/g' \
    -e 's/\b(AKIA[0-9A-Z]{16})\b/[REDACTED_AWS_KEY]/g' \
    -e 's/\b(sk-[A-Za-z0-9_-]{20,})\b/[REDACTED_API_KEY]/g' \
    -e 's/\b(gh[pousr]_[A-Za-z0-9]{20,})\b/[REDACTED_GH_TOKEN]/g' \
    -e 's/-----BEGIN[A-Z ]*PRIVATE KEY-----/[REDACTED_PRIVATE_KEY]/g'
}

# --- Garde-fou d'intégrité ---------------------------------------------------
#
# Si les wrappers ou l'allowlist deviennent modifiables par un utilisateur non
# privilégié, toute la construction s'effondre : l'agent réécrit le script qu'il
# a le droit d'exécuter en root. On refuse de tourner dans ce cas.

ops_assert_integrity() {
  local target
  for target in "$OPS_SERVICES_FILE" "${BASH_SOURCE[0]}"; do
    [[ -e "$target" ]] || die "fichier requis absent : ${target}"

    local owner perms
    owner=$(stat -c '%U' "$target")
    perms=$(stat -c '%a' "$target")

    [[ "$owner" == "root" ]] || die "SÉCURITÉ : ${target} n'appartient pas à root"
    # Le dernier chiffre (autres) et celui du groupe ne doivent pas porter le bit d'écriture
    [[ "${perms: -1}" =~ [0-5] ]] || die "SÉCURITÉ : ${target} est modifiable par tous"
    [[ "${perms: -2:1}" =~ [0-5] ]] || die "SÉCURITÉ : ${target} est modifiable par son groupe"
  done
}
