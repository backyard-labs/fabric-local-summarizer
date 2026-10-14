# Running Reviewed PowerShell Scripts

A practical Windows reference for running PowerShell scripts you have reviewed and decided to trust, such as `Fabric-Summarize.ps1`.

**Security principle:** Unblocking a script removes an execution restriction. It does not establish that the script is safe.

## Recommended Workflow

### 1. Save the script

Keep scripts in a known directory, for example:

```text
C:\Users\<YourUsername>\scripts\PowerShell
```

### 2. Review the script before running it

Open the script in Visual Studio Code or inspect its contents:

```powershell
Get-Content -LiteralPath .\Fabric-Summarize.ps1
```

Look for unexpected downloads, external network connections, credential access, destructive commands, or changes to system settings.

If the script is digitally signed, inspect its signature:

```powershell
Get-AuthenticodeSignature -FilePath .\Fabric-Summarize.ps1
```

A valid signature can help establish integrity and signer identity when the publisher is trusted, but does not guarantee safe behavior.

### 3. Unblock only a reviewed file, if necessary

If a trusted downloaded script is blocked because of its Internet-zone marking:

```powershell
Unblock-File -LiteralPath .\Fabric-Summarize.ps1
```

**Security warning:** `Unblock-File` removes the file's `Zone.Identifier` security marker, commonly called the *Mark-of-the-Web*.

It does **not**:

- Scan the script for malware.
- Verify the script's authenticity or author.
- Validate its digital signature.
- Change the PowerShell execution policy.
- Establish that the script is safe.

Removing this marker may allow an unsigned script to execute under `RemoteSigned` when it would otherwise be blocked. Malicious instructions, if present, remain unchanged and may execute with the privileges of the account running the script.

**Only unblock a file after verifying its source and reviewing that specific version.** Do not unblock unfamiliar scripts simply to bypass an error.

### 4. Run the script normally

```powershell
.\Fabric-Summarize.ps1
```

Use a non-administrative PowerShell session unless elevated privileges are genuinely required.

## Diagnose a Script-Blocking Error

Check the effective execution policy and its scopes:

```powershell
Get-ExecutionPolicy
Get-ExecutionPolicy -List
```

Check whether the script has an Internet-zone marker:

```powershell
Get-Item -LiteralPath .\Fabric-Summarize.ps1 -Stream Zone.Identifier -ErrorAction SilentlyContinue
```

Common scenarios:

- **RemoteSigned:** An unsigned script marked as downloaded from the Internet may be blocked. After reviewing and trusting that file, `Unblock-File` can remove the marker without changing the execution policy.
- **AllSigned:** Scripts must satisfy the signature requirements. Unblocking does not remove this requirement.
- **Organization-managed policies:** Group Policy may override local settings. Do not attempt to circumvent managed restrictions; contact your administrator.

If unblocking does not resolve the error, investigate the effective policy and other applicable security controls.

## Security Practices for Scripts You Keep

- Keep reviewed scripts in a dedicated folder.
- Review scripts again when they are updated or replaced.
- Unblock individual reviewed files rather than entire folders.
- Avoid unnecessary administrator privileges.
- Avoid routine use of `-ExecutionPolicy Bypass`, `Unrestricted`, or broad execution-policy changes.
- Review external dependencies, network access, and file operations.

**PowerShell execution policies are not security boundaries.** They help prevent accidental execution of certain scripts but do not provide comprehensive protection against malicious code. Use additional safeguards such as endpoint protection, least privilege, trusted sources, and application controls where appropriate.

A command such as:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Fabric-Summarize.ps1
```

requests the `Bypass` policy for that PowerShell process, subject to higher-precedence policies. It does not permanently change the saved policy, but it reduces execution-policy checks for that process.

For scripts distributed across an organization, use approved code-signing and trusted-publisher processes.

## What Happened with Fabric-Summarize.ps1

During testing, the downloaded PowerShell script was blocked as unsigned.

After reviewing the script, we ran:

```powershell
Unblock-File -LiteralPath .\Fabric-Summarize.ps1
```

The script then executed normally:

```powershell
.\Fabric-Summarize.ps1
```

This resolved the observed issue without changing the configured execution policy.

No `ExecutionPolicy Bypass` was needed in this case. Future execution remains subject to the effective execution policy and other applicable security controls.

## Microsoft References

- [About Execution Policies](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_execution_policies)
- [Set-ExecutionPolicy](https://learn.microsoft.com/powershell/module/microsoft.powershell.security/set-executionpolicy)
- [Unblock-File](https://learn.microsoft.com/powershell/module/microsoft.powershell.utility/unblock-file)
- [About Signing](https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_signing)

## AI-Assisted Documentation Disclosure

This runbook was prepared with assistance from OpenAI's ChatGPT as part of the Fabric Local Summarizer project.

It provides general educational guidance and is not a substitute for organizational security policies or independent security review.

---

**Remember:** Review first. Verify the source. Unblock only when appropriate. Permission to execute a script is not proof that it is safe.