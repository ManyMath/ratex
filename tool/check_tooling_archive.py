#!/usr/bin/env python3
"""Verify included Cargokit in an actual pub archive; not a native consumer gate."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile


def run(args, cwd, log):
    executable = shutil.which(args[0])
    if executable is None:
        raise RuntimeError(f'Missing provisioned tool: {args[0]}')
    result = subprocess.run([executable, *args[1:]], cwd=cwd, input='\n',
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            encoding='utf-8', errors='replace')
    log.write_text(result.stdout, encoding='utf-8')
    if result.returncode:
        raise RuntimeError(f'Command failed; see {log}')
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    version = run(['dart', '--version'], root, output / 'dart-version.log')
    if 'Dart SDK version: 3.13.2 ' not in version:
        raise RuntimeError('Pinned Dart 3.13.2 archive capability is required')
    archive_path = output / 'ratex.tar.gz'
    with tempfile.TemporaryDirectory(prefix='ratex-tooling-stage-') as temp:
        stage = Path(temp) / 'source'
        # Preserve publication selection, including ignored generated inputs.
        shutil.copytree(root, stage, symlinks=True,
                        ignore=lambda directory, names: ['.git'] if '.git' in names else [])
        subprocess.run(['git', 'init', '-q', str(stage)], check=True)
        run(['flutter', 'pub', 'get'], stage, output / 'pub-get.log')
        package = stage / 'packages/ratex'
        run(['dart', 'pub', 'publish', '--dry-run'], package, output / 'validation.log')
        run(['dart', 'pub', 'publish', f'--to-archive={archive_path}'], package, output / 'archive.log')
    with tarfile.open(archive_path) as archive:
        provenance_bytes = archive.extractfile('cargokit/VENDOR_PROVENANCE.json').read()
        if provenance_bytes != (root / 'packages/ratex/cargokit/VENDOR_PROVENANCE.json').read_bytes():
            raise RuntimeError('Published tooling provenance differs from the reviewed installed tree')
        provenance = json.loads(provenance_bytes)
        for name, expected in provenance['files_sha256'].items():
            actual = hashlib.sha256(archive.extractfile('cargokit/' + name).read()).hexdigest()
            if actual != expected:
                raise RuntimeError(f'Published Cargokit source drift: {name}')
        if archive.extractfile('LICENSE').read() != (root / 'LICENSE').read_bytes():
            raise RuntimeError('Published package license differs from the existing repository license')
    evidence = {'status': 'passed', 'scope': 'Cargokit tooling bytes and license in pub-selected archive only; native crate closure and consumer build not verified',
                'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
                'source_dirty': bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root)),
                'archive_sha256': hashlib.sha256(archive_path.read_bytes()).hexdigest(),
                'cargokit_revision': provenance['revision'], 'published_tooling_files': len(provenance['files_sha256'])}
    (output / 'evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    main()
