#!/bin/bash
# Parse the generated dotenv file as data without executing shell syntax.

load_privacy_env() {
  local env_file=$1 line key value
  [ -f "$env_file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case "$line" in
      ""|\#*) continue ;;
      *=*) ;;
      *) echo "Invalid line in $env_file" >&2; return 1 ;;
    esac

    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      DOMAIN|SERVER_IP|ACME_EMAIL|COMPOSE_PROFILES|COMPOSE_PROJECT_NAME|\
      DATA_DIR|MEDIA_DIR|PAPERLESS_CONSUME_DIR|PAPERLESS_EXPORT_DIR|\
      PAPERLESS_DB_PASSWORD|PAPERLESS_DB_USER|PAPERLESS_ADMIN_USER|\
      PAPERLESS_ADMIN_PASSWORD|PAPERLESS_SECRET_KEY|PAPERLESS_URL|\
      JELLYFIN_URL|VAULTWARDEN_ADMIN_TOKEN|VAULTWARDEN_URL|\
      VAULTWARDEN_SIGNUPS|TAILSCALE_AUTHKEY|BACKUP_DIR|BACKUP_CRON) ;;
      *) echo "Unsupported key in $env_file: $key" >&2; return 1 ;;
    esac

    printf -v "$key" '%s' "$value"
    export "${key?}"
  done < "$env_file"
}
