import zipfile, json, os, sys

apk = r"app/build/app/outputs/flutter-apk/app-store-release.apk"
src = r"app/assets/data/multiplayer.json"

# Prefer the released APK; fall back to the source catalog so the guard runs
# in dev without a build.
if os.path.exists(apk):
    z = zipfile.ZipFile(apk)
    names = [n for n in z.namelist() if "multiplayer" in n]
    print("candidate names:", names)
    target = names[0]
    data = z.read(target).decode("utf-8")
    print("source: APK", apk)
else:
    with open(src, "r", encoding="utf-8") as f:
        data = f.read()
    print("source: file", src)

j = json.loads(data)
print("mame section present:", '"mame"' in data)
print("fceumm:", len(j.get("fceumm", {})),
      "fbalpha2012:", len(j.get("fbalpha2012", {})),
      "mame:", len(j.get("mame", {})))
print("sample mame keys:", list(j.get("mame", {}).keys())[:8])
for drv in ["kof97", "mslug", "sf2", "dino", "garou", "1941r1"]:
    print(f"  mame[{drv}] =", j.get("mame", {}).get(drv))

# Regression guard: MAME 0.197 driver names have no spaces, so every spaced
# `mame` driver must carry a no-space alias. Otherwise zips named after the
# canonical driver (e.g. `kof97.zip`) fail to resolve.
mame = j.get("mame", {})
missing = []
for key in mame:
    if " " in key:
        alias = key.replace(" ", "")
        if alias not in mame:
            missing.append((key, alias))

if missing:
    print("\nREGRESSION: spaced mame drivers missing no-space alias:")
    for key, alias in missing:
        print(f"  '{key}' -> missing '{alias}'")
    sys.exit(1)

spaced = [k for k in mame if " " in k]
print(f"\nmame spacing alignment OK: {len(spaced)} spaced driver(s) "
      f"all have a no-space alias")
