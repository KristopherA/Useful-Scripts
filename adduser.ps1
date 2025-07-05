param(
[string]$username,
[string]$password,
[string]$firstname,
[string]$lastname,
[string]$initial,
[string]$samname
)

import-module activedirectory

New-ADUser -Verbose `
            -SamAccountName $samname `
            -UserPrincipalName "$username@domain.com" `
            -Name "$samname" `
            -GivenName $firstname `
            -Initials $initial `
            -Surname $lastname `
            -DisplayName "$lastname, $firstname" `
            -AccountPassword (convertto-securestring $password -AsPlainText -Force) `
            -Path "CN=Users,DC=domain,DC=com" `
			-Enabled $True