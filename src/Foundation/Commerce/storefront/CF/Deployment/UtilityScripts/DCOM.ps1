function New-DComAccessControlEntry
{
	param (
		[string] $Domain,
		[string] $Name,
		[UInt32] $AccessMask = 11, # Execute | Execute_Local | Activate_Local
		[string] $ComputerName = "."
	)
	<#
	.SYNOPSIS
	Creates a new DCOM access control entry.

	.DESCRIPTION
	This function creates a new access control entry for a DCOM application.

	.PARAMETER Domain
	Specifies the machine name or domain name.

	.PARAMETER ApplicationId
	Specifies the ID of the DCOM application.

	.PARAMETER AccessMask
	Specifies level of access to the DCOM application.  Execute =  1, Execute_Local =  2, Execute_Remote  =  4, Activate_Local  =  8, Activate_Remote = 16.  Defaults to Execute | Execute_Local | Activate_Local.

	.PARAMETER ComputerName
	Specifies the name of the system or domain on which the identity will be granted access.  Defaults to the local system (".").

	.EXAMPLE
	Set-DComAccessControl -Identity "MySystem\MyUser" -ApplicationId "guid"
	#>
 
	#Create the Trusteee Object
	$Trustee = ([WMIClass] "\\$ComputerName\root\cimv2:Win32_Trustee").CreateInstance();
 
	#Search for the user account
	$account = [WMI] "\\$ComputerName\root\cimv2:Win32_Account.Name='$Name',Domain='$Domain'";
 
	#Get the SID for the found account.
	$accountSID = [WMI] "\\$ComputerName\root\cimv2:Win32_SID.SID='$($account.sid)'";
 
	#Setup Trusteee object
	$Trustee.Domain = $Domain;
	$Trustee.Name = $Name;
	$Trustee.SID = $accountSID.BinaryRepresentation;
 
	#Create ACE (Access Control List) object.
	$ACE = ([WMIClass] "\\$ComputerName\root\cimv2:Win32_ACE").CreateInstance();
 
	# COM Access Mask
	#   Execute         =  1,
	#   Execute_Local   =  2,
	#   Execute_Remote  =  4,
	#   Activate_Local  =  8,
	#   Activate_Remote = 16
 
	#Setup the rest of the ACE.
	$ACE.AccessMask = $AccessMask;
	$ACE.AceFlags = 0;
	$ACE.AceType = 0; # Access allowed
	$ACE.Trustee = $Trustee;
	return $ACE;
}

function Set-DComAccessControl
{
	param (
		[string] $Identity,
		[string] $ApplicationId,
		[UInt32] $AccessMask = 11, # Execute | Execute_Local | Activate_Local
		[string] $ComputerName = "."
	)
	<#
	.SYNOPSIS 
	Sets access control permissions to a DCOM application.

	.DESCRIPTION
	This function grants a fully qualified identity, by namem, access to a DCOM application.

	.PARAMETER Identity
	Specifies identity that will be granted access to the DCOM application.

	.PARAMETER ApplicationId
	Specifies the ID of the DCOM application.

	.PARAMETER AccessMask
	Specifies level of access to the DCOM application.  Execute =  1, Execute_Local =  2, Execute_Remote  =  4, Activate_Local  =  8, Activate_Remote = 16.  Defaults to Execute | Execute_Local | Activate_Local.

	.PARAMETER ComputerName
	Specifies the name of the system or domain on which the identity will be granted access.  Defaults to the local system (".").

	.EXAMPLE
	Set-DComAccessControl -Identity "MySystem\MyUser" -ApplicationId "guid"
	#>

	$Domain = $Identity.Split("\")[0];
	$Name = $Identity.Split("\")[1];
	$dcom = Get-WMIObject Win32_DCOMApplicationSetting -Filter "AppId='$ApplicationId'" -EnableAllPrivileges;
	$sd = $dcom.GetLaunchSecurityDescriptor().Descriptor;
	$nsAce = $sd.Dacl | Where {$_.Trustee.Name -eq $Name};
	if ($nsAce)
	{
		$nsAce.AccessMask = $AccessMask;
	}
	else
	{
		$newAce = New-DComAccessControlEntry -Domain $Domain -Name $Name -AccessMask $AccessMask -ComputerName $ComputerName;
		$sd.Dacl += $newAce;
	}

	$dcom.SetLaunchSecurityDescriptor($sd);
}