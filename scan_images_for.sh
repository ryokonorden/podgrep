#!/usr/bin/env bash
# Interactive search inside the container images your ECS tasks are running.
# Asks what you're looking for (php, nginx, openssl, log4j, curl, ...), pulls each unique
# image from an ecs_images.sh CSV by exact digest, and reports FOUND / NOT_FOUND.
#
# How it checks (works even when software was compiled from source, not packaged):
#   1. docker pull <image>@<digest>          (the exact build the tasks run)
#   2. list the image filesystem WITHOUT running it (docker create + export)
#        - programs:  */bin/*<term>*  and  */sbin/*<term>*
#        - optional:  any file name containing <term>  (jars, .so libraries, configs...)
#   3. if a program is found, run ONLY that program to get its version
#      (tries -v, --version, version; image entrypoint overridden, networking off)
#   4. optional: trivy package list (OS, language and app packages matching <term>)
#
# Usage: bash scan_images_for.sh                     # interactive prompts
#        bash scan_images_for.sh nginx               # skip the search-term prompt
#        CSV=ecs_tasks_X.csv bash scan_images_for.sh # pick a specific inventory file
#        CLEANUP=yes bash scan_images_for.sh         # delete pulled images afterwards
#        PLATFORM=linux/arm64 bash scan_images_for.sh  (default linux/amd64)
# Needs: docker (Docker Desktop running on macOS), logged in to your registries.

set -uo pipefail

# ---------- inputs ----------
csv="${CSV:-$(ls -t ecs_tasks_*.csv 2>/dev/null | head -1)}"
[ -n "$csv" ] && [ -f "$csv" ] || { echo "No ecs_tasks_*.csv found. Run ecs_images.sh first, or set CSV=<file>." >&2; exit 1; }
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker isn't running (start Docker Desktop)" >&2; exit 1; }

term="${1:-}"
while [ -z "$term" ]; do
  read -rp "What are you looking for? (e.g. php, nginx, openssl, curl, log4j, python): " term
done
read -rp "Also search ALL file names, not just programs (finds jars, .so libraries, configs)? [y/N]: " all_files
case "$all_files" in [Yy]*) all_files=yes ;; *) all_files=no ;; esac

platform="${PLATFORM:-linux/amd64}"
skip_re="${SKIP_REGISTRIES:-registry.crowdstrike.com}"   # vendor sidecars you don't build

pairs=$(tail -n +2 "$csv" | tr -d '"' | awk -F, '{print $9 "," $10}' | sort -u)
total=$(printf '%s\n' "$pairs" | grep -c .)

echo
echo "Searching for '$term' | inventory: $csv ($total unique images) | all files: $all_files | platform: $platform"
read -rp "Continue? [Y/n]: " ok
case "$ok" in [Nn]*) echo "Aborted."; exit 0 ;; esac

safe_term=$(echo "$term" | tr -c 'A-Za-z0-9._-' '_')
out="scan_${safe_term}_$(date +%Y%m%d_%H%M%S).csv"
echo "image,digest,result,programs,version,other_files,packages,used_by,scan_status" > "$out"
term_re=$(printf '%s' "$term" | sed 's/[][\.*^$+?(){}|/]/\\&/g')   # treat the term as plain text

# ---------- scan each unique image ----------
n=0; found_n=0
while IFS=, read -r image digest; do
  n=$((n+1))
  used_by=$(tail -n +2 "$csv" | tr -d '"' | awk -F, -v i="$image" -v d="$digest" '$9==i && $10==d {print $1 "/" $2}' | sort -u | paste -sd ';' -)

  if echo "$image" | grep -Eq "$skip_re"; then
    echo "[$n/$total] skip (vendor image): $image" >&2
    echo "\"$image\",\"$digest\",,,,,,\"$used_by\",skipped_vendor_image" >> "$out"; continue
  fi

  # exact reference: repo@digest (strip tag, keep registry ports)
  if [[ "$image" == *@* ]]; then ref="$image"
  elif [ -n "$digest" ]; then
    last="${image##*/}"; [[ "$last" == *:* ]] && repo="${image%:*}" || repo="$image"
    ref="$repo@$digest"
  else ref="$image"; fi

  echo "[$n/$total] $ref" >&2
  if ! docker pull -q --platform "$platform" "$ref" >/dev/null 2>/tmp/pull_err; then
    echo "   pull failed: $(head -1 /tmp/pull_err)" >&2
    echo "\"$image\",\"$digest\",,,,,,\"$used_by\",PULL_FAILED_check_registry_login" >> "$out"; continue
  fi

  # file listing without running the image
  cid=$(docker create --platform "$platform" "$ref" 2>/dev/null)
  listing=$(docker export "$cid" | tar -t 2>/dev/null | grep -v '/$')
  docker rm -f "$cid" >/dev/null 2>&1

  progs=$(echo "$listing" | grep -Ei "(^|/)s?bin/[^/]*${term_re}[^/]*$" | sed 's|^|/|' | sort -u | head -10)
  others=""
  if [ "$all_files" = yes ]; then
    others=$(echo "$listing" | grep -Ei "[^/]*${term_re}[^/]*$" | grep -Eiv "(^|/)s?bin/" \
             | grep -Ev '^(usr/share/(doc|man|locale)|usr/share/zoneinfo)/' | sed 's|^|/|' | sort -u | head -15)
  fi

  # version: prefer a program named exactly <term> (optionally with version digits)
  ver=""
  if [ -n "$progs" ]; then
    first=$(echo "$progs" | grep -Ei "/${term_re}[0-9.-]*$" | head -1); first="${first:-$(echo "$progs" | head -1)}"
    for flag in -v --version version; do
      o=$(docker run --rm --platform "$platform" --network none --entrypoint "$first" "$ref" $flag 2>&1 </dev/null || true)
      o=$(printf '%s\n' "$o" | head -2 | tr '\n' ' ')
      if echo "$o" | grep -q '[0-9]\.[0-9]' && ! echo "$o" | grep -Eqi 'unknown|invalid|illegal|usage:|not found|no such'; then
        ver="$o"; break
      fi
    done
    ver="${ver:-version not detected (try running $first manually)}"
  fi

  # optional package match (OS packages, composer, npm, pip, jars ...)
  pkgs=""
  if command -v trivy >/dev/null && command -v jq >/dev/null; then
    pkgs=$(trivy image -q --list-all-pkgs --format json "$ref" 2>/dev/null \
           | jq -r '.Results[]?.Packages[]? | "\(.Name)=\(.Version)"' | grep -iF -- "$term" | sort -u | head -15 | paste -sd ' ' -)
  fi

  if [ -n "$progs$others$pkgs" ]; then result=FOUND; found_n=$((found_n+1)); else result=NOT_FOUND; fi
  echo "   $result ${ver:+($ver)}" >&2

  clean() { printf '%s' "$1" | tr '\n,"' ' ; ' | sed 's/ *$//'; }
  echo "\"$image\",\"$digest\",$result,\"$(clean "$progs")\",\"$(clean "$ver")\",\"$(clean "$others")\",\"$(clean "$pkgs")\",\"$used_by\",ok" >> "$out"

  [ "${CLEANUP:-no}" = yes ] && docker rmi "$ref" >/dev/null 2>&1
done <<< "$pairs"

# ---------- summary ----------
echo
echo "================ '$term' in running ECS images ================"
echo "Images checked: $total | FOUND: $found_n"
echo
tail -n +2 "$out" | tr -d '"' | awk -F, '
  $3=="FOUND" {
    printf "  FOUND      %s\n", $1
    if ($5!="") printf "             version:  %s\n", $5
    if ($4!="") printf "             programs: %s\n", $4
    if ($6!="") printf "             files:    %s\n", $6
    if ($7!="") printf "             packages: %s\n", $7
    printf "             used by:  %s\n", $8 }
  $3=="NOT_FOUND" { printf "  NOT_FOUND  %s\n", $1 }
  $9!="ok" && $9!="" { printf "  %-10s %s\n", "SKIPPED", $1 " (" $9 ")" }'
echo
echo "Full details: $out"
