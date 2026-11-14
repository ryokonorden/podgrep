#!/usr/bin/env bash
# Interactive search across every running pod/container in the current kube context.
# Asks what you're looking for (a package, process, service or file name, e.g. mod_http2,
# openssl, log4j, nginx), then checks each container and reports FOUND / NOT_FOUND.
#
# Checks done inside each container (read-only, nothing is changed):
#   packages  : rpm -qa | dpkg-query | apk info   (whichever exists)
#   processes : running process command lines (/proc, works without ps)
#   services  : systemctl list-units  (usually absent in containers: no systemd)
#   binary    : command -v <term>     (flags BusyBox applets so they aren't mistaken for the real thing)
#   files     : find / -xdev -iname "*<term>*"   (optional, slower)
#
# Usage:  ./find_in_pods.sh                  # interactive prompts
#         ./find_in_pods.sh mod_http2        # skip the search-term prompt
# Needs:  kubectl with get pods + pods/exec rights.

set -uo pipefail
errf=$(mktemp); trap 'rm -f "$errf"' EXIT

# ---------- prompts ----------
term="${1:-}"
while [ -z "$term" ]; do
  read -rp "What are you looking for? (e.g. mod_http2, openssl, log4j, nginx): " term
done
read -rp "Namespace to search (blank = all namespaces): " ns_filter
read -rp "Also search the filesystem for matching file names? Slower. [y/N]: " do_files
case "$do_files" in [Yy]*) do_files=yes ;; *) do_files=no ;; esac

ctx=$(kubectl config current-context 2>/dev/null || echo unknown)
echo
echo "Searching for '$term' | context: $ctx | namespace: ${ns_filter:-ALL} | file search: $do_files"
read -rp "Continue? [Y/n]: " ok
case "$ok" in [Nn]*) echo "Aborted."; exit 0 ;; esac

safe_term=$(echo "$term" | tr -c 'A-Za-z0-9._-' '_')
out="search_${safe_term}_$(date +%Y%m%d_%H%M%S).csv"
echo "namespace,pod,container,image,result,packages,processes,services,binary,files" > "$out"

if [ -n "$ns_filter" ]; then ns_args=(-n "$ns_filter"); else ns_args=(-A); fi

# ---------- check run inside each container ($1 = term, $2 = yes/no file search) ----------
# The term is passed as an argument, not pasted into the script, so odd characters can't break it.
read -r -d '' INNER <<'EOF'
t="$1"; files="$2"
clean() { tr '\n,"' ';; ' | sed 's/;*$//' | cut -c1-300; }

pk=""
command -v rpm  >/dev/null 2>&1 && pk="$pk$(rpm -qa 2>/dev/null | grep -iF -- "$t")"
command -v dpkg-query >/dev/null 2>&1 && pk="$pk$(dpkg-query -W -f='${Package}=${Version}\n' 2>/dev/null | grep -iF -- "$t")"
command -v apk  >/dev/null 2>&1 && pk="$pk$(apk info -v 2>/dev/null | grep -iF -- "$t")"

pr=""
for p in /proc/[0-9]*; do
  [ -r "$p/cmdline" ] || continue
  case "${p#/proc/}" in "$$"|"$PPID") continue ;; esac  # skip this check script itself
  c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$c" in *"clean() {"*|*FIND_IN_PODS_MARKER*) continue ;; esac
  echo "$c" | grep -qiF -- "$t" && pr="$pr${p#/proc/}:$c
"
done

sv="n/a"
if command -v systemctl >/dev/null 2>&1 && systemctl list-units >/dev/null 2>&1; then
  sv=$(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -iF -- "$t")
fi

bn=""
b=$(command -v -- "$t" 2>/dev/null)
if [ -n "$b" ]; then
  real=$(readlink -f "$b" 2>/dev/null || echo "$b")
  case "$real" in *busybox*) bn="$b (BusyBox applet, not the real $t)" ;; *) bn="$b" ;; esac
fi

fl="skipped"
[ "$files" = yes ] && fl=$(find / -xdev \( -path /proc -o -path /sys \) -prune -o -iname "*$t*" -print 2>/dev/null | head -10)

hit=NOT_FOUND
{ [ -n "$pk" ] || [ -n "$pr" ] || { [ -n "$sv" ] && [ "$sv" != n/a ]; } || \
  { [ -n "$bn" ] && ! echo "$bn" | grep -q BusyBox; } || \
  { [ -n "$fl" ] && [ "$fl" != skipped ]; }; } && hit=FOUND

printf '%s|%s|%s|%s|%s|%s\n' "$hit" "$(printf %s "$pk" | clean)" "$(printf %s "$pr" | clean)" \
  "$(printf %s "$sv" | clean)" "$(printf %s "$bn" | clean)" "$(printf %s "$fl" | clean)"
EOF

# ---------- loop over containers ----------
rows=$(kubectl get pods "${ns_args[@]}" --field-selector=status.phase=Running -o go-template='{{range .items}}{{$ns := .metadata.namespace}}{{$pod := .metadata.name}}{{range .spec.containers}}{{$ns}}{{"\t"}}{{$pod}}{{"\t"}}{{.name}}{{"\t"}}{{.image}}{{"\n"}}{{end}}{{end}}')
total=$(printf '%s\n' "$rows" | grep -c .)
[ "$total" -eq 0 ] && { echo "No running pods found."; exit 1; }

found=0; nf=0; failed=0; n=0
while IFS=$'\t' read -r ns pod c image; do
  n=$((n+1)); printf '\r[%d/%d] %-70.70s' "$n" "$total" "$ns/$pod/$c" >&2

  res=$(kubectl exec -n "$ns" "$pod" -c "$c" -- sh -c "$INNER" sh "$term" "$do_files" 2>"$errf" </dev/null)
  if [ $? -ne 0 ] || [ -z "$res" ]; then
    err=$(tr '\n,' '  ' <"$errf")
    case "$err" in
      *"executable file not found"*|*"no such file or directory"*) why="NO_SHELL_scan_image_instead" ;;
      *[Ff]orbidden*) why="EXEC_FORBIDDEN_rbac" ;;
      *"container not found"*|*"not running"*) why="CONTAINER_GONE" ;;
      *) why="EXEC_FAILED: ${err:0:100}" ;;
    esac
    echo "$ns,$pod,$c,$image,\"$why\",,,,," >> "$out"; failed=$((failed+1)); continue
  fi

  IFS='|' read -r hit pk pr sv bn fl <<<"$res"
  echo "$ns,$pod,$c,$image,$hit,\"$pk\",\"$pr\",\"$sv\",\"$bn\",\"$fl\"" >> "$out"
  if [ "$hit" = FOUND ]; then found=$((found+1)); else nf=$((nf+1)); fi
done <<<"$rows"

# ---------- summary ----------
echo >&2
echo
echo "================ Results for '$term' ================"
echo "Containers checked : $total"
echo "FOUND              : $found"
echo "NOT_FOUND          : $nf"
echo "Could not check    : $failed   (no shell / no permission: scan those images instead)"
echo
if [ "$found" -gt 0 ]; then
  echo "'$term' FOUND in:"
  awk -F, '$5=="FOUND" {printf "  %s/%s [%s]  %s\n", $1, $2, $3, $4}' "$out"
else
  echo "'$term' was NOT found in any container that could be checked."
fi
echo
echo "Full details: $out"
