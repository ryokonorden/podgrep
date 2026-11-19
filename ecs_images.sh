#!/usr/bin/env bash
# List every running ECS task and its containers/images (current AWS region / profile).
#
# Prints a per-task table, a unique-image summary, and writes ecs_tasks_<timestamp>.csv
#
# Usage: bash ecs_images.sh                       (run with bash, also works from zsh)
#        AWS_REGION=<your-region> bash ecs_images.sh
# Needs: aws CLI, jq

set -uo pipefail
command -v jq >/dev/null || { echo "jq is required (brew install jq)" >&2; exit 1; }

out="ecs_tasks_$(date +%Y%m%d_%H%M%S).csv"
echo "cluster,service,task_id,task_definition,launch_type,status,started_at,container,image,image_digest" > "$out"

for c in $(aws ecs list-clusters --query 'clusterArns[]' --output text); do
  name=${c##*/}
  tasks=()
  while IFS= read -r t; do [ -n "$t" ] && tasks+=("$t"); done < <(
    aws ecs list-tasks --cluster "$c" --desired-status RUNNING --output json | jq -r '.taskArns[]')

  if [ ${#tasks[@]} -eq 0 ]; then echo "-- $name: no running tasks" >&2; continue; fi
  echo "-- $name: ${#tasks[@]} running task(s)" >&2

  for ((i=0; i<${#tasks[@]}; i+=100)); do            # describe-tasks takes max 100 per call
    if ! resp=$(aws ecs describe-tasks --cluster "$c" --tasks "${tasks[@]:i:100}" --output json 2>&1); then
      echo "!! $name: $resp" >&2; continue
    fi
    echo "$resp" | jq -r --arg cl "$name" '
      .tasks[] as $t
      | $t.containers[]
      | [ $cl,
          ($t.group // "" | sub("^service:"; "")),          # service name (or standalone group)
          ($t.taskArn | split("/") | last),                 # task id
          ($t.taskDefinitionArn | split("/") | last),       # family:revision
          ($t.launchType // ($t.capacityProviderName // "")),
          $t.lastStatus,
          ($t.startedAt // "" | tostring | .[0:19]),
          .name,
          .image,
          (.imageDigest // "")
        ] | @csv' >> "$out"
  done
done

rows=$(($(wc -l < "$out") - 1))
[ "$rows" -eq 0 ] && { echo "No running tasks found."; exit 0; }

echo
echo "================ Running tasks ================"
# table: cluster | service | task | taskdef | started | container | image | digest (short)
{ echo "CLUSTER|SERVICE|TASK|TASK_DEF|STARTED|CONTAINER|IMAGE|DIGEST"
  tail -n +2 "$out" | tr -d '"' | awk -F, '{printf "%s|%s|%s|%s|%s|%s|%s|%s\n", $1, $2, substr($3,1,8), $4, $7, $8, $9, substr($10,8,12)}' | sort
} | if command -v column >/dev/null; then column -t -s '|'; else tr '|' '\t'; fi

echo
echo "================ Unique images (tag + digest) ================"
tail -n +2 "$out" | tr -d '"' | awk -F, '{print $9 "  " substr($10,1,19)}' | sort | uniq -c | sort -rn

echo
echo "Same tag with different digests (tag was re-pushed; tasks run different builds):"
dups=$(tail -n +2 "$out" | tr -d '"' | awk -F, '$10!="" {print $9 "," $10}' | sort -u \
       | cut -d, -f1 | uniq -c | awk '$1>1 {print "  " $2 " (" $1 " different digests)"}')
echo "${dups:-  none}"

echo
echo "Full details: $out"
