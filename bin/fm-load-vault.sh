#!/usr/bin/env bash
# fm-load-vault.sh — Decrypt .env.vault and export secrets as environment variables
#
# Usage:
#   source bin/fm-load-vault.sh          # loads into current shell
#   eval "$(bin/fm-load-vault.sh)"       # same effect
#   bin/fm-load-vault.sh --check         # verify vault is decryptable, print key names
#
# Requires: age (brew install age)
# Key location: ~/.age/firstmate-photo-key.txt
#
# Security model:
# - .env.vault is age-encrypted, safe to commit
# - Decryption happens in a tmpfile that is shredded on exit
# - Secrets are exported as env vars, never printed to stdout
# - Crewmates receive env vars via --env-file, never raw vault content

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="$(dirname "$SCRIPT_DIR")"
VAULT_FILE="$HOME_DIR/.env.vault"
KEY_FILE="$HOME_DIR/.secrets/firstmate-photo-key.txt"
FALLBACK_KEY="$HOME/.age/firstmate-photo-key.txt"

# Resolve the key file
if [[ -f "$KEY_FILE" ]]; then
    AGE_KEY="$KEY_FILE"
elif [[ -f "$FALLBACK_KEY" ]]; then
    AGE_KEY="$FALLBACK_KEY"
else
    echo "ERROR: age key not found at $KEY_FILE or $FALLBACK_KEY" >&2
    return 1 2>/dev/null || exit 1
fi

if [[ ! -f "$VAULT_FILE" ]]; then
    echo "ERROR: vault not found at $VAULT_FILE" >&2
    return 1 2>/dev/null || exit 1
fi

# --check mode: just verify decryptability and print key names
if [[ "${1:-}" == "--check" ]]; then
    echo "Vault: $VAULT_FILE"
    echo "Key:   $AGE_KEY"
    echo "---"
    age -d -i "$AGE_KEY" "$VAULT_FILE" 2>/dev/null | grep -E '^[A-Z_]+=' | sed 's/=.*/=***/'
    echo "---"
    echo "Vault OK: $(age -d -i "$AGE_KEY" "$VAULT_FILE" 2>/dev/null | grep -c '^[A-Z_]+') secrets"
    return 0 2>/dev/null || exit 0
fi

# Decrypt to tmpfile, source it, then shred
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"; if command -v shred &>/dev/null; then shred -u "$TMPFILE" 2>/dev/null; fi' EXIT

age -d -i "$AGE_KEY" "$VAULT_FILE" > "$TMPFILE"

# Export all KEY=VALUE lines (skip comments and blanks)
# Use 'export "$line"' directly to preserve special characters like # in values
while IFS= read -r line; do
    if [[ "$line" =~ ^[A-Z_]+=.+ ]]; then
        export "$line"
    fi
done < "$TMPFILE"
