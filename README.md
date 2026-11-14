# podgrep

Find out which pods in your Kubernetes cluster are running a given package, process, binary or file, in a single command.

Useful for vulnerability response ("which of my pods run `mod_http2`?", "where is `log4j`?", "who still ships `openssl 1.1`?") when you need an answer from the live cluster, not from a build pipeline.

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

## What it checks

For every container in every running pod, it runs read-only checks over `kubectl exec`:

| Check | How | Notes |
|---|---|---|
| Packages | `rpm -qa`, `dpkg-query`, `apk info` | Whichever the image has. Most reliable check; includes the version. |
| Processes | Command lines from `/proc` | Works in images without `ps`. |
| Services | `systemctl list-units` | Usually `n/a` in containers (no systemd). Kept for VM/host use. |
| Binary | `command -v <term>` | BusyBox applets (e.g. BusyBox `httpd`) are flagged so they aren't mistaken for the real program. |
| Files *(optional)* | `find / -xdev -iname "*<term>*"` | Catches things not installed as packages, e.g. `log4j-core-2.14.jar` inside an app. |

A container is reported **FOUND** if any check matches.

Nothing is installed, changed or restarted. Matching is case-insensitive plain text, and the search term is passed into the container as an argument, not pasted into the command, so characters like `*`, `;` or `$` can't break the script or run anything.

## Requirements

- `bash`, `kubectl`
- A kube context pointing at the cluster you want to search (`kubectl config current-context`)
- RBAC permission to `get`/`list` pods and `create` on `pods/exec` in the namespaces you search

Works with any Kubernetes cluster (EKS, GKE, AKS, on-prem, kind, etc.).

## Usage

```bash
git clone https://github.com/<your-username>/podgrep.git
cd podgrep
chmod +x find_in_pods.sh

./find_in_pods.sh              # interactive
./find_in_pods.sh openssl      # skip the first prompt
```

You'll be asked for:
1. **Search term**: a package, process, binary or file name
2. **Namespace**: leave blank for all namespaces
3. **File search**: `y` to also scan file names (slower)

The script shows the cluster context before starting, so you don't search the wrong cluster by accident.

## Output

A summary is printed to the terminal, and full results are written to a timestamped CSV:

`search_<term>_<YYYYMMDD_HHMMSS>.csv`

| Column | Meaning |
|---|---|
| `namespace`, `pod`, `container`, `image` | Where it looked |
| `result` | `FOUND`, `NOT_FOUND`, or a reason it couldn't check (below) |
| `packages`, `processes`, `services`, `binary`, `files` | What matched in each check |

### Containers it can't check

| Result | Meaning | What to do |
|---|---|---|
| `NO_SHELL_scan_image_instead` | Distroless/minimal image with no `sh` | Scan the image (see below) |
| `EXEC_FORBIDDEN_rbac` | Your role can't exec into this pod | Get `pods/exec` permission, or scan the image |
| `CONTAINER_GONE` | Pod restarted during the scan | Re-run |
| `EXEC_FAILED: ...` | Something else; first part of the error is shown | Check the message |

`NO_SHELL` doesn't mean clean. It means the script couldn't look. Distroless images can't contain OS packages such as Apache or OpenSSL from apt/yum, but they can still have vulnerabilities in the application binary itself (for example Go standard library or module CVEs). Use an image scanner for those:

```bash
trivy image <image>
grype <image>
```

On AWS, Amazon Inspector enhanced scanning for ECR covers these automatically.

## Example searches

```bash
./find_in_pods.sh mod_http2    # Apache HTTP/2 module
./find_in_pods.sh httpd        # Apache itself
./find_in_pods.sh openssl
./find_in_pods.sh log4j        # answer "y" to file search to catch bundled JARs
./find_in_pods.sh nginx
./find_in_pods.sh xz           # e.g. xz-utils backdoor checks
```

## Limitations

- Only checks **running** pods, and only regular containers (not init or ephemeral containers).
- Containers are checked one at a time; expect a few minutes for a few hundred containers.
- A **name match is not a vulnerability verdict**. Distros backport security fixes without changing the upstream version number, so compare the package version in the CSV against your vendor's advisory (RHEL, Amazon Linux, Debian, Ubuntu, Alpine).
- The script finds what's in the cluster *right now*. To stop vulnerable images getting deployed in the first place, scan images in CI as well.

## License

MIT
