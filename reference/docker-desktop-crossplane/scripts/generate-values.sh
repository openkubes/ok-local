#!/usr/bin/env bash
set -euo pipefail

enable_rmf_sim="${1:-false}"
case "${enable_rmf_sim}" in
  true|false) ;;
  *)
    echo "Usage: $0 [true|false]" >&2
    exit 2
    ;;
esac

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
preflight_dir="$(cd "${script_dir}/.." && pwd)"
state_dir="${preflight_dir}/.state"
credentials_file="${state_dir}/credentials.env"
values_file="${state_dir}/rmf-values.yaml"
template_file="${preflight_dir}/rmf-values.yaml.template"

mkdir -p "${state_dir}"
chmod 0700 "${state_dir}"

if [[ ! -f "${credentials_file}" ]]; then
  umask 077
  rmf_db_password="$(openssl rand -hex 24)"
  rmf_admin_password="$(openssl rand -hex 24)"
  keycloak_admin_password="$(openssl rand -hex 24)"
  keycloak_db_password="$(openssl rand -hex 24)"

  {
    printf 'RMF_DB_PASSWORD=%s\n' "${rmf_db_password}"
    printf 'RMF_ADMIN_PASSWORD=%s\n' "${rmf_admin_password}"
    printf 'KEYCLOAK_ADMIN_PASSWORD=%s\n' "${keycloak_admin_password}"
    printf 'KEYCLOAK_DB_PASSWORD=%s\n' "${keycloak_db_password}"
  } > "${credentials_file}"
fi

# The generated file contains only hex values produced above, so sourcing it
# cannot introduce shell syntax from user input.
# shellcheck disable=SC1090
source "${credentials_file}"

sed \
  -e "s/__ENABLE_RMF_SIM__/${enable_rmf_sim}/g" \
  -e "s/__RMF_DB_PASSWORD__/${RMF_DB_PASSWORD}/g" \
  -e "s/__RMF_ADMIN_PASSWORD__/${RMF_ADMIN_PASSWORD}/g" \
  -e "s/__KEYCLOAK_ADMIN_PASSWORD__/${KEYCLOAK_ADMIN_PASSWORD}/g" \
  -e "s/__KEYCLOAK_DB_PASSWORD__/${KEYCLOAK_DB_PASSWORD}/g" \
  "${template_file}" > "${values_file}"

chmod 0600 "${credentials_file}" "${values_file}"
echo "Generated ${values_file} (ENABLE_RMF_SIM=${enable_rmf_sim})."

