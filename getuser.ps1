param(
[string]$username
)

import-module activedirectory

Get-ADUser `
    -Identity $username