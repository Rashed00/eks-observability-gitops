#!/usr/bin/env bash
# set-target-revision.sh - point every ArgoCD Application that uses a chart
# from our Helm repo at a new chart version.
#
# Used by .github/workflows/bump-target-revision.yml. Can also be run by hand
# (it only edits files under apps/, it does not commit):
#
#   scripts/ci/set-target-revision.sh <chart> <version> [apps-dir]
#
# Only Applications whose repoURL is our Helm repo AND whose chart matches are
# touched. Only the targetRevision line changes, the rest of the file is kept
# exactly as it is (comments, quotes, indentation).
#
# Never goes backwards: if an app is already on the same or a newer version,
# it is left alone.
#
# Prints one line per changed Application, "<file> <app> <old> -> <new>", on
# stdout. Everything else goes to stderr. Exit code 0 also when nothing changed.

set -euo pipefail

CHART="${1:?chart name}"
VERSION="${2:?version}"
APPS_DIR="${3:-apps}"
HELM_REPO="${HELM_REPO:-https://rashed00.github.io/eks-observability-helm-charts}"

[[ "${CHART}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "Bad chart name: ${CHART}" >&2; exit 2; }
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "Bad version: ${VERSION}" >&2; exit 2; }

# Reads a YAML file one document (---) at a time.
#   mode=report : print "<app> <current targetRevision>" for each matching app
#   mode=edit   : print the file with targetRevision replaced in matching apps
# shellcheck disable=SC2016  # $0, $1 below are awk fields, not shell
AWK_PROG='
function norm(u) { gsub(/["'\'']/, "", u); u = tolower(u); sub(/\/+$/, "", u); return u }
function val(line,   v) { v = line; sub(/^[^:]*:[ \t]*/, "", v); sub(/[ \t]+#.*$/, "", v); gsub(/["'\'' \t]/, "", v); return v }
function flush(   i, ind) {
  if (is_app && norm(repo_url) == norm(want_repo) && chart == want_chart && tr_line > 0) {
    if (mode == "report") {
      print app_name, val(buf[tr_line])
    } else {
      ind = buf[tr_line]; sub(/targetRevision:.*/, "", ind)
      buf[tr_line] = ind "targetRevision: " new_version
    }
  }
  if (mode == "edit") for (i = 1; i <= n; i++) print buf[i]
  n = 0; is_app = 0; repo_url = ""; chart = ""; tr_line = 0; app_name = ""; in_meta = 0
}
/^---/ { flush(); if (mode == "edit") print; next }
{ buf[++n] = $0 }
/^kind:[ \t]*Application[ \t]*$/      { is_app = 1 }
/^metadata:/                          { in_meta = 1; next }
/^[^ \t#]/                            { in_meta = 0 }
in_meta && /^  name:/ && app_name == "" { app_name = val($0) }
/^    repoURL:/                       { repo_url = val($0) }
/^    chart:/                         { chart = val($0) }
/^    targetRevision:/                { tr_line = n }
END { flush() }
'

found=0
while IFS= read -r -d '' file; do
  matches="$(awk -v mode=report -v want_repo="${HELM_REPO}" -v want_chart="${CHART}" "${AWK_PROG}" "${file}")"
  [[ -n "${matches}" ]] || continue
  found=1

  update=0
  while read -r app current; do
    if [[ "${current}" == "${VERSION}" ]]; then
      echo "${app} (${file}): already on ${VERSION}." >&2
    elif [[ "$(printf '%s\n%s\n' "${current}" "${VERSION}" | sort -V | tail -1)" != "${VERSION}" ]]; then
      echo "${app} (${file}): on ${current}, which is newer than ${VERSION}. Not going backwards." >&2
    else
      echo "${file} ${app} ${current} -> ${VERSION}"
      update=1
    fi
  done <<<"${matches}"

  if [[ "${update}" == "1" ]]; then
    tmp="$(mktemp)"
    awk -v mode=edit -v want_repo="${HELM_REPO}" -v want_chart="${CHART}" -v new_version="${VERSION}" \
      "${AWK_PROG}" "${file}" >"${tmp}"
    cat "${tmp}" >"${file}"
    rm -f "${tmp}"
  fi
done < <(find "${APPS_DIR}" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 | sort -z)

if [[ "${found}" == "0" ]]; then
  echo "No Application in ${APPS_DIR}/ uses chart '${CHART}' from ${HELM_REPO}." >&2
fi
