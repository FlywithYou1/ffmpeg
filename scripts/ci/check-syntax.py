#!/usr/bin/env python3
"""Validate source scripts and embedded Actions shell blocks without a build."""
import ast
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def workflow_blocks(text):
    lines = text.splitlines()
    for i, line in enumerate(lines):
        match = re.match(r'^(\s*)run: \|\s*$', line)
        if not match:
            continue
        indent = len(match[1])
        body = []
        for following in lines[i + 1:]:
            if following.strip() and len(following) - len(following.lstrip()) <= indent:
                break
            body.append(following[indent + 2:])
        shell = 'bash'
        for previous in reversed(lines[:i]):
            shell_match = re.match(r'^\s*shell: (\S+)', previous)
            if shell_match:
                shell = shell_match[1]
            if re.match(r'^\s*- (name|uses):', previous):
                break
        source = re.sub(r'\$\{\{.*?\}\}', 'workflow_value', '\n'.join(body), flags=re.S)
        yield i + 1, shell, source


def check_powershell(executable, source, name):
    parser = '$t=$null; $e=$null; [System.Management.Automation.Language.Parser]::ParseInput([Console]::In.ReadToEnd(),[ref]$t,[ref]$e)|Out-Null; if($e.Count){$e|ForEach-Object {[Console]::Error.WriteLine($_.Message)};exit 1}'
    result = subprocess.run([executable, '-NoProfile', '-Command', parser], input=source.encode(), capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{name}: {result.stderr.decode(errors="replace")}')


def main():
    bash = shutil.which('bash')
    if not bash:
        raise RuntimeError('Bash is required for script syntax validation')
    pwsh = shutil.which('pwsh') or shutil.which('powershell')
    paths = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard'], cwd=ROOT, text=True).splitlines()
    count = 0
    for path in paths:
        file = ROOT / path
        if not file.is_file():
            continue
        if file.suffix not in {'.sh', '.ps1', '.py', '.json'}:
            continue
        source = file.read_text(encoding='utf-8-sig')
        if file.suffix == '.sh':
            subprocess.run([bash, '-n'], input=source.encode(), check=True)
        elif file.suffix == '.ps1':
            if pwsh:
                check_powershell(pwsh, source, path)
            else:
                print(f'Unavailable PowerShell syntax validation: {path}')
        elif file.suffix == '.py':
            ast.parse(source, filename=path)
        elif file.suffix == '.json':
            json.loads(source)
        count += 1
    for line, shell, source in workflow_blocks((ROOT / '.github/workflows/build-ffmpeg.yml').read_text()):
        if shell == 'pwsh':
            if pwsh:
                check_powershell(pwsh, source, f'workflow:{line}')
        elif shell == 'bash':
            subprocess.run([bash, '-n'], input=source.encode(), check=True)
        else:
            raise RuntimeError(f'Unrecognized workflow shell at {line}: {shell}')
        count += 1
    print(f'Syntax validated: {count} files/blocks')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
