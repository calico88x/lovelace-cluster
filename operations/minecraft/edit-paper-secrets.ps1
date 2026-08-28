#Requires -Version 7.0

<#
.SYNOPSIS
Interactively edits the SOPS-encrypted private settings for the Paper server.

.DESCRIPTION
The encrypted Secret is copied to Lovelace, decrypted only through an in-memory
pipeline, edited through /dev/tty, re-encrypted, verified, and copied back. The
age private key never leaves the cluster and plaintext is never written to disk.
#>

[CmdletBinding()]
param(
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RemoteHost = 'lovelace'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SecretRelativePath = 'apps/staging/minecraft/minecraft-private.sops.yaml'
$ExpectedSecretName = 'minecraft-private'
$ExpectedNamespace = 'minecraft'
$ServerLabel = 'Paper Minecraft'

function Assert-NativeSuccess {
    param([Parameter(Mandatory)][string]$Message)

    if ($LASTEXITCODE -ne 0) {
        throw "$Message (exit code $LASTEXITCODE)"
    }
}

foreach ($Command in @('ssh', 'scp', 'git')) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "Required command '$Command' was not found in PATH."
    }
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$SecretPath = Join-Path $RepoRoot $SecretRelativePath

if (-not (Test-Path -LiteralPath $SecretPath -PathType Leaf)) {
    throw "Encrypted Secret not found: $SecretPath"
}

$SourceHash = (Get-FileHash -LiteralPath $SecretPath -Algorithm SHA256).Hash
$RunId = [Guid]::NewGuid().ToString('N')
$LocalTemp = Join-Path ([IO.Path]::GetTempPath()) "minecraft-secrets-$RunId"
$LocalDriver = Join-Path $LocalTemp 'edit-secret.sh'
$LocalEditor = Join-Path $LocalTemp 'secret-editor.py'
$LocalResult = Join-Path $LocalTemp 'updated.sops.yaml'
$RepositoryStage = "$SecretPath.$RunId.new"
$RemoteDir = $null

$RemoteDriver = @'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

input_file=$1
output_file=$2
editor_file=$3
expected_name=$4
expected_namespace=$5

for command_name in sops kubectl python3 base64 awk tr; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command is missing on Lovelace: %s\n' "$command_name" >&2
    exit 10
  fi
done

if [[ ! -r "$input_file" ]]; then
  printf 'Encrypted input is not readable.\n' >&2
  exit 11
fi

mapfile -t recipients < <(
  awk '
    $1 == "recipient:" {gsub(/"/, "", $2); print $2}
    $1 == "-" && $2 == "recipient:" {gsub(/"/, "", $3); print $3}
  ' "$input_file" | tr -d '\r'
)
if (( ${#recipients[@]} == 0 )); then
  printf 'Could not determine the age recipient from the encrypted document.\n' >&2
  exit 12
fi

age_arguments=()
for recipient in "${recipients[@]}"; do
  if [[ ! "$recipient" =~ ^age1[0-9a-z]+$ ]]; then
    printf 'The encrypted document contains an invalid age recipient.\n' >&2
    exit 12
  fi
  age_arguments+=(--age "$recipient")
done

# SOPS invokes this command only when it needs the identity. The age key stays
# inside the cluster and is never placed in a workstation file or argument.
export SOPS_AGE_KEY_CMD="kubectl -n flux-system get secret sops-age -o jsonpath='{.data.age\\.agekey}' | base64 -d"

printf 'Verifying encrypted input and SOPS access...\n'
sops decrypt "$input_file" >/dev/null

temporary_output="${output_file}.new"
encryption_error="${output_file}.sops-error"
trap 'rm -f -- "$temporary_output" "$encryption_error"' EXIT

set +e
sops decrypt --output-type json "$input_file" |
  python3 "$editor_file" "$expected_name" "$expected_namespace" |
  sops encrypt \
    "${age_arguments[@]}" \
    --encrypted-regex '^(data|stringData)$' \
    --input-type json \
    --output-type yaml \
    /dev/stdin >"$temporary_output" 2>"$encryption_error"
pipeline_status=("${PIPESTATUS[@]}")
set -e

if (( pipeline_status[1] == 20 )); then
  exit 20
fi

for status in "${pipeline_status[@]}"; do
  if (( status != 0 )); then
    if [[ -s "$encryption_error" ]]; then
      cat "$encryption_error" >&2
    fi
    printf 'The edit/encryption pipeline failed; no output was accepted.\n' >&2
    exit 13
  fi
done

rm -f -- "$encryption_error"

chmod 600 "$temporary_output"
mv -- "$temporary_output" "$output_file"

printf 'Verifying encrypted output and expected Kubernetes metadata...\n'
sops decrypt --output-type json "$output_file" |
  python3 "$editor_file" --validate-only "$expected_name" "$expected_namespace"
sops decrypt "$output_file" >/dev/null

printf 'Encrypted update verified successfully.\n'
'@

$RemoteEditor = @'
#!/usr/bin/env python3
"""TTY editor for a decrypted Kubernetes Secret received through stdin."""

import json
import re
import sys
import termios

EDITABLE_KEYS = ("RCON_PASSWORD", "SEED", "WHITELIST", "OPS")
USERNAME_PATTERN = re.compile(r"^[A-Za-z0-9_]{3,16}$")
CANCEL_EXIT = 20


def validate_document(document, expected_name, expected_namespace):
    if document.get("apiVersion") != "v1" or document.get("kind") != "Secret":
        raise ValueError("the decrypted document is not a v1 Kubernetes Secret")

    metadata = document.get("metadata")
    if not isinstance(metadata, dict):
        raise ValueError("the Secret has no metadata mapping")
    if metadata.get("name") != expected_name:
        raise ValueError(
            f"expected Secret name {expected_name!r}, found {metadata.get('name')!r}"
        )
    if metadata.get("namespace") != expected_namespace:
        raise ValueError(
            "expected namespace "
            f"{expected_namespace!r}, found {metadata.get('namespace')!r}"
        )

    values = document.get("stringData")
    if not isinstance(values, dict):
        raise ValueError("the Secret must store editable values under stringData")

    missing = [key for key in EDITABLE_KEYS if key not in values]
    if missing:
        raise ValueError("the Secret is missing required keys: " + ", ".join(missing))

    for key in EDITABLE_KEYS:
        if not isinstance(values[key], str):
            raise ValueError(f"{key} must be a string")

    return values


def split_names(raw_value):
    names = []
    seen = set()
    for candidate in re.split(r"[,\r\n]+", raw_value):
        name = candidate.strip()
        if not name:
            continue
        folded = name.casefold()
        if folded not in seen:
            names.append(name)
            seen.add(folded)
    return names


def validate_names(names):
    invalid = [name for name in names if not USERNAME_PATTERN.fullmatch(name)]
    if invalid:
        raise ValueError(
            "invalid Minecraft Java username(s): "
            + ", ".join(invalid)
            + " (use 3-16 letters, digits, or underscores)"
        )


class Terminal:
    def __init__(self):
        self.reader = open("/dev/tty", "r", encoding="utf-8", buffering=1)
        self.writer = open("/dev/tty", "w", encoding="utf-8", buffering=1)

    def close(self):
        self.reader.close()
        self.writer.close()

    def write(self, message=""):
        self.writer.write(message + "\n")
        self.writer.flush()

    def prompt(self, message):
        self.writer.write(message)
        self.writer.flush()
        response = self.reader.readline()
        if response == "":
            raise EOFError("terminal input closed")
        return response.rstrip("\r\n")

    def confirm(self, message, default=False):
        suffix = " [Y/n]: " if default else " [y/N]: "
        answer = self.prompt(message + suffix).strip().casefold()
        if not answer:
            return default
        return answer in {"y", "yes"}

    def secret_prompt(self, message):
        descriptor = self.reader.fileno()
        original = termios.tcgetattr(descriptor)
        hidden = termios.tcgetattr(descriptor)
        hidden[3] &= ~termios.ECHO
        self.writer.write(message)
        self.writer.flush()
        try:
            termios.tcsetattr(descriptor, termios.TCSADRAIN, hidden)
            response = self.reader.readline()
            if response == "":
                raise EOFError("terminal input closed")
            return response.rstrip("\r\n")
        finally:
            termios.tcsetattr(descriptor, termios.TCSADRAIN, original)
            self.writer.write("\n")
            self.writer.flush()


def show_names(terminal, title, names):
    terminal.write(f"\n{title} ({len(names)})")
    terminal.write("-" * 48)
    if not names:
        terminal.write("  <empty>")
        return
    for index, name in enumerate(names, start=1):
        terminal.write(f"  {index:>2}. {name}")


def manage_names(terminal, values, key, title):
    changed = False
    while True:
        names = split_names(values[key])
        show_names(terminal, title, names)
        terminal.write("\n  1. Add names")
        terminal.write("  2. Remove names")
        terminal.write("  3. Replace the complete list")
        terminal.write("  4. Clear the list")
        terminal.write("  5. Back")
        choice = terminal.prompt("Select: ").strip()

        try:
            if choice == "1":
                additions = split_names(
                    terminal.prompt("Names to add (comma-separated): ")
                )
                validate_names(additions)
                existing = {name.casefold() for name in names}
                added = [name for name in additions if name.casefold() not in existing]
                if added:
                    names.extend(added)
                    values[key] = ",".join(names)
                    changed = True
                    terminal.write(f"Added {len(added)} name(s).")
                else:
                    terminal.write("No new names were added.")

            elif choice == "2":
                if not names:
                    terminal.write("The list is already empty.")
                    continue
                raw = terminal.prompt(
                    "Names or list numbers to remove (comma-separated): "
                )
                tokens = [part.strip() for part in raw.split(",") if part.strip()]
                remove_indexes = set()
                remove_names = set()
                for token in tokens:
                    if token.isdigit() and 1 <= int(token) <= len(names):
                        remove_indexes.add(int(token) - 1)
                    else:
                        remove_names.add(token.casefold())
                updated = [
                    name
                    for index, name in enumerate(names)
                    if index not in remove_indexes and name.casefold() not in remove_names
                ]
                removed = len(names) - len(updated)
                if removed:
                    values[key] = ",".join(updated)
                    changed = True
                    terminal.write(f"Removed {removed} name(s).")
                else:
                    terminal.write("No matching names were found.")

            elif choice == "3":
                replacement = split_names(
                    terminal.prompt("Complete replacement list (comma-separated): ")
                )
                validate_names(replacement)
                if terminal.confirm(
                    f"Replace the complete {title.lower()} with {len(replacement)} name(s)?"
                ):
                    serialized = ",".join(replacement)
                    if serialized != values[key]:
                        values[key] = serialized
                        changed = True
                    terminal.write("List replaced.")

            elif choice == "4":
                if names and terminal.confirm(f"Clear the complete {title.lower()}?"):
                    values[key] = ""
                    changed = True
                    terminal.write("List cleared.")
                elif not names:
                    terminal.write("The list is already empty.")

            elif choice == "5":
                return changed
            else:
                terminal.write("Choose 1 through 5.")
        except ValueError as error:
            terminal.write(f"Error: {error}")


def show_current(terminal, values):
    terminal.write("\nCurrent private server settings")
    terminal.write("=" * 48)
    terminal.write(f"SEED: {values['SEED'] if values['SEED'] else '<empty>'}")
    password = values["RCON_PASSWORD"]
    terminal.write(
        "RCON_PASSWORD: "
        + (f"<set, {len(password)} characters>" if password else "<empty>")
    )
    show_names(terminal, "WHITELIST", split_names(values["WHITELIST"]))
    show_names(terminal, "OPS", split_names(values["OPS"]))
    if password and terminal.confirm("Reveal RCON_PASSWORD on screen?"):
        terminal.write(f"RCON_PASSWORD: {password}")


def edit_seed(terminal, values):
    terminal.write(f"\nCurrent SEED: {values['SEED'] if values['SEED'] else '<empty>'}")
    terminal.write("Enter /clear to remove it; leave blank to keep it unchanged.")
    replacement = terminal.prompt("New SEED: ")
    if replacement == "":
        terminal.write("SEED unchanged.")
        return False
    if replacement.casefold() == "/clear":
        replacement = ""
    if "\n" in replacement or "\r" in replacement:
        terminal.write("SEED cannot contain a newline.")
        return False
    if replacement == values["SEED"]:
        terminal.write("SEED unchanged.")
        return False
    values["SEED"] = replacement
    terminal.write("SEED updated.")
    return True


def edit_password(terminal, values):
    terminal.write("\nThe password will not be echoed or stored in shell history.")
    first = terminal.secret_prompt("New RCON_PASSWORD (blank cancels): ")
    if not first:
        terminal.write("RCON_PASSWORD unchanged.")
        return False
    second = terminal.secret_prompt("Confirm RCON_PASSWORD: ")
    if first != second:
        terminal.write("Passwords did not match; no change was made.")
        return False
    if first == values["RCON_PASSWORD"]:
        terminal.write("RCON_PASSWORD unchanged.")
        return False
    values["RCON_PASSWORD"] = first
    terminal.write("RCON_PASSWORD updated.")
    return True


def interactive_edit(document, expected_name, expected_namespace):
    values = validate_document(document, expected_name, expected_namespace)
    terminal = Terminal()
    dirty = False
    try:
        terminal.write("")
        terminal.write(f"Minecraft private settings: {expected_namespace}/{expected_name}")
        terminal.write("Plaintext remains in memory on Lovelace; only encrypted YAML returns.")

        while True:
            terminal.write("\nMain menu")
            terminal.write("=" * 48)
            terminal.write("  1. View current values")
            terminal.write("  2. Manage WHITELIST")
            terminal.write("  3. Manage OPS")
            terminal.write("  4. Change or clear SEED")
            terminal.write("  5. Change RCON_PASSWORD")
            terminal.write("  6. Save encrypted update")
            terminal.write("  7. Cancel without changes")
            choice = terminal.prompt("Select: ").strip()

            if choice == "1":
                show_current(terminal, values)
            elif choice == "2":
                dirty = manage_names(terminal, values, "WHITELIST", "WHITELIST") or dirty
            elif choice == "3":
                dirty = manage_names(terminal, values, "OPS", "OPS") or dirty
            elif choice == "4":
                dirty = edit_seed(terminal, values) or dirty
            elif choice == "5":
                dirty = edit_password(terminal, values) or dirty
            elif choice == "6":
                if not dirty:
                    terminal.write("No values changed; nothing will be written.")
                    raise SystemExit(CANCEL_EXIT)
                if terminal.confirm("Encrypt and replace the local repository file?"):
                    terminal.write("Encrypting and verifying update...")
                    json.dump(document, sys.stdout, separators=(",", ":"))
                    sys.stdout.write("\n")
                    sys.stdout.flush()
                    return
            elif choice == "7":
                if not dirty or terminal.confirm("Discard all changes?"):
                    terminal.write("Canceled; the repository file was not changed.")
                    raise SystemExit(CANCEL_EXIT)
            else:
                terminal.write("Choose 1 through 7.")
    finally:
        terminal.close()


def main():
    validate_only = len(sys.argv) == 4 and sys.argv[1] == "--validate-only"
    if validate_only:
        expected_name, expected_namespace = sys.argv[2:4]
    elif len(sys.argv) == 3:
        expected_name, expected_namespace = sys.argv[1:3]
    else:
        print("invalid editor invocation", file=sys.stderr)
        return 2

    try:
        document = json.load(sys.stdin)
        if validate_only:
            validate_document(document, expected_name, expected_namespace)
        else:
            interactive_edit(document, expected_name, expected_namespace)
        return 0
    except SystemExit as exit_signal:
        return int(exit_signal.code)
    except Exception as error:
        print(f"Secret editor failed: {error}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
'@

New-Item -ItemType Directory -Path $LocalTemp -ErrorAction Stop | Out-Null

try {
    # PowerShell scripts may use CRLF, but the uploaded Unix helpers must not.
    $Utf8NoBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText($LocalDriver, ($RemoteDriver -replace "`r`n", "`n"), $Utf8NoBom)
    [IO.File]::WriteAllText($LocalEditor, ($RemoteEditor -replace "`r`n", "`n"), $Utf8NoBom)

    Write-Host "Connecting to $RemoteHost for $ServerLabel secret editing..."
    $RemoteDir = (& ssh -T $RemoteHost 'mktemp -d /tmp/minecraft-secrets-XXXXXXXX').Trim()
    Assert-NativeSuccess 'Could not create a protected temporary directory on Lovelace'

    if ($RemoteDir -notmatch '^/tmp/minecraft-secrets-[A-Za-z0-9]+$') {
        throw "Lovelace returned an unexpected temporary path: $RemoteDir"
    }

    & scp $SecretPath "${RemoteHost}:${RemoteDir}/input.sops.yaml"
    Assert-NativeSuccess 'Could not copy the encrypted Secret to Lovelace'
    & scp $LocalDriver $LocalEditor "${RemoteHost}:${RemoteDir}/"
    Assert-NativeSuccess 'Could not copy the protected editor to Lovelace'

    $RemoteCommand = "chmod 700 '$RemoteDir/edit-secret.sh' '$RemoteDir/secret-editor.py'; " +
        "'$RemoteDir/edit-secret.sh' '$RemoteDir/input.sops.yaml' " +
        "'$RemoteDir/updated.sops.yaml' '$RemoteDir/secret-editor.py' " +
        "'$ExpectedSecretName' '$ExpectedNamespace'"

    & ssh -tt $RemoteHost $RemoteCommand
    $RemoteExitCode = $LASTEXITCODE

    if ($RemoteExitCode -eq 20) {
        Write-Host 'No changes were written.'
        return
    }
    if ($RemoteExitCode -ne 0) {
        throw "Remote secret editing failed (exit code $RemoteExitCode); the repository file is unchanged."
    }

    & scp "${RemoteHost}:${RemoteDir}/updated.sops.yaml" $LocalResult
    Assert-NativeSuccess 'Could not copy the encrypted result from Lovelace'

    if (-not (Test-Path -LiteralPath $LocalResult -PathType Leaf) -or
        (Get-Item -LiteralPath $LocalResult).Length -eq 0) {
        throw 'The encrypted result is missing or empty.'
    }

    $EncryptedText = Get-Content -LiteralPath $LocalResult -Raw
    if ($EncryptedText -notmatch '(?m)^sops:\s*$' -or
        $EncryptedText -notmatch 'ENC\[AES256_GCM') {
        throw 'The returned file does not look like a SOPS-encrypted document.'
    }
    if ($EncryptedText -notmatch "(?m)^\s+name:\s+$([regex]::Escape($ExpectedSecretName))\s*$" -or
        $EncryptedText -notmatch "(?m)^\s+namespace:\s+$([regex]::Escape($ExpectedNamespace))\s*$") {
        throw 'The returned Secret metadata does not match this script target.'
    }

    $CurrentHash = (Get-FileHash -LiteralPath $SecretPath -Algorithm SHA256).Hash
    if ($CurrentHash -ne $SourceHash) {
        throw 'The repository Secret changed while the editor was open; refusing to overwrite it.'
    }

    # Stage beside the destination so the final replacement stays on the same
    # filesystem and does not inherit temporary-directory permissions.
    Copy-Item -LiteralPath $LocalResult -Destination $RepositoryStage
    Move-Item -LiteralPath $RepositoryStage -Destination $SecretPath -Force

    & git -C $RepoRoot diff --check -- $SecretRelativePath
    Assert-NativeSuccess 'The updated file failed git diff --check'

    Write-Host "`nUpdated and verified: $SecretRelativePath" -ForegroundColor Green
    Write-Host 'The file remains encrypted. Review and commit it through the normal GitOps workflow.'
    & git -C $RepoRoot status --short -- $SecretRelativePath
}
finally {
    if ($RemoteDir -and $RemoteDir -match '^/tmp/minecraft-secrets-[A-Za-z0-9]+$') {
        $CleanupCommand = "rm -rf -- '$RemoteDir'"
        & ssh -T $RemoteHost $CleanupCommand 2>$null | Out-Null
    }
    if (Test-Path -LiteralPath $LocalTemp) {
        Remove-Item -LiteralPath $LocalTemp -Recurse -Force
    }
    if (Test-Path -LiteralPath $RepositoryStage) {
        Remove-Item -LiteralPath $RepositoryStage -Force
    }
}
