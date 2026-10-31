#!/usr/bin/env bash

resolve_latest_versions() {
  local xray_release acme_release installer_metadata

  xray_release="$(curl -fsSL --retry 2 --max-time 30 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    https://api.github.com/repos/XTLS/Xray-core/releases/latest)" || {
    printf '[ERROR] could not resolve the latest stable Xray release\n' >&2
    return 1
  }
  XRAY_VERSION="$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | select(type == "string")' <<< "$xray_release")" || {
    printf '[ERROR] Xray latest-release response is invalid\n' >&2
    return 1
  }
  [[ "$XRAY_VERSION" =~ ^v[0-9]+(\.[0-9]+){1,3}$ ]] || {
    printf '[ERROR] Xray latest-release tag is not a stable version: %s\n' "$XRAY_VERSION" >&2
    return 1
  }

  installer_metadata="$(curl -fsSL --retry 2 --max-time 30 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    https://api.github.com/repos/XTLS/Xray-install/commits/main)" || {
    printf '[ERROR] could not resolve the current official Xray installer commit\n' >&2
    return 1
  }
  XRAY_INSTALL_REF="$(jq -er '.sha | select(type == "string")' <<< "$installer_metadata")" || {
    printf '[ERROR] Xray installer commit response is invalid\n' >&2
    return 1
  }
  [[ "$XRAY_INSTALL_REF" =~ ^[0-9a-f]{40}$ ]] || {
    printf '[ERROR] Xray installer commit SHA is invalid\n' >&2
    return 1
  }

  acme_release="$(curl -fsSL --retry 2 --max-time 30 \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    https://api.github.com/repos/acmesh-official/acme.sh/releases/latest)" || {
    printf '[ERROR] could not resolve the latest stable acme.sh release\n' >&2
    return 1
  }
  ACME_VERSION="$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name | select(type == "string")' <<< "$acme_release")" || {
    printf '[ERROR] acme.sh latest-release response is invalid\n' >&2
    return 1
  }
  [[ "$ACME_VERSION" =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]] || {
    printf '[ERROR] acme.sh latest-release tag is not a stable version: %s\n' "$ACME_VERSION" >&2
    return 1
  }
}
