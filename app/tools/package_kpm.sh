#!/bin/sh
# Build Daily as a KPM package (.kpkg) and a KPM repository folder.
#
#   tools/package_kpm.sh            uses build/kindle/daily (tools/build_kindle.sh)
#   DAILY_BIN=path tools/package_kpm.sh   use another binary (tests)
#
# Output:
#   build/kpm/daily_<version>_kindlepw2-kindlehf.kpkg
#   build/kpm-repo/   -> publish this folder (e.g. GitHub Pages); its
#                        manifest.json URL is what `kpm add-repo` takes.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BIN="${DAILY_BIN:-${ROOT}/build/kindle/daily}"
[ -f "${BIN}" ] || { echo "missing ${BIN}; run tools/build_kindle.sh first" >&2; exit 1; }

STAGE="${ROOT}/build/kpm/stage"
rm -rf "${STAGE}" && mkdir -p "${STAGE}/assets"
cp "${BIN}" "${STAGE}/daily-luajit"
cp "${ROOT}/main.lua" "${ROOT}/config.example.lua" "${ROOT}/LICENSE.tome" "${STAGE}/"
cp "${ROOT}/platform/kindle/daily.sh" "${STAGE}/"
cp -r "${ROOT}/core" "${ROOT}/daily" "${ROOT}/fonts" "${STAGE}/"
cp "${ROOT}/platform/kindle/kpm/install.sh" "${ROOT}/platform/kindle/kpm/launch.sh" \
   "${ROOT}/platform/kindle/kpm/uninstall.sh" "${STAGE}/"
cp -r "${ROOT}/platform/kindle/kpm/scriptlet" "${ROOT}/platform/kindle/kpm/kual" "${STAGE}/"
(cd "${ROOT}" && luajit tools/make_icon.lua "${STAGE}/assets/daily-icon.png")

python3 - "${ROOT}" "${STAGE}" "${VERSION}" <<'PY'
import json, os, sys, tarfile, shutil
root, stage, version = sys.argv[1], sys.argv[2], sys.argv[3]
ver = [int(x) for x in version.split(".")]
platforms = ["kindlepw2", "kindlehf"]  # one static ARMv7 binary runs on both
manifest = {
    "manifest_version": 2,
    "id": "daily",
    "name": "Daily",
    "author": "Daily",
    "description": "Morning dashboard: top news by category, markets and weather",
    "version": ver,
    "dependencies": [],
    "supported_platforms": platforms,
}
with open(os.path.join(stage, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)
with open(os.path.join(stage, "VERSION"), "w") as f:
    f.write(version + "\n")

name = f"daily_{version}_{'-'.join(platforms)}.kpkg"
out = os.path.join(root, "build", "kpm", name)

def exe_filter(info):
    # keep scripts and the binary executable for KPM's extractor
    if info.isfile() and (info.name.endswith(".sh") or info.name == "daily-luajit"):
        info.mode = 0o755
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    return info

with tarfile.open(out, "w:gz", compresslevel=6) as tar:
    for item in sorted(os.listdir(stage)):
        tar.add(os.path.join(stage, item), arcname=item, filter=exe_filter)

# Repository folder in KPM's layout (rebuilt from scratch: latest version only)
repo = os.path.join(root, "build", "kpm-repo")
shutil.rmtree(repo, ignore_errors=True)
art_rel = f"packages/daily/artifacts/{name}"
os.makedirs(os.path.join(repo, os.path.dirname(art_rel)), exist_ok=True)
shutil.copy(out, os.path.join(repo, art_rel))
repo_manifest = {
    "manifest_version": 2,
    "id": "daily",
    "name": "Daily",
    "description": "Daily: a morning dashboard for Kindle",
    "packages": {
        "daily": {
            "name": manifest["name"],
            "author": manifest["author"],
            "description": manifest["description"],
            "artifacts": [{
                "url": art_rel,
                "version": ver,
                "dependencies": [],
                "supported_platforms": platforms,
            }],
        }
    },
}
with open(os.path.join(repo, "manifest.json"), "w") as f:
    json.dump(repo_manifest, f, indent=2)

# Fixed-name copy for USB updates, and latest.json for the in-app updater
import hashlib
shutil.copy(out, os.path.join(repo, "daily-latest.kpkg"))
with open(out, "rb") as f:
    digest = hashlib.sha256(f.read()).hexdigest()
with open(os.path.join(repo, "latest.json"), "w") as f:
    json.dump({"version": version, "file": "daily-latest.kpkg", "sha256": digest,
               "size": os.path.getsize(out)}, f, indent=2)
with open(os.path.join(repo, "index.html"), "w") as f:
    f.write(f"""<!doctype html><meta charset="utf-8"><title>Daily KPM repository</title>
<style>body{{font:16px/1.5 Georgia,serif;max-width:40em;margin:2em auto;padding:0 1em}}code{{background:#eee;padding:.1em .3em}}</style>
<h1>Daily</h1>
<p>{manifest["description"]}. Version {version}.</p>
<h2>Install with KPM</h2>
<ol>
<li>Search bar: <code>;kpm install kterm</code>, then open kterm.</li>
<li>In kterm: <code>kpm add-repo &lt;this page's address&gt;manifest.json</code> then <code>kpm update</code> (once).</li>
<li>Search bar: <code>;kpm install daily</code>. Later: <code>;kpm upgrade</code>.</li>
</ol>
<h2>Update over USB</h2>
<p>Download <a href="daily-latest.kpkg">daily-latest.kpkg</a>, copy it into the <code>daily/update</code>
folder on your Kindle, eject, and open Daily.</p>
<p>Files: <a href="manifest.json">manifest.json</a> &middot; <a href="{art_rel}">{name}</a> &middot; <a href="daily-kindle.zip">daily-kindle.zip</a> (USB install with KUAL)</p>
""")
print("package:", out)
print("repository:", repo)
PY
