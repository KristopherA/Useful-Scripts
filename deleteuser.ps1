param(
[string]$username
)

import-module activedirectory

Remove-ADUser -Verbose `
    -Identity $username `
    -Confirm:$false