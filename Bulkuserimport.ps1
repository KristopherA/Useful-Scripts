# Import active directory module for running AD cmdlets
Import-Module activedirectory
  
#Store the data from ADUsers.csv in the $ADUsers variable
$ADUsers = Import-csv  C:\scripts\associates.csv

#Loop through each row containing user details in the CSV file 
foreach ($User in $ADUsers)
{
	#Read user data from each field in each row and assign the data to a variable as below
		
	
    $SAM = $User.SAM
    $UPN = $User.UPN
	$Firstname 	= $User.firstname
    #$Initials   = $User.initial
	$Lastname 	= $User.lastname
	$OU 		= $User.ou #This field refers to the OU the user account is to be created in
    $Password 	= $User.password

    $ErrorActionPreference = "SilentlyContinue"

	#Check to see if the user already exists in AD
	#if (Get-ADUser -F {SamAccountName -eq $SAM})
	#{
	     #If $SAM does exist, give a warning
		 #Write-Warning "A user account with username $SAM already exist in Active Directory."
	#}
	#else
	#{
		#User does not exist then proceed to create the new user account


        #Account will be created in the OU provided by the $OU variable read from the CSV file
		New-ADUser `
            -Name "$Firstname $Lastname" `
            -SamAccountName $SAM `
            -UserPrincipalName "$UPN@una.ca" `
            -GivenName $Firstname `
            -Surname $Lastname `
            -Enabled $True `
            -Path $OU `
            -PasswordNeverExpires $true `
            -AccountPassword (convertto-securestring $Password -AsPlainText -Force)
	#}
}
