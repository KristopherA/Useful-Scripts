param(
[string]$username,
[string]$firstname,
[string]$lastname
)

import-module activedirectory

Set-ADUser `
			-Identity $username `
            -GivenName $firstname `
            -Surname $lastname `
            -DisplayName "$lastname, $firstname" `
			-PassThru