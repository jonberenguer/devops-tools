# forklift-cli

A bash utility for migrating Docker Compose services between hosts. It packages a running service's images, compose folder, and named volumes into a single timestamped archive, and restores that archive on a destination host.

The script depends only on `docker` and standard POSIX tools (`bash`, `date`, `id`, `dirname`, `tar`, `find`). All other utilities (`jq`, `yq`, `7z`) run inside the `local/forklift` container — no additional packages need to be installed on the host.

---

## Requirements

- Docker (with the `compose` plugin)
- `bash` 4+
- The `local/forklift` utility image (built with the `image-build` command below)

---

## Setup

Build the utility container once before running any other commands:

```bash
bash forklift-cli.sh image-build
```

This produces a local Alpine-based image (`local/forklift:latest`) that contains `bash`, `7zip`, `yq`, `jq`, `tar`, and a set of optional ad-hoc tools (`rsync`, `openssh`, `curl`, etc.).

To include `vim` in the image (useful for interactive debugging inside the container):

```bash
docker build --no-cache --build-arg INCLUDE_VIM=true \
  -t local/forklift:latest \
  ~/image-builders/forklift
```

---

## Usage

```
bash forklift-cli.sh <method> <service-name> <vol-password> [timestamp]
```

| Argument | Description |
|---|---|
| `method` | `image-build`, `build`, or `deploy` |
| `service-name` | The name of the Docker Compose service (must match `docker compose ls` output) |
| `vol-password` | Password used to encrypt volume archives with 7z |
| `timestamp` | Required for `deploy` only — the timestamp of the archive to restore (`YYYYMMDD_HHMMSS`) |

### Commands

#### `image-build`

Builds the `local/forklift` utility container. Run this once on each host (source and destination) before using `build` or `deploy`.

```bash
bash forklift-cli.sh image-build
```

---

#### `build`

Snapshots a running Compose service into a timestamped archive stored under `~/temp/`.

```bash
bash forklift-cli.sh build <service-name> <vol-password>
```

What it captures:

- All Docker images referenced in the compose file
- The entire service folder (the directory containing `docker-compose.yml`)
- All named Docker volumes, encrypted with the provided password using 7z

Output archive: `~/temp/<service-name>_<TIMESTAMP>-with-images.tar.gz`

**Example:**

```bash
bash forklift-cli.sh build myapp s3cr3tpassword
```

---

#### `deploy`

Restores a previously built archive onto the current host.

```bash
bash forklift-cli.sh deploy <service-name> <vol-password> <timestamp>
```

What it restores:

- Loads Docker images into the local daemon
- Extracts the service folder to `~/services/<service-name>/`
- Recreates all named volumes and decrypts their contents

After a successful deploy, start the service manually:

```bash
docker compose -f ~/services/<service-name>/docker-compose.yml up -d
```

**Example:**

```bash
bash forklift-cli.sh deploy myapp s3cr3tpassword 20260315_142301
```

---

## Password Security

The `vol-password` argument is used to encrypt and decrypt volume archives. How you supply it has a direct impact on how exposed it is.

### The risk with positional arguments

Passing the password directly on the command line as `$3` means it is visible in the OS process list for the duration of the script:

```
# Anyone running this on the host can see it:
ps aux | grep forklift
# ... forklift-cli.sh build myapp s3cr3tpassword
```

The three approaches below eliminate or significantly reduce this exposure, in order of increasing robustness.

---

### Option 1 — Interactive prompt (recommended for manual runs)

Use `read -s` to collect the password silently at the terminal, assign it to an environment variable, and pass that variable to the script. Environment variables are not visible in `ps aux` — they are only accessible via `/proc/<pid>/environ`, which requires root or the same user.

Change the script's argument signature to read `VOL_PW` from the environment instead of `$3`:

```bash
# In forklift-cli.sh, replace:
VOL_PW="${3:-}"

# With:
VOL_PW="${VOL_PW:-}"
if [[ -z "${VOL_PW}" ]]; then
  echo "[forklift] VOL_PW environment variable is required." >&2
  exit 1
fi
```

Then invoke the script like this:

```bash
read -rs -p "Volume password: " VOL_PW && echo
export VOL_PW
bash forklift-cli.sh build myapp
unset VOL_PW
```

The `unset` after the call ensures the variable does not linger in your shell session.

---

### Option 2 — Password file (recommended for automation / cron)

Store the password in a file with strict permissions. The password never appears on the command line or in the process list.

```bash
# Create the password file once
echo "s3cr3tpassword" > ~/.forklift_secret
chmod 600 ~/.forklift_secret
```

Then read it at call time:

```bash
VOL_PW="$(< ~/.forklift_secret)" bash forklift-cli.sh build myapp
```

Or export it before the call:

```bash
export VOL_PW="$(< ~/.forklift_secret)"
bash forklift-cli.sh build myapp
unset VOL_PW
```

**Tips:**

- Store the file on a `tmpfs` mount (e.g. `/dev/shm/`) to avoid it ever hitting disk:
  ```bash
  echo "s3cr3tpassword" > /dev/shm/.forklift_secret
  chmod 600 /dev/shm/.forklift_secret
  ```
- Never commit the password file to version control. Add it to `.gitignore` if the script lives in a repo.
- Rotate the password and regenerate archives if the host is ever compromised.

---

### Option 3 — Secrets manager (recommended for shared or production environments)

Tools like [`pass`](https://www.passwordstore.org/), `gopass`, or the system keyring (`secret-tool` on Linux) store passwords in an encrypted vault and expose them only at runtime.

Using `pass`:

```bash
# Store the password once
pass insert forklift/vol-password

# Use it at call time
VOL_PW="$(pass show forklift/vol-password)" bash forklift-cli.sh build myapp
```

Using the GNOME keyring (`secret-tool`):

```bash
# Store once
secret-tool store --label="forklift vol-password" service forklift account vol-password

# Use at call time
VOL_PW="$(secret-tool lookup service forklift account vol-password)" bash forklift-cli.sh build myapp
```

This is the strongest option: the password is encrypted at rest, never written to a plain file, and only decrypted into memory at the moment it is needed.

---

### Summary

| Method | Visible in `ps aux` | Survives reboot | Good for automation |
|---|---|---|---|
| Positional argument (`$3`) | ✅ Yes — avoid | ✗ No | ✗ No |
| `read -s` + env var | ✗ No | ✗ No | ✗ No |
| Password file (`chmod 600`) | ✗ No | ✅ Yes | ✅ Yes |
| Password file on `tmpfs` | ✗ No | ✗ No | ✅ Yes |
| Secrets manager (`pass` etc.) | ✗ No | ✅ Yes | ✅ Yes |

---

## Archive Layout

```
~/temp/
└── <service-name>/
    └── <TIMESTAMP>/
        ├── <service-name>_images.tar          # Docker image dump
        ├── <service-name>-service-folder.tar.gz  # Compose project folder
        └── <vol-name>-archive.7z              # Encrypted volume (one per named volume)

~/temp/<service-name>_<TIMESTAMP>-with-images.tar.gz  # Final archive (copy this to destination)
```

---

## Transferring to the Destination Host

The script does not handle transfer — copy the archive to the destination by whatever means suits your environment:

```bash
# scp
scp ~/temp/myapp_20260315_142301-with-images.tar.gz user@destination:~/temp/

# rsync
rsync -avz ~/temp/myapp_20260315_142301-with-images.tar.gz user@destination:~/temp/
```

Then run `deploy` on the destination host.

---

## Notes

- `SERVICE_NAME` must contain only alphanumerics, hyphens, and underscores.
- The `deploy` command brings the Compose stack **down** before restoring volumes. Any running containers for that service will be stopped.
- After deploy, the service is **not** started automatically — this is intentional so you can verify the restore before going live.
- The forklift image must be built on **both** the source and destination host before running `build` or `deploy`.
