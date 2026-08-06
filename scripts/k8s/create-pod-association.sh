#!/usr/bin/env bash

set -euo pipefail

DEFAULT_CLUSTER_NAME=""
DEFAULT_NAMESPACE="gitlab"
DEFAULT_REGION=""
DEFAULT_ROLE_ARN=""

usage() {
  cat <<EOF_USAGE
Usage: $(basename "$0") --service-accounts LIST [options]

Creates Amazon EKS Pod Identity associations for a comma-separated list of
Kubernetes service accounts. This is useful for GitLab subcomponents that mount
Secrets Store CSI volumes and need the same IAM role association.

Options:
  -s, --service-accounts LIST   Comma-separated service account names. Required.
                                Example: gitlab,gitlab-gitlab-exporter
  -c, --cluster-name NAME       EKS cluster name. Defaults to:
                                ${DEFAULT_CLUSTER_NAME}
  -n, --namespace NAME          Kubernetes namespace. Defaults to:
                                ${DEFAULT_NAMESPACE}
  -r, --role-arn ARN            IAM role ARN to associate. Defaults to:
                                ${DEFAULT_ROLE_ARN}
      --region REGION           AWS region. Defaults to AWS_REGION,
                                AWS_DEFAULT_REGION, active AWS CLI config, or:
                                ${DEFAULT_REGION}
  -p, --profile PROFILE         AWS CLI profile to use.
      --replace                 If an association exists for a service account
                                with a different role, delete it and create the
                                requested association.
      --dry-run                 Print planned create commands only. Does not call
                                AWS or check existing associations.
  -h, --help                    Show this help.

Examples:
  # Create associations using GitLab defaults.
  $(basename "$0") \
    --service-accounts gitlab,gitlab-gitlab-exporter,gitlab-webservice

  # Use an explicit cluster, namespace, role, and region.
  $(basename "$0") \
    --service-accounts gitlab,gitlab-gitlab-exporter \
    --cluster-name air-power-sap-eks-133-blue \
    --namespace gitlab \
    --role-arn arn:aws-us-gov:iam::404122547968:role/air-power-sap-gitlab-role \
    --region us-gov-west-1

  # Preview commands without calling AWS.
  $(basename "$0") --service-accounts gitlab,gitlab-gitlab-exporter --dry-run

EOF_USAGE
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

aws_cli() {
  aws "${AWS_PROFILE_ARG[@]}" "$@"
}

resolve_region() {
  if [[ -n "${AWS_REGION_VALUE}" ]]; then
    echo "${AWS_REGION_VALUE}"
    return
  fi

  if [[ -n "${AWS_REGION:-}" ]]; then
    echo "${AWS_REGION}"
    return
  fi

  if [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    echo "${AWS_DEFAULT_REGION}"
    return
  fi

  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "${DEFAULT_REGION}"
    return
  fi

  local configured_region
  configured_region="$(aws_cli configure get region 2>/dev/null || true)"
  if [[ -n "${configured_region}" && "${configured_region}" != "None" ]]; then
    echo "${configured_region}"
    return
  fi

  echo "${DEFAULT_REGION}"
}

trim() {
  local value="$*"

  # Remove leading whitespace.
  value="${value#"${value%%[![:space:]]*}"}"
  # Remove trailing whitespace.
  value="${value%"${value##*[![:space:]]}"}"

  printf '%s' "${value}"
}

validate_service_account_name() {
  local service_account="$1"

  if [[ ! "${service_account}" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]]; then
    error "Invalid Kubernetes service account name: ${service_account}"
  fi
}

parse_service_accounts() {
  local raw_item
  local service_account

  IFS=',' read -r -a RAW_SERVICE_ACCOUNTS <<< "${SERVICE_ACCOUNTS_CSV}"

  SERVICE_ACCOUNTS=()
  for raw_item in "${RAW_SERVICE_ACCOUNTS[@]}"; do
    service_account="$(trim "${raw_item}")"
    if [[ -z "${service_account}" ]]; then
      continue
    fi

    validate_service_account_name "${service_account}"
    SERVICE_ACCOUNTS+=("${service_account}")
  done

  if [[ ${#SERVICE_ACCOUNTS[@]} -eq 0 ]]; then
    error "--service-accounts must include at least one service account name."
  fi
}

print_dry_run_command() {
  local service_account="$1"

  printf 'aws'
  if [[ ${#AWS_PROFILE_ARG[@]} -gt 0 ]]; then
    printf ' %q %q' "${AWS_PROFILE_ARG[0]}" "${AWS_PROFILE_ARG[1]}"
  fi
  printf ' eks create-pod-identity-association'
  printf ' --cluster-name %q' "${CLUSTER_NAME}"
  printf ' --namespace %q' "${NAMESPACE}"
  printf ' --service-account %q' "${service_account}"
  printf ' --role-arn %q' "${ROLE_ARN}"
  printf ' --region %q\n' "${AWS_REGION_VALUE}"
}

list_association_ids_for_service_account() {
  local service_account="$1"

  aws_cli eks list-pod-identity-associations \
    --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION_VALUE}" \
    --query "associations[?namespace=='${NAMESPACE}' && serviceAccount=='${service_account}'].associationId" \
    --output text
}

describe_association_role_arn() {
  local association_id="$1"

  aws_cli eks describe-pod-identity-association \
    --cluster-name "${CLUSTER_NAME}" \
    --association-id "${association_id}" \
    --region "${AWS_REGION_VALUE}" \
    --query 'association.roleArn' \
    --output text
}

delete_association() {
  local association_id="$1"

  echo "Deleting existing association ${association_id}..."
  aws_cli eks delete-pod-identity-association \
    --cluster-name "${CLUSTER_NAME}" \
    --association-id "${association_id}" \
    --region "${AWS_REGION_VALUE}" >/dev/null
}

create_association() {
  local service_account="$1"
  local association_id

  echo "Creating association for ${NAMESPACE}/${service_account} -> ${ROLE_ARN}"
  association_id="$(aws_cli eks create-pod-identity-association \
    --cluster-name "${CLUSTER_NAME}" \
    --namespace "${NAMESPACE}" \
    --service-account "${service_account}" \
    --role-arn "${ROLE_ARN}" \
    --region "${AWS_REGION_VALUE}" \
    --query 'association.associationId' \
    --output text)"

  echo "  Created association: ${association_id}"
  CREATED_COUNT=$((CREATED_COUNT + 1))
}

ensure_association() {
  local service_account="$1"
  local association_ids_raw
  local association_id
  local existing_role_arn
  local found_matching_role="false"
  local -a association_ids=()

  association_ids_raw="$(list_association_ids_for_service_account "${service_account}")"

  if [[ -n "${association_ids_raw}" && "${association_ids_raw}" != "None" ]]; then
    read -r -a association_ids <<< "${association_ids_raw}"
  fi

  if [[ ${#association_ids[@]} -eq 0 ]]; then
    create_association "${service_account}"
    return
  fi

  for association_id in "${association_ids[@]}"; do
    existing_role_arn="$(describe_association_role_arn "${association_id}")"

    if [[ "${existing_role_arn}" == "${ROLE_ARN}" ]]; then
      echo "Skipping ${NAMESPACE}/${service_account}; association already exists: ${association_id}"
      SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
      found_matching_role="true"
    elif [[ "${REPLACE}" == "true" ]]; then
      echo "Replacing ${NAMESPACE}/${service_account}; existing role differs."
      echo "  Existing association: ${association_id}"
      echo "  Existing role:        ${existing_role_arn}"
      echo "  Requested role:       ${ROLE_ARN}"
      delete_association "${association_id}"
      REPLACED_COUNT=$((REPLACED_COUNT + 1))
    else
      echo "WARNING: ${NAMESPACE}/${service_account} already has association ${association_id} with a different role." >&2
      echo "  Existing role:  ${existing_role_arn}" >&2
      echo "  Requested role: ${ROLE_ARN}" >&2
      echo "  Re-run with --replace to delete and recreate it." >&2
      FAILED_COUNT=$((FAILED_COUNT + 1))
      return
    fi
  done

  if [[ "${found_matching_role}" == "false" && "${REPLACE}" == "true" ]]; then
    create_association "${service_account}"
  fi
}

SERVICE_ACCOUNTS_CSV=""
CLUSTER_NAME="${DEFAULT_CLUSTER_NAME}"
NAMESPACE="${DEFAULT_NAMESPACE}"
ROLE_ARN="${DEFAULT_ROLE_ARN}"
AWS_REGION_VALUE=""
AWS_PROFILE_ARG=()
DRY_RUN="false"
REPLACE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--service-accounts)
      require_value "$1" "${2:-}"
      SERVICE_ACCOUNTS_CSV="$2"
      shift 2
      ;;
    --service-accounts=*)
      SERVICE_ACCOUNTS_CSV="${1#*=}"
      shift
      ;;
    -c|--cluster-name)
      require_value "$1" "${2:-}"
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --cluster-name=*)
      CLUSTER_NAME="${1#*=}"
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
    -r|--role-arn)
      require_value "$1" "${2:-}"
      ROLE_ARN="$2"
      shift 2
      ;;
    --role-arn=*)
      ROLE_ARN="${1#*=}"
      shift
      ;;
    --region)
      require_value "$1" "${2:-}"
      AWS_REGION_VALUE="$2"
      shift 2
      ;;
    --region=*)
      AWS_REGION_VALUE="${1#*=}"
      shift
      ;;
    -p|--profile)
      require_value "$1" "${2:-}"
      AWS_PROFILE_ARG=(--profile "$2")
      shift 2
      ;;
    --profile=*)
      AWS_PROFILE_ARG=(--profile "${1#*=}")
      shift
      ;;
    --replace)
      REPLACE="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${SERVICE_ACCOUNTS_CSV}" ]]; then
  usage
  error "--service-accounts is required."
fi

parse_service_accounts

if [[ "${DRY_RUN}" != "true" ]]; then
  require_command aws
fi

AWS_REGION_VALUE="$(resolve_region)"

if [[ -z "${AWS_REGION_VALUE}" || "${AWS_REGION_VALUE}" == "None" ]]; then
  error "Unable to determine AWS region. Set AWS_REGION or pass --region."
fi

echo "EKS Pod Identity association configuration:"
echo "  Cluster:   ${CLUSTER_NAME}"
echo "  Namespace: ${NAMESPACE}"
echo "  Region:    ${AWS_REGION_VALUE}"
echo "  Role ARN:  ${ROLE_ARN}"
echo ""

if [[ "${DRY_RUN}" == "true" ]]; then
  echo "Dry-run mode enabled. Planned create commands:"
  for service_account in "${SERVICE_ACCOUNTS[@]}"; do
    print_dry_run_command "${service_account}"
  done
  exit 0
fi

CREATED_COUNT=0
SKIPPED_COUNT=0
REPLACED_COUNT=0
FAILED_COUNT=0

for service_account in "${SERVICE_ACCOUNTS[@]}"; do
  ensure_association "${service_account}"
done

echo ""
echo "Summary:"
echo "  Created:  ${CREATED_COUNT}"
echo "  Skipped:  ${SKIPPED_COUNT}"
echo "  Replaced: ${REPLACED_COUNT}"
echo "  Failed:   ${FAILED_COUNT}"

if [[ ${FAILED_COUNT} -gt 0 ]]; then
  exit 1
fi

echo ""
echo "✔ Pod Identity association workflow complete."
