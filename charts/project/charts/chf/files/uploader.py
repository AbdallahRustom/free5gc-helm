#!/usr/bin/env python3
import os
import sys
import time
import shutil
import zipfile
import subprocess
from datetime import datetime, timezone
from glob import glob

def log(msg: str) -> None:
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"[{ts}] {msg}", flush=True)

def iso_now() -> int:
    return int(time.time())

def getenv_int(name: str, default: int) -> int:
    val = os.getenv(name)
    if val is None or val == "":
        return default
    try:
        return int(val)
    except ValueError:
        return default

def sftp_batch_key(host: str, port: int, user: str, key_path: str, batch: str) -> (int, str):
    """
    Execute an SFTP batch against host using key auth, with StrictHostKeyChecking disabled,
    mirroring the Bash command used in your script.
    Returns (rc, combined_output).
    """
    cmd = [
        "sftp", "-vv",
        "-i", key_path,
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "PreferredAuthentications=publickey",
        "-o", "PasswordAuthentication=no",
        "-o", "KbdInteractiveAuthentication=no",
        "-o", "BatchMode=yes",
        "-P", str(port),
        "-b", "-", f"{user}@{host}",
    ]
    try:
        p = subprocess.run(
            cmd,
            input=batch,
            text=True,
            capture_output=True,
            check=False,
        )
        output = (p.stdout or "") + (p.stderr or "")
        return p.returncode, output
    except FileNotFoundError:
        return 127, "sftp: command not found"
    except Exception as e:
        return 1, f"sftp error: {e}"

def main() -> int:
    log("uploader start")

    # Directories
    BASE = os.getenv("CDR_BASE", "/data/cdr")
    IN = os.path.join(BASE, "incoming")
    FAILED = os.path.join(BASE, "failed")
    SENT = os.path.join(BASE, "sent")
    TMP_ZIP_DIR = os.path.join(BASE, "tmp")
    os.makedirs(IN, exist_ok=True)
    os.makedirs(FAILED, exist_ok=True)
    os.makedirs(SENT, exist_ok=True)
    os.makedirs(TMP_ZIP_DIR, exist_ok=True)

    # Policy (match your Bash defaults/comments)
    MIN_SIZE_BYTES = getenv_int("MIN_SIZE_BYTES", 5242880)  # 5 MB
    MIN_AGE_SECS = getenv_int("MIN_AGE_SECS", 300)         # 5 minutes
    QUIET_SECS = getenv_int("QUIET_SECS", 30)              # avoid files still being written

    # SFTP (key-based)
    HOST = os.getenv("SFTP_HOST")
    USER = os.getenv("SFTP_USER")
    PORT = getenv_int("SFTP_PORT", 22)
    KEY = os.getenv("SFTP_PRIVATE_KEY", "/secrets/id_ed25519")
    REMOTE_DIR = os.getenv("SFTP_REMOTE_DIR", "/incoming/cdr")

    if not HOST or not USER:
        log("ERROR: SFTP_HOST and SFTP_USER must be set")
        return 1

    log(f"base={BASE} in={IN} failed={FAILED} sent={SENT} tmp={TMP_ZIP_DIR}")
    log(f"policy: include failed + current where (size>={MIN_SIZE_BYTES} OR age>={MIN_AGE_SECS}) and quiet>={QUIET_SECS}")
    log(f"sftp: host={HOST} port={PORT} remoteDir={REMOTE_DIR} key={KEY}")

    # Ensure zip exists (your Bash checks for the 'zip' CLI, but we use Python's zipfile)
    # If you strictly require the 'zip' binary, uncomment the check below.
    # if shutil.which("zip") is None:
    #     log("ERROR: 'zip' not found. Install it (Alpine: 'apk add --no-cache zip').")
    #     return 1

    now = iso_now()

    # Build candidate lists
    to_send = []
    from_failed = []
    from_current = []

    # Include all failed CDRs
    for f in sorted(glob(os.path.join(FAILED, "*.csv"))):
        to_send.append(f)
        from_failed.append(f)

    # Include eligible current CDRs using OR policy + quiet constraint
    for f in sorted(glob(os.path.join(IN, "*.csv"))):
        try:
            st = os.stat(f)
        except OSError:
            log(f"WARN: stat failed: {f}")
            continue
        sz = st.st_size
        mtime = int(st.st_mtime)
        age = now - mtime

        # OR policy: accept if either size or age threshold is met, and quiet period is met
        if (sz < MIN_SIZE_BYTES) and (age < MIN_AGE_SECS):
            continue
        if age < QUIET_SECS:
            continue

        to_send.append(f)
        from_current.append(f)

    log(f"selection: to_send={len(to_send)} (failed={len(from_failed)} current={len(from_current)})")

    if len(to_send) == 0:
        log("nothing to send, status: OK")
        return 0

    # Create timestamped zip name
    zip_ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    zip_name = f"cdr-batch-{zip_ts}.zip"
    zip_path = os.path.join(TMP_ZIP_DIR, zip_name)

    # Detect duplicate basenames; if found, keep paths inside zip, else flatten
    seen = set()
    collision = False
    for f in to_send:
        bn = os.path.basename(f)
        if bn in seen:
            collision = True
            break
        seen.add(bn)

    if collision:
        log("notice: duplicate basenames detected; keeping paths inside zip")

    # Build zip
    try:
        if os.path.exists(zip_path):
            os.remove(zip_path)
        with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
            for f in to_send:
                if collision:
                    # Keep path relative to BASE (mimics zip without -j)
                    try:
                        arc = os.path.relpath(f, start=BASE)
                    except ValueError:
                        # Fallback if relpath fails: use basename
                        arc = os.path.basename(f)
                else:
                    # Flatten like 'zip -j'
                    arc = os.path.basename(f)
                zf.write(f, arcname=arc)
        log(f"created zip: {zip_path} with {len(to_send)} file(s)")
    except Exception as e:
        log(f"ERROR: zip failed creating {zip_name}: {e}")
        try:
            if os.path.exists(zip_path):
                os.remove(zip_path)
        except Exception:
            pass
        return 1

    # Preflight: ensure remote directory exists
    rc, out = sftp_batch_key(
        HOST, PORT, USER, KEY,
        batch=f'ls "{REMOTE_DIR}"\n'
    )
    for line in out.splitlines():
        print(f"[SFTP] {line}", flush=True)
    if rc != 0:
        log(f"ERROR: remote directory not accessible: {REMOTE_DIR}")
        try:
            if os.path.exists(zip_path):
                os.remove(zip_path)
        except Exception:
            pass
        # Move current candidates to failed; leave existing failed as-is
        for f in from_current:
            try:
                shutil.move(f, os.path.join(FAILED, os.path.basename(f)))
            except Exception as e:
                log(f"WARN: move to failed failed for {f}: {e}")
        log("status: FAILED (preflight)")
        return 1

    # Upload ZIP and verify it landed
    batch = (
        f'put -p "{zip_path}" "{REMOTE_DIR}/{zip_name}"\n'
        f'ls "{REMOTE_DIR}/{zip_name}"\n'
    )
    rc, out = sftp_batch_key(HOST, PORT, USER, KEY, batch=batch)
    for line in out.splitlines():
        print(f"[SFTP] {line}", flush=True)

    if rc == 0:
        log(f"uploaded: {zip_name}")
        # On success: move originals to sent/
        for f in from_current:
            try:
                shutil.move(f, os.path.join(SENT, os.path.basename(f)))
            except Exception as e:
                log(f"WARN: move to sent failed for {f}: {e}")
        for f in from_failed:
            try:
                shutil.move(f, os.path.join(SENT, os.path.basename(f)))
            except Exception as e:
                log(f"WARN: move failed->sent failed for {f}: {e}")
        try:
            os.remove(zip_path)
        except Exception:
            pass
        log(f"status: OK (sent {len(to_send)} file(s) in {zip_name})")
        return 0
    else:
        log(f"ERROR: upload failed: {zip_name}")
        # On failure: move current to failed/, leave existing failed in place
        for f in from_current:
            try:
                shutil.move(f, os.path.join(FAILED, os.path.basename(f)))
            except Exception as e:
                log(f"WARN: move to failed failed for {f}: {e}")
        try:
            os.remove(zip_path)
        except Exception:
            pass
        log("status: FAILED (kept failed CDRs for next run)")
        return 1

if __name__ == "__main__":
    sys.exit(main())
