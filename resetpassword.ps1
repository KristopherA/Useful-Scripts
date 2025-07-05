param(
[string]$username,
[string]$newpassword
)

import-module activedirectory

Set-ADAccountPassword `
    -Identity $username `
    -Reset `
    -NewPassword (ConvertTo-SecureString -AsPlainText $newpassword -Force)