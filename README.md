# podgrep

Find out which of your running containers contain a given package, program or file, in a single command.

Useful for vulnerability response ("which of my pods run `mod_http2`?", "where is `log4j`?", "which images still ship PHP 8.3.36?") when you need an answer from what is **actually running**, not from a build pipeline.

| Script | Platform | What it does |
|---|---|---|
| `find_in_pods.sh` | Kubernetes (EKS, GKE, AKS, on-prem...) | Searches inside every running container via `kubectl exec` |
| `ecs_images.sh` | Amazon ECS (Fargate and EC2) | Lists every running task, its containers, images and exact digests |
| `scan_images_for.sh` | Any (uses the ECS inventory) | Pulls each running image by digest and searches inside it |

All three are read-only: nothing in your cluster is installed, changed or restarted.

---

## Kubernetes: `find_in_pods.sh`

```
$ ./find_in_pods.sh
What are you looking for? (e.g. mod_http2, openssl, log4j, nginx): mod_http2
Namespace to search (blank = all namespaces):
Also search the filesystem for matching file names? Slower. [y/N]: n

Searching for 'mod_http2' | context: my-cluster | namespace: ALL | file search: no
Continue? [Y/n]: y
[120/120] default/example-app-5f7c9d8b6-x2k4p/app

================ Results for 'mod_http2' ================
Containers checked : 120
FOUND              : 2
NOT_FOUND          : 88
Could not check    : 30   (no shell / no permission: scan those images instead)

'mod_http2' FOUND in:
  default/example-web-6d8f7c5b9-abcde [web]  httpd:2.4.66
  default/example-web-6d8f7c5b9-fghij [web]  httpd:2.4.66

Full details: search_mod_http2_20260101_120000.csv
```

### What it checks

For every container in every running pod, it runs read-only checks over `kubectl exec`:

| Check | How | Notes |
|---|---|---|
| Packages | `rpm -qa`, `dpkg-query`, `apk info` | Whichever the image has. Most reliable check; includes the version. |
| Processes | Command lines from `/proc` | Works in images without `ps`. |
| Services | `systemctl list-units` | Usually `n/a` in containers (no systemd). Kept for VM/host use. |
| Binary | `command -v <term>` | BusyBox applets (e.g. BusyBox `httpd`) are flagged so they aren't mistaken for the real program. |
| Files *(optional)* | `find / -xdev -iname "*<term>*"` | Catches things not installed as packages, e.g. `log4j-core-2.14.jar` inside an app. |

A container is reported **FOUND** if any check matches. Matching is case-insensitive plain text, and the search term is passed into the container as an argument, not pasted into the command, so characters like `*`, `;` or `$` can't break the script or run anything.

### Requirements

- `bash`, `kubectl`
- A kube context pointing at the cluster you want to search (`kubectl config current-context`)
- RBAC permission to `get`/`list` pods and `create` on `pods/exec` in the namespaces you search

### Usage

```bash
./find_in_pods.sh              # interactive
./find_in_pods.sh openssl      # skip the first prompt
```

You'll be asked for the search term, a namespace (blank = all), and whether to also search file names. The script shows the cluster context before starting, so you don't search the wrong cluster by accident.

### Output

A summary in the terminal, plus `search_<term>_<timestamp>.csv`:

| Column | Meaning |
|---|---|
| `namespace`, `pod`, `container`, `image` | Where it looked |
| `result` | `FOUND`, `NOT_FOUND`, or a reason it couldn't check (below) |
| `packages`, `processes`, `services`, `binary`, `files` | What matched in each check |

### Containers it can't check

| Result | Meaning | What to do |
|---|---|---|
| `NO_SHELL_scan_image_instead` | Distroless/minimal image with no `sh` | Scan the image instead |
| `EXEC_FORBIDDEN_rbac` | Your role can't exec into this pod | Get `pods/exec` permission, or scan the image |
| `CONTAINER_GONE` | Pod restarted during the scan | Re-run |
| `EXEC_FAILED: ...` | Something else; first part of the error is shown | Check the message |

`NO_SHELL` doesn't mean clean. It means the script couldn't look. Distroless images can't contain OS packages such as Apache or OpenSSL, but they can still have vulnerabilities in the application binary itself (for example Go standard library or module CVEs). Use an image scanner such as `trivy image <image>` or `grype <image>`; on AWS, Amazon Inspector enhanced scanning for ECR covers these automatically.

---

## Amazon ECS: `ecs_images.sh` + `scan_images_for.sh`

ECS has no `kubectl exec`, and Fargate has no host to log into, so ECS is a two-step workflow:

1. **Inventory** what's running (`ecs_images.sh`)
2. **Search inside** each running image (`scan_images_for.sh`)

### Step 1: `ecs_images.sh` (what is running?)

```bash
bash ecs_images.sh                          # run with bash, also from zsh
AWS_REGION=<your-region> bash ecs_images.sh
```

Requires the AWS CLI and `jq`, plus `ecs:ListClusters`, `ecs:ListTasks` and `ecs:DescribeTasks` permissions.

It prints:

1. **Running tasks**: cluster, service, task ID, task definition (family:revision), start time, container, image and image digest
2. **Unique images**: each tag and digest pair, with how many containers run it
3. **Same tag, different digests**: tags that were re-pushed, so tasks under one tag are running different builds

and saves everything to `ecs_tasks_<timestamp>.csv`.

**Why the digest matters:** a tag can be re-pushed, and a long-running task keeps the image it pulled when it started. The digest identifies the exact build a task is running, and that is what step 2 scans.

### Step 2: `scan_images_for.sh` (what's inside?)

```
$ bash scan_images_for.sh
What are you looking for? (e.g. php, nginx, openssl, curl, log4j, python): php
Also search ALL file names, not just programs (finds jars, .so libraries, configs)? [y/N]: n

Searching for 'php' | inventory: ecs_tasks_20260101_120000.csv (4 unique images) | all files: no | platform: linux/amd64
Continue? [Y/n]: y

================ 'php' in running ECS images ================
Images checked: 4 | FOUND: 2

  FOUND      registry.example.com/team/app:v1.2.0
             version:  PHP 8.3.36 (cli) (built: ...)
             programs: /usr/local/bin/php /usr/local/sbin/php-fpm
             used by:  prod-cluster/web-service;stg-cluster/web-service
  FOUND      registry.example.com/team/app:v1.1.0
             version:  PHP 8.3.36 (cli) (built: ...)
             used by:  dev-cluster/web-service
  NOT_FOUND  registry.example.com/team/nginx:v1.0.0
  SKIPPED    registry.example.com/vendor/sidecar:1.0 (skipped_vendor_image)

Full details: scan_php_20260101_120000.csv
```

It reads the newest `ecs_tasks_*.csv` and, for each unique image:

1. Pulls it **by digest**, so it scans the exact build the tasks run
2. Lists the image's files **without running it**, looking for programs (`*/bin/*<term>*`, `*/sbin/*<term>*`) and optionally any matching file name (jars, `.so` libraries, configs)
3. If a program is found, runs **only that program** to get its version (tries `-v`, `--version`, `version`), with the image's entrypoint overridden and networking off
4. If `trivy` and `jq` are installed, also lists matching OS, language and app packages

This finds software **compiled from source** (e.g. PHP in the official `php` images), which package-based scanners can miss.

```bash
bash scan_images_for.sh                       # interactive
bash scan_images_for.sh nginx                 # skip the search-term prompt
CSV=ecs_tasks_X.csv bash scan_images_for.sh   # use a specific inventory
CLEANUP=yes bash scan_images_for.sh           # delete pulled images afterwards
PLATFORM=linux/arm64 bash scan_images_for.sh  # Graviton tasks (default linux/amd64)
SKIP_REGISTRIES='vendor1|vendor2' bash scan_images_for.sh   # skip images you don't build
```

Requires Docker (Docker Desktop running on macOS) and a **registry login** for your private images, e.g. `docker login ...` or a credential helper. A `PULL_FAILED` result almost always means a missing or expired registry login.

### Fixing and verifying

To fix a finding, rebuild the image (new tag recommended), update the task definition, and redeploy the **service** shown in the output:

```bash
aws ecs update-service --cluster <cluster> --service <service> --task-definition <family:new-revision>
```

Then **run both steps again**. `scan_images_for.sh` scans whatever is in the inventory CSV, so without a fresh inventory it would re-scan the old images:

```bash
bash ecs_images.sh                 # new inventory: new digests, check STARTED is after the deploy
bash scan_images_for.sh php        # should now show the patched version
```

---

## Example searches

```bash
./find_in_pods.sh mod_http2            # Kubernetes: Apache HTTP/2 module
./find_in_pods.sh log4j                # answer "y" to file search to catch bundled JARs
bash scan_images_for.sh php            # ECS: PHP version in each running image
bash scan_images_for.sh openssl        # answer "y" to also find libssl*.so
bash scan_images_for.sh nginx
```

## Limitations

- Only checks what is **running right now**. To stop vulnerable images getting deployed, scan images in CI as well.
- `find_in_pods.sh` checks regular containers only (not init or ephemeral containers), one at a time; expect a few minutes for a few hundred containers.
- A **name match is not a vulnerability verdict**. Distros backport security fixes without changing the upstream version number, so compare versions against your vendor's advisory (RHEL, Amazon Linux, Debian, Ubuntu, Alpine) or the upstream release notes.
- `scan_images_for.sh` covers programs, file names and packages. It does not see application-level components such as CMS plugins; use a dedicated scanner for those.

## Keep results out of git

All three scripts write CSVs containing your real cluster, service, pod and image names. Don't commit them:

```bash
printf 'search_*.csv\necs_tasks_*.csv\nscan_*.csv\n' > .gitignore
```

## License

MIT
