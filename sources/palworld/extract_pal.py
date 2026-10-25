#!/usr/bin/env python3
"""Extract one pal from your Palworld install, on the machine where the game is
installed (Windows or Linux). Writes <Pal>-extract.zip for sources/palworld/make_pet.sh on the Mac.

  python3 extract_pal.py --list                 # internal names of every pal with a model
  python3 extract_pal.py KingWhale              # Panthalus
  python3 extract_pal.py KingWhale --pak "D:/Steam/steamapps/common/Palworld/Pal/Content/Paks/Pal-Windows.pak"

Needs only Python 3.9+. Downloads repak (the .pak reader) into ./sekhpet-tools on first
run. The game files are only read, never changed. The zip holds the pal's model,
animations, materials and textures, the stats and name tables the pipeline reads, and
the archive listing. It's built from game data: keep it to yourself.
"""
import argparse
import hashlib
import json
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile
from pathlib import Path

REPAK = 'v0.2.3'
RELEASE = f'https://github.com/trumank/repak/releases/download/{REPAK}/'
ARCHIVES = {'Linux': 'repak_cli-x86_64-unknown-linux-gnu.tar.xz', 'Windows': 'repak_cli-x86_64-pc-windows-msvc.zip'}
STEAM_PAK = 'steamapps/common/Palworld/Pal/Content/Paks/Pal-Windows.pak'
DEFAULT_PAKS = [Path.home() / '.local/share/Steam' / STEAM_PAK, Path.home() / '.steam/steam' / STEAM_PAK,
                Path('C:/Program Files (x86)/Steam') / STEAM_PAK]
MONSTER = 'Pal/Content/Pal/{}/Character/Monster/'
SIDECARS = ('.uasset', '.uexp', '.ubulk', '.uptnl')
# The stats table (sizes, speeds) and English names the pipeline reads.
TABLES = ['**/DT_PalMonsterParameter.*', 'Pal/Content/L10N/en/Pal/DataTable/Text/DT_PalNameText_Common.*']
LIMIT_FILES, LIMIT_BYTES = 4000, 512 * 1024 * 1024


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def find_repak(tools, given):
    if given:
        return Path(given)
    if shutil.which('repak'):
        return Path(shutil.which('repak'))
    system = platform.system()
    if system not in ARCHIVES:
        sys.exit(f'No repak download for {system}; install it (cargo install repak_cli) and pass --repak.')
    name = 'repak.exe' if system == 'Windows' else 'repak'
    found = next(tools.rglob(name), None) if tools.exists() else None
    if found:
        return found
    tools.mkdir(parents=True, exist_ok=True)
    archive = tools / ARCHIVES[system]
    print(f'Downloading repak {REPAK}...')
    urllib.request.urlretrieve(RELEASE + archive.name, archive)
    expected = urllib.request.urlopen(RELEASE + archive.name + '.sha256').read().decode().split()[0]
    if sha256(archive) != expected:
        sys.exit('repak download is corrupt (checksum mismatch); delete sekhpet-tools and retry.')
    if archive.suffix == '.zip':
        zipfile.ZipFile(archive).extractall(tools)
    else:
        with tarfile.open(archive) as stream:
            try:
                stream.extractall(tools, filter='data')
            except TypeError:  # Python before 3.12 without the backported filter
                stream.extractall(tools)
    return next(tools.rglob(name))


def package_path(ref):
    if ref.startswith('/Game/'):
        return 'Pal/Content/' + ref[6:]
    if ref.startswith('/Engine/'):
        return 'Engine/Content/' + ref[8:]
    return None


def follow(path):
    """Follow rendering and skeletal data, not the gameplay or world graph."""
    return path.startswith(('Pal/Content/Pal/Model/', 'Pal/Content/Pal/Animation/', 'Pal/Content/Pal/Material/',
                            'Pal/Content/Pal/Texture/', 'Engine/Content/'))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('pal', nargs='?', help="internal name, as in the model's SK_<name> (e.g. KingWhale)")
    parser.add_argument('--list', action='store_true', help='list the internal names of pals with a model')
    parser.add_argument('--anims', help="animation set to use, for variants that share their base pal's (found automatically)")
    parser.add_argument('--pak', help='path to Pal-Windows.pak (the usual Steam locations are tried)')
    parser.add_argument('--repak', help='path to a repak binary (otherwise downloaded)')
    parser.add_argument('--out', default='.', help='folder for the zip (default: here)')
    args = parser.parse_args()
    if not args.pal and not args.list:
        parser.error('name a pal, or use --list')

    pak = Path(args.pak) if args.pak else next((p for p in DEFAULT_PAKS if p.is_file()), None)
    if not pak or not pak.is_file():
        sys.exit('Pal-Windows.pak not found; pass --pak <path>.')
    repak = find_repak(Path('sekhpet-tools'), args.repak)
    before = (pak.stat().st_size, pak.stat().st_mtime_ns)

    def run(*arguments):
        return subprocess.run([str(repak), *arguments], check=True, capture_output=True, text=True).stdout

    listing = run('list', str(pak)).splitlines()
    all_paths = set(listing)
    # SK_<name> in its own folder, or (some variants, such as Lyleen Noct's LilyQueen_Ice) in
    # its base pal's.
    models = sorted({m.group(1) for p in listing
                     if (m := re.match(MONSTER.format('Model') + r'[^/]+/SK_([^/]+)\.uasset$', p))})
    anim_sets = {m.group(1) for p in listing if (m := re.match(MONSTER.format('Animation') + r'([^/]+)/AS_', p))}
    if args.list:
        print('\n'.join(models))
        return

    name = args.pal
    if name not in models:
        near = [m for m in models if m.lower() == name.lower()]
        sys.exit(f'No model SK_{name}.' + (f' Did you mean {near[0]}?' if near else
                 ' Some paldeck entries use a differently named mesh; see PIPELINE.md, "No model folder".'))
    anims = args.anims or (name if name in anim_sets else
                           max((a for a in anim_sets if name.startswith(a + '_')), key=len, default=None))
    if not anims:
        sys.exit(f'{name} has no animation folder and no base pal to share one with; pass --anims.')

    with tempfile.TemporaryDirectory(prefix='sekhpet-extract-') as scratch:
        out = Path(scratch) / 'raw'
        selected, scanned = set(), set()

        def extract(paths, filters=None):
            assert paths and len(selected | paths) <= LIMIT_FILES, 'Dependency expansion needs review'
            command = ['unpack', str(pak), '-o', str(out), '-f', '-q']
            for pattern in filters or sorted(paths):
                command += ['-i', pattern]
            run(*command)
            selected.update(paths)
            total = sum((out / p).stat().st_size for p in selected)
            assert total <= LIMIT_BYTES, 'Extraction exceeded 512 MiB'
            print(f'Extracted {len(paths)} files ({len(selected)} so far, {total >> 20} MiB)', flush=True)

        # Everything named after the pal, plus the shared animation folder for variants.
        seeds = {p for p in all_paths if name.lower() in p.lower()}
        # repak's filters are case-sensitive; one namespace filter covers most seeds at once.
        extract(seeds, [f'**/*{name}*'] + sorted(p for p in seeds if name not in p))
        shared = {p for p in all_paths if p.startswith(MONSTER.format('Animation') + anims + '/')} - selected
        if shared:
            extract(shared)
        # Follow package references found in each package's name map.
        while True:
            pending = set()
            for path in sorted(p for p in selected - scanned if p.endswith('.uasset') and follow(p)):
                scanned.add(path)
                blob = (out / path).read_bytes()
                values = {x.decode('ascii') for x in re.findall(rb'[ -~]{6,}', blob)}
                values.update(x.decode('utf-16le') for x in re.findall(rb'(?:[ -~]\x00){6,}', blob))
                for ref in values:
                    target = package_path(ref.split('.')[0]) if ref.startswith(('/Game/', '/Engine/')) else None
                    if target:
                        pending.update({target + ext for ext in SIDECARS if target + ext in all_paths} - selected)
            if not pending:
                break
            extract(pending)

        tables = Path(scratch) / 'tables'
        run('unpack', str(pak), '-o', str(tables), '-f', '-q', *[x for t in TABLES for x in ('-i', t)])
        assert before == (pak.stat().st_size, pak.stat().st_mtime_ns), 'The pak changed during extraction'

        manifest = {'pal': name, 'animSet': anims, 'repak': REPAK, 'pakSize': before[0],
                    'files': {p: sha256(out / p) for p in sorted(selected)}}
        zip_path = Path(args.out) / f'{name}-extract.zip'
        with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as bundle:
            bundle.writestr('manifest.json', json.dumps(manifest, indent=1))
            bundle.writestr('paklist.txt', '\n'.join(listing) + '\n')
            for root in (out, tables):
                for file in sorted(root.rglob('*')):
                    if file.is_file():
                        bundle.write(file, f'{root.name}/{file.relative_to(root).as_posix()}')
    print(f'Wrote {zip_path} ({len(selected)} files; animations from {anims}). Copy it to the Mac and run '
          f'sources/palworld/make_pet.sh on it.')


if __name__ == '__main__':
    main()
