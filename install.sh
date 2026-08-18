#!/usr/bin/env bash
# install.sh — installe claude-ops sur le serveur. À lancer en root.
#
#   sudo ./install.sh --pubkey "ssh-ed25519 AAAA... claude-ops"
#
# Idempotent : relançable sans risque, ne duplique rien.

set -euo pipefail
IFS=$'\n\t'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

readonly OPS_USER=claude-ops
readonly BIN_DIR=/usr/local/bin
readonly LIB_DIR=/usr/local/lib/claude-ops
readonly CONF_DIR=/etc/claude-ops
readonly LOG_FILE=/var/log/claude-ops.log
readonly SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PUBKEY=""

die()  { printf '\033[31merreur:\033[0m %s\n' "$1" >&2; exit 1; }
step() { printf '\n\033[1m→ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }

# --- Garde-fous --------------------------------------------------------------

(( EUID == 0 )) || die "à lancer en root : sudo ./install.sh --pubkey \"...\""

while (( $# )); do
  case "$1" in
    --pubkey) PUBKEY="${2-}"; shift 2 ;;
    *) die "argument inconnu : $1" ;;
  esac
done

[[ -n "$PUBKEY" ]] || die "--pubkey est obligatoire"
[[ "$PUBKEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)[[:space:]] ]] \
  || die "la clé publique ne ressemble pas à une clé SSH valide"

command -v docker >/dev/null || die "docker introuvable"
command -v visudo >/dev/null || die "visudo introuvable"

for f in bin/ops-lib.sh bin/ops-status bin/ops-logs bin/ops-inspect sudoers.d/claude-ops; do
  [[ -f "${SRC_DIR}/${f}" ]] || die "fichier source manquant : ${f}"
done

# --- 1. Utilisateur dédié ----------------------------------------------------
# --system      : uid bas, pas un compte humain
# --shell nologin serait trop restrictif : SSH a besoin d'un shell pour
#                 exécuter une commande. On garde bash, l'enfermement vient
#                 des droits, pas du shell.
# Aucun mot de passe n'est défini : la connexion par mot de passe est
# impossible, seule la clé fonctionne.

step "Utilisateur ${OPS_USER}"
if id "$OPS_USER" &>/dev/null; then
  ok "existe déjà"
else
  useradd --system --create-home --shell /bin/bash "$OPS_USER"
  ok "créé"
fi

# Vérification explicite : l'agent ne doit surtout PAS être dans le groupe
# docker (équivaut à root) ni dans le groupe sudo.
for forbidden in docker sudo adm; do
  if id -nG "$OPS_USER" | tr ' ' '\n' | grep -qx "$forbidden"; then
    die "SÉCURITÉ : ${OPS_USER} est dans le groupe '${forbidden}' — le retirer avant de continuer"
  fi
done
ok "hors des groupes docker / sudo / adm"

passwd --lock "$OPS_USER" >/dev/null
ok "connexion par mot de passe désactivée"

# --- 2. Bibliothèque et wrappers --------------------------------------------
# root:root, non modifiables par quiconque d'autre : c'est la condition que
# ops_assert_integrity() vérifie à chaque exécution.

step "Scripts"
install -d -m 0755 -o root -g root "$LIB_DIR"
install -m 0644 -o root -g root "${SRC_DIR}/bin/ops-lib.sh" "${LIB_DIR}/ops-lib.sh"
ok "${LIB_DIR}/ops-lib.sh"

for script in ops-status ops-logs ops-inspect; do
  install -m 0755 -o root -g root "${SRC_DIR}/bin/${script}" "${BIN_DIR}/${script}"
  ok "${BIN_DIR}/${script}"
done

# --- 3. Allowlist ------------------------------------------------------------

step "Allowlist des services"
install -d -m 0755 -o root -g root "$CONF_DIR"

if [[ -f "${CONF_DIR}/services.allow" ]]; then
  ok "conservée (fichier déjà présent)"
else
  cat > "${CONF_DIR}/services.allow" <<'EOF'
# Conteneurs que l'agent est autorisé à consulter.
# Un nom par ligne. Comparaison stricte : pas de joker, pas de préfixe.
#
# N'ajouter ici QUE des services dont les logs peuvent être lus sans risque.
# Éviter les bases de données et les reverse-proxies : leurs logs contiennent
# fréquemment des identifiants, des jetons ou des données personnelles.
#
# Lister les conteneurs disponibles :  docker ps --format '{{.Names}}'

EOF
  chmod 0644 "${CONF_DIR}/services.allow"
  chown root:root "${CONF_DIR}/services.allow"
  ok "créée (vide — à remplir, voir la fin)"
fi

# --- 4. Règle sudoers --------------------------------------------------------
# Validée AVANT installation : une erreur de syntaxe dans /etc/sudoers.d/
# peut casser sudo pour tous les utilisateurs de la machine.

step "Règle sudoers"
tmp_sudoers=$(mktemp)
trap 'rm -f "$tmp_sudoers"' EXIT
install -m 0440 -o root -g root "${SRC_DIR}/sudoers.d/claude-ops" "$tmp_sudoers"

visudo -c -q -f "$tmp_sudoers" || die "syntaxe sudoers invalide — rien n'a été installé"
ok "syntaxe validée"

install -m 0440 -o root -g root "$tmp_sudoers" /etc/sudoers.d/claude-ops
ok "/etc/sudoers.d/claude-ops"

touch "$LOG_FILE"
chmod 0600 "$LOG_FILE"
chown root:root "$LOG_FILE"
ok "journal ${LOG_FILE}"

# --- 5. Clé SSH --------------------------------------------------------------
# Options de restriction :
#   restrict  active toutes les restrictions (pas de forwarding de port,
#             d'agent, de X11, pas de pty, pas de ~/.ssh/rc)
#   pty       réactivé : certaines commandes en ont besoin pour un affichage
#             correct. À retirer si tu veux verrouiller davantage.

step "Clé SSH de l'agent"
ssh_dir="/home/${OPS_USER}/.ssh"
auth_file="${ssh_dir}/authorized_keys"

install -d -m 0700 -o "$OPS_USER" -g "$OPS_USER" "$ssh_dir"
touch "$auth_file"

key_body=$(awk '{print $2}' <<<"$PUBKEY")
if grep -qF "$key_body" "$auth_file" 2>/dev/null; then
  ok "clé déjà autorisée"
else
  printf 'restrict,pty %s\n' "$PUBKEY" >> "$auth_file"
  ok "clé ajoutée"
fi

chmod 0600 "$auth_file"
chown "$OPS_USER:$OPS_USER" "$auth_file"

# --- 6. Vérification ---------------------------------------------------------

step "Vérification"
sudo -u "$OPS_USER" sudo -n -l 2>/dev/null | grep -q ops-status \
  && ok "sudo NOPASSWD opérationnel" \
  || die "sudo ne reconnaît pas la règle — vérifier /etc/sudoers.d/claude-ops"

if sudo -u "$OPS_USER" docker ps &>/dev/null; then
  die "SÉCURITÉ : ${OPS_USER} accède à docker en direct — il ne devrait pas"
fi
ok "accès docker direct correctement refusé"

cat <<EOF

$(printf '\033[1m─────────────────────────────────────────\033[0m')
Installation terminée.

Étape suivante — remplir l'allowlist, sinon ops-logs ne pourra rien lire :

  docker ps --format '{{.Names}}'
  sudoedit ${CONF_DIR}/services.allow

Puis tester depuis ton poste :

  ssh claude-ops@<serveur> sudo ops-status

EOF
