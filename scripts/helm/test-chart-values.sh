#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_repo_root() {
  if git -C "${SCRIPT_DIR}" rev-parse --show-toplevel >/dev/null 2>&1; then
    git -C "${SCRIPT_DIR}" rev-parse --show-toplevel
    return
  fi

  cd "${SCRIPT_DIR}/../.." && pwd
}

REPO_ROOT="$(resolve_repo_root)"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] <module-name|chart-path> [-- <helm-template-args>]

Tests a Helm chart with its values by running helm lint and helm template.

The chart can be passed as either:
  - a module name under applications/   e.g. secrets-provider-aws
  - a chart path                        e.g. applications/secrets-provider-aws

By default, the script uses <chart-dir>/values.yaml when it exists.

Options:
  -f, --values PATH           Values file to pass to Helm. Can be repeated.
                              If omitted, defaults to <chart-dir>/values.yaml.
  -n, --namespace NAMESPACE   Namespace for helm template. Defaults to default.
  -r, --release NAME          Release name for helm template. Defaults to the
                              chart directory name.
  -o, --output PATH           Write rendered manifests to PATH instead of stdout.
  --skip-dependencies         Skip helm dependency build. Use this for offline
                              testing when dependencies are already vendored.
  -h, --help                  Show this help.

Examples:
  $(basename "$0") secrets-provider-aws --namespace kube-system
  $(basename "$0") applications/secrets-provider-driver -n kube-system
  $(basename "$0") metrics-server -f applications/metrics-server/values.yaml -o /tmp/metrics-server.yaml
  $(basename "$0") keycloak -- --set image.tag=test

EOF
}

error() {
  echo "ERROR: $*" >&2
  exit 1
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    error "Required command not found: ${command_name}"
  fi
}

require_value() {
  local option_name="$1"
  local option_value="${2:-}"

  if [[ -z "${option_value}" ]]; then
    error "${option_name} requires a value."
  fi
}

absolute_path() {
  local path="$1"
  local dir
  local base

  dir="$(dirname "${path}")"
  base="$(basename "${path}")"

  if [[ ! -d "${dir}" ]]; then
    error "Directory not found for path: ${path}"
  fi

  dir="$(cd "${dir}" && pwd)"
  echo "${dir}/${base}"
}

resolve_chart_dir() {
  local chart_ref="$1"
  local candidate

  if [[ -d "${chart_ref}" ]]; then
    absolute_path "${chart_ref}"
    return
  fi

  candidate="${REPO_ROOT}/applications/${chart_ref}"
  if [[ -d "${candidate}" ]]; then
    absolute_path "${candidate}"
    return
  fi

  error "Chart not found: ${chart_ref}. Pass an existing chart path or a module name under applications/."
}

chart_has_dependencies() {
  local chart_yaml="$1"

  grep -Eq '^dependencies:[[:space:]]*$' "${chart_yaml}"
}

copy_chart_to_tmp() {
  local source_chart_dir="$1"
  local tmp_root="$2"
  local chart_name
  local tmp_chart_dir

  chart_name="$(basename "${source_chart_dir}")"
  tmp_chart_dir="${tmp_root}/${chart_name}"

  mkdir -p "${tmp_chart_dir}"
  tar \
    --exclude '.git' \
    -C "${source_chart_dir}" \
    -cf - . | tar -C "${tmp_chart_dir}" -xf -

  echo "${tmp_chart_dir}"
}

CHART_REF=""
NAMESPACE="default"
RELEASE_NAME=""
OUTPUT_FILE=""
SKIP_DEPENDENCIES="false"
VALUES_FILES=()
HELM_TEMPLATE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--values)
      require_value "$1" "${2:-}"
      VALUES_FILES+=("$2")
      shift 2
      ;;
    --values=*)
      VALUES_FILES+=("${1#*=}")
      shift
      ;;
    -n|--namespace)
      require_value "$1" "${2:-}"
      NAMESPACE="$2"
      shift 2
      ;;
    --namespace=*)
      NAMESPACE="${1#*=}"
      shift
      ;;
    -r|--release)
      require_value "$1" "${2:-}"
      RELEASE_NAME="$2"
      shift 2
      ;;
    --release=*)
      RELEASE_NAME="${1#*=}"
      shift
      ;;
    -o|--output)
      require_value "$1" "${2:-}"
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --output=*)
      OUTPUT_FILE="${1#*=}"
      shift
      ;;
    --skip-dependencies)
      SKIP_DEPENDENCIES="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      HELM_TEMPLATE_ARGS+=("$@")
      break
      ;;
    -* )
      echo "ERROR: Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "${CHART_REF}" ]]; then
        error "Only one chart/module argument can be provided. Unexpected argument: $1"
      fi
      CHART_REF="$1"
      shift
      ;;
  esac
done

if [[ -z "${CHART_REF}" ]]; then
  usage
  error "A module name or chart path is required."
fi

require_command helm
require_command tar

CHART_DIR="$(resolve_chart_dir "${CHART_REF}")"
CHART_YAML="${CHART_DIR}/Chart.yaml"

if [[ ! -f "${CHART_YAML}" ]]; then
  error "Chart.yaml not found in chart directory: ${CHART_DIR}"
fi

if [[ -z "${RELEASE_NAME}" ]]; then
  RELEASE_NAME="$(basename "${CHART_DIR}")"
fi

if [[ ${#VALUES_FILES[@]} -eq 0 && -f "${CHART_DIR}/values.yaml" ]]; then
  VALUES_FILES+=("${CHART_DIR}/values.yaml")
fi

VALUES_ARGS=()
if [[ ${#VALUES_FILES[@]} -gt 0 ]]; then
  for values_file in "${VALUES_FILES[@]}"; do
    values_file="$(absolute_path "${values_file}")"
    if [[ ! -f "${values_file}" ]]; then
      error "Values file not found: ${values_file}"
    fi
    VALUES_ARGS+=(--values "${values_file}")
  done
fi

TMP_DIR=""
cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}
trap cleanup EXIT

TMP_DIR="$(mktemp -d)"
TMP_CHART_DIR="$(copy_chart_to_tmp "${CHART_DIR}" "${TMP_DIR}")"

echo "-------------------------------------------------"
echo "Helm chart values test"
echo "-------------------------------------------------"
echo "Chart:             ${CHART_DIR}"
echo "Temporary chart:   ${TMP_CHART_DIR}"
echo "Release:           ${RELEASE_NAME}"
echo "Namespace:         ${NAMESPACE}"
if [[ ${#VALUES_ARGS[@]} -gt 0 ]]; then
  echo "Values files:"
  for ((i = 1; i < ${#VALUES_ARGS[@]}; i += 2)); do
    echo "  - ${VALUES_ARGS[$i]}"
  done
else
  echo "Values files:      none"
fi
echo "Skip dependencies: ${SKIP_DEPENDENCIES}"
if [[ -n "${OUTPUT_FILE}" ]]; then
  echo "Template output:   ${OUTPUT_FILE}"
else
  echo "Template output:   stdout"
fi
echo ""

if [[ "${SKIP_DEPENDENCIES}" != "true" && "$(chart_has_dependencies "${CHART_YAML}" && echo true || echo false)" == "true" ]]; then
  echo "Building chart dependencies in temporary workspace..."
  helm dependency build "${TMP_CHART_DIR}"
  echo ""
elif [[ "${SKIP_DEPENDENCIES}" == "true" ]]; then
  echo "Skipping dependency build by request."
  echo ""
fi

echo "Running helm lint..."
helm lint "${TMP_CHART_DIR}" "${VALUES_ARGS[@]}"
echo ""

echo "Running helm template..."
TEMPLATE_CMD=(
  helm template "${RELEASE_NAME}" "${TMP_CHART_DIR}"
  --namespace "${NAMESPACE}"
  "${VALUES_ARGS[@]}"
  --debug
  "${HELM_TEMPLATE_ARGS[@]}"
)

if [[ -n "${OUTPUT_FILE}" ]]; then
  output_dir="$(dirname "${OUTPUT_FILE}")"
  mkdir -p "${output_dir}"
  "${TEMPLATE_CMD[@]}" > "${OUTPUT_FILE}"
  echo "Rendered manifests written to: ${OUTPUT_FILE}"
else
  "${TEMPLATE_CMD[@]}"
fi

echo ""
echo "✔ Helm chart values test complete."
