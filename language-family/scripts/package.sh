#!/bin/bash

set -e
set -u
set -o pipefail

readonly ROOT_DIR="$(cd "$(dirname "${0}")/.." && pwd)"
readonly BIN_DIR="${ROOT_DIR}/.bin"
readonly BUILD_DIR="${ROOT_DIR}/build"

function main {
  local version

  while [[ "${#}" != 0 ]]; do
    case "${1}" in
      --version|-v)
        version="${2}"
        shift 2
        ;;

      "")
        # skip if the argument is empty
        shift 1
        ;;

      *)
        echo "unknown argument \"${1}\""
        exit 1
    esac
  done

  if [[ "${version}" == "" ]]; then
    echo "--version is required"
    exit 1
  fi

  os::check
  repo::prepare

  github::token::fetch
  tools::jam::install
  tools::yj::install
  tools::pack::install

  buildpack::archive "${version}"
  buildpackage::toml::write
  buildpackage::create
}

function os::check() {
  local os

  case "$(uname)" in
    "Darwin")
      os="macos"
      ;;

    "Linux")
      os="linux"
      ;;

    *)
      echo "Unknown OS \"$(uname)\""
      exit 1
  esac

  readonly OS="${os}"
}

function repo::prepare() {
  echo "-> Preparing repo..."

  rm -rf "${BUILD_DIR}"

  mkdir -p "${BIN_DIR}"
  mkdir -p "${BUILD_DIR}"

  export PATH="${BIN_DIR}:${PATH}"
}

function tools::jam::install() {
  echo "-> Installing latest jam..."

  local os
  os="${OS}"
  if [[ "${os}" == "macos" ]]; then
    os="darwin"
  fi

  local url
  url="$(
    curl "https://api.github.com/repos/cloudfoundry/packit/releases/latest" \
      --header "Authorization: token ${GITHUB_TOKEN}" \
      --silent \
      --location \
      | jq -r ".assets[] | select(.name | contains(\"${os}\")) | .browser_download_url"
  )"

  curl "${url}" \
    --silent \
    --location \
    --output "${BIN_DIR}/jam"
  chmod +x "${BIN_DIR}/jam"
}

function tools::yj::install() {
  echo "-> Installing latest yj..."

  local url
  url="$(
    curl "https://api.github.com/repos/sclevine/yj/releases/latest" \
      --header "Authorization: token ${GITHUB_TOKEN}" \
      --silent \
      --location \
      | jq -r ".assets[] | select(.name | contains(\"${OS}\")) | .browser_download_url"
  )"

  curl "${url}" \
    --silent \
    --location \
    --output "${BIN_DIR}/yj"
  chmod +x "${BIN_DIR}/yj"
}

function tools::pack::install() {
  echo "-> Installing latest pack..."

  local url
  url="$(
    curl "https://api.github.com/repos/buildpacks/pack/releases/latest" \
      --header "Authorization: token ${GITHUB_TOKEN}" \
      --silent \
      --location \
      | jq -r ".assets[] | select(.name | contains(\"${OS}\")) | .browser_download_url"
  )"

  curl "${url}" \
    --silent \
    --location \
    --output /tmp/pack.tgz
  tar xzf /tmp/pack.tgz -C "${BIN_DIR}"
  chmod +x "${BIN_DIR}/pack"
  rm /tmp/pack.tgz
}

function buildpack::archive() {
  local version
  version="${1}"

  echo "-> Packaging family buildpack into ${BUILD_DIR}/buildpack.tgz..."

  jam pack \
    --buildpack "${ROOT_DIR}/buildpack.toml" \
    --version "${version}" \
    --output "${BUILD_DIR}/buildpack.tgz"
}

function buildpackage::toml::write() {
  echo "-> Generating package config in ${BUILD_DIR}/package.toml..."

  yj -tj < "${ROOT_DIR}/buildpack.toml" \
    | jq -r '.metadata.dependencies[] | select(.id != "lifecycle") | {uri: .uri }' \
    | jq -s --arg uri "${BUILD_DIR}/buildpack.tgz" '. | {buildpack: {uri: $uri}, dependencies: .}' \
    | yj -jt \
    > "${BUILD_DIR}/package.toml"
}

function buildpackage::create() {
  echo "-> Packaging buildpack..."

  pack \
    package-buildpack "${BUILD_DIR}/buildpackage.cnb" \
      --package-config "${BUILD_DIR}/package.toml" \
      --format file
}

function github::token::fetch() {
  if [[ -z "${GITHUB_TOKEN:-""}" ]]; then
    echo "-> Fetching GITHUB_TOKEN..."

    GITHUB_TOKEN="$(
      lpass show Shared-CF\ Buildpacks/concourse-private.yml \
        | grep buildpacks-github-token \
        | cut -d ' ' -f 2
    )"
  fi

  export GITHUB_TOKEN
}

main "${@:-}"
