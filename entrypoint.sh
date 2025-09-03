#!/usr/bin/dumb-init /bin/bash
# shellcheck shell=bash

export RUNNER_ALLOW_RUNASROOT=1
export PATH=${PATH}:/actions-runner

export -n ACCESS_TOKEN
export -n RUNNER_TOKEN
export -n APP_ID
export -n APP_PRIVATE_KEY

# Заставляем этот родительский скрипт игнорировать сигналы завершения.
# Теперь только дочерний процесс раннера будет на них реагировать.
trap '' SIGTERM SIGINT TERM

# --- ВАША ЛОГИКА КОНФИГУРАЦИИ (остается без изменений) ---
_DEBUG_ONLY=${DEBUG_ONLY:-false}
_DEBUG_OUTPUT=${DEBUG_OUTPUT:-false}
_DISABLE_AUTOMATIC_DEREGISTRATION=${DISABLE_AUTOMATIC_DEREGISTRATION:-false}
_RANDOM_RUNNER_SUFFIX=${RANDOM_RUNNER_SUFFIX:="true"}
_RUNNER_NAME=${RUNNER_NAME:-${RUNNER_NAME_PREFIX:-github-runner}-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13 ; echo '')}
if [[ ${RANDOM_RUNNER_SUFFIX} != "true" ]]; then
  if [[ -f "/etc/hostname" ]]; then
    if [[ $(stat --printf="%s" /etc/hostname) -ne 0 ]]; then
      _RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX-"github-runner"}
      _RUNNER_NAME=${RUNNER_NAME:-${_RUNNER_NAME_PREFIX:+${_RUNNER_NAME_PREFIX}-}$(cat /etc/hostname)}
    fi
  fi
fi
_RUNNER_WORKDIR=${RUNNER_WORKDIR:-/_work/${_RUNNER_NAME}}
_LABELS=${LABELS:-default}
_RUNNER_GROUP=${RUNNER_GROUP:-Default}
_GITHUB_HOST=${GITHUB_HOST:="github.com"}
_RUN_AS_ROOT=${RUN_AS_ROOT:="true"}
_START_DOCKER_SERVICE=${START_DOCKER_SERVICE:="false"}
_UNSET_CONFIG_VARS=${UNSET_CONFIG_VARS:="false"}
_CONFIGURED_ACTIONS_RUNNER_FILES_DIR=${CONFIGURED_ACTIONS_RUNNER_FILES_DIR:-""}
if [[ -z ${RUNNER_SCOPE} ]]; then
  if [[ ${ORG_RUNNER} == "true" ]]; then
    export RUNNER_SCOPE="org"
  else
    export RUNNER_SCOPE="repo"
  fi
fi
RUNNER_SCOPE="${RUNNER_SCOPE,,}"
case ${RUNNER_SCOPE} in
  org*)
    [[ -z ${ORG_NAME} ]] && ( echo "ORG_NAME required for org runners"; exit 1 )
    _SHORT_URL="https://${_GITHUB_HOST}/${ORG_NAME}"
    RUNNER_SCOPE="org"
    if [[ -n "${APP_ID}" ]] && [[ -z "${APP_LOGIN}" ]]; then
      APP_LOGIN=${ORG_NAME}
    fi
    ;;
  ent*)
    [[ -z ${ENTERPRISE_NAME} ]] && ( echo "ENTERPRISE_NAME required for enterprise runners"; exit 1 )
    _SHORT_URL="https://${_GITHUB_HOST}/enterprises/${ENTERPRISE_NAME}"
    RUNNER_SCOPE="enterprise"
    ;;
  *)
    [[ -z ${REPO_URL} ]] && ( echo "REPO_URL required for repo runners"; exit 1 )
    _SHORT_URL=${REPO_URL}
    RUNNER_SCOPE="repo"
    if [[ -n "${APP_ID}" ]] && [[ -z "${APP_LOGIN}" ]]; then
      APP_LOGIN=${REPO_URL%/*}
      APP_LOGIN=${APP_LOGIN##*/}
    fi
    ;;
esac
configure_runner() {
  ARGS=()
  if [[ -n "${APP_ID}" ]] && [[ -n "${APP_PRIVATE_KEY}" ]] && [[ -n "${APP_LOGIN}" ]]; then
    if [[ -n "${ACCESS_TOKEN}" ]] || [[ -n "${RUNNER_TOKEN}" ]]; then
      echo "ERROR: ACCESS_TOKEN or RUNNER_TOKEN provided but are mutually exclusive with APP_ID, APP_PRIVATE_KEY and APP_LOGIN." >&2
      exit 1
    fi
    nl="
"
    ACCESS_TOKEN=$(APP_ID="${APP_ID}" APP_PRIVATE_KEY="${APP_PRIVATE_KEY//\\n/${nl}}" APP_LOGIN="${APP_LOGIN}" bash /app_token.sh)
  elif [[ -n "${APP_ID}" ]] || [[ -n "${APP_PRIVATE_KEY}" ]] || [[ -n "${APP_LOGIN}" ]]; then
    echo "ERROR: All of APP_ID, APP_PRIVATE_KEY and APP_LOGIN must be specified." >&2
    exit 1
  fi
  if [[ -n "${ACCESS_TOKEN}" ]]; then
    _TOKEN=$(ACCESS_TOKEN="${ACCESS_TOKEN}" bash /token.sh)
    RUNNER_TOKEN=$(echo "${_TOKEN}" | jq -r .token)
  fi
  if [ -n "${EPHEMERAL}" ]; then
    ARGS+=("--ephemeral")
  fi
  if [ -n "${DISABLE_AUTO_UPDATE}" ]; then
    ARGS+=("--disableupdate")
  fi
  if [ -n "${NO_DEFAULT_LABELS}" ]; then
    ARGS+=("--no-default-labels")
  fi
  ./config.sh \
      --url "${_SHORT_URL}" \
      --token "${RUNNER_TOKEN}" \
      --name "${_RUNNER_NAME}" \
      --work "${_RUNNER_WORKDIR}" \
      --labels "${_LABELS}" \
      --runnergroup "${_RUNNER_GROUP}" \
      --unattended \
      --replace \
      "${ARGS[@]}"
  [[ ! -d "${_RUNNER_WORKDIR}" ]] && mkdir -p "${_RUNNER_WORKDIR}"
}
if [[ -n "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}" ]]; then
  if [[ -d "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}" ]]; then
    cp -p -r "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}/." "/actions-runner"
  fi
  if [ -f "/actions-runner/.runner" ]; then
    echo "The runner has already been configured"
  else
    if [[ ${_DEBUG_ONLY} == "false" ]]; then
      configure_runner
    fi
  fi
else
  if [[ ${_DEBUG_ONLY} == "false" ]]; then
    [[ -f "/actions-runner/.runner" ]] && rm -f /actions-runner/.runner
    configure_runner
  fi
fi
if [[ -n "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}" ]]; then
  if [[ ${_DISABLE_AUTOMATIC_DEREGISTRATION} == "false" ]]; then
    exit 1
  fi
  cp -p -r "/actions-runner/_diag" "/actions-runner/svc.sh" /actions-runner/.[^.]* "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}"
fi
if [[ ${_START_DOCKER_SERVICE} == "true" ]]; then
  _PREFIX=""
  [[ ${_RUN_AS_ROOT} != "true" ]] && _PREFIX="sudo"
  if [[ ${_DEBUG_ONLY} == "true" ]]; then
    echo ${_PREFIX} service docker start
  else
    ${_PREFIX} service docker start
  fi
fi
if [[ ${_UNSET_CONFIG_VARS} == "true" ]]; then
  unset RUN_AS_ROOT; unset RUNNER_NAME; unset RUNNER_NAME_PREFIX; unset RANDOM_RUNNER_SUFFIX; unset ACCESS_TOKEN; unset APP_ID; unset APP_PRIVATE_KEY; unset APP_LOGIN; unset RUNNER_SCOPE; unset ORG_NAME; unset ENTERPRISE_NAME; unset LABELS; unset REPO_URL; unset RUNNER_TOKEN; unset RUNNER_WORKDIR; unset RUNNER_GROUP; unset GITHUB_HOST; unset DISABLE_AUTOMATIC_DEREGISTRATION; unset CONFIGURED_ACTIONS_RUNNER_FILES_DIR; unset EPHEMERAL; unset DISABLE_AUTO_UPDATE; unset START_DOCKER_SERVICE; unset NO_DEFAULT_LABELS; unset UNSET_CONFIG_VARS
fi
if [[ ${_DEBUG_ONLY} == "true" ]] || [[ ${_DEBUG_OUTPUT} == "true" ]] ; then
  echo ""
  echo "Disable automatic registration: ${_DISABLE_AUTOMATIC_DEREGISTRATION}"
  echo "Random runner suffix: ${_RANDOM_RUNNER_SUFFIX}"
  echo "Runner name: ${_RUNNER_NAME}"
  echo "Runner workdir: ${_RUNNER_WORKDIR}"
  echo "Labels: ${_LABELS}"
  echo "Runner Group: ${_RUNNER_GROUP}"
  echo "Github Host: ${_GITHUB_HOST}"
  echo "Run as root:${_RUN_AS_ROOT}"
  echo "Start docker: ${_START_DOCKER_SERVICE}"
fi

# --- Финальное исправление: убираем функцию-обертку start_runner, чтобы избежать создания сабшелла ---
if [[ ${_DEBUG_ONLY} == "false" ]]; then
    if [[ ${_RUN_AS_ROOT} == "true" ]]; then
      if [[ $(id -u) -eq 0 ]]; then
        "$@" &
      else
        echo "ERROR: RUN_AS_ROOT env var is set to true but the user is not running as root, but UID '$(id -u)'"
        exit 1
      fi
    else
      if [[ $(id -u) -eq 0 ]]; then
        [[ -n "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}" ]] && chown -R runner "${_CONFIGURED_ACTIONS_RUNNER_FILES_DIR}"
        chown -R runner "${_RUNNER_WORKDIR}" /actions-runner
        chown runner /opt/hostedtoolcache/
        /usr/sbin/gosu runner "$@" &
      else
        "$@" &
      fi
    fi
    
    # Ждем PID последнего фонового процесса, который мы запустили выше
    wait $!
else
    echo "DEBUG_ONLY is true. Skipping runner execution."
fi