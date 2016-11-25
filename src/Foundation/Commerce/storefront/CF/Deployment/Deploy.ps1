#Requires -Version 3
$ErrorActionPreference = "Stop";
Set-PSDebug -Strict;
$Error.Clear();

function Expand-String([string] $source)
{
    $source = (($source -replace '&quot;', '`"') -replace '''', '`''');
    if ($PSVersionTable.PSVersion -eq '2.0') {        
        $target = $ExecutionContext.InvokeCommand.ExpandString($source);
    } else {
        
        try {
            # If the source string contains a Powershell expression, we have to use Invoke-Expression because ExpandString is broken in PS v3.0
            if($source.StartsWith('$(') -and $source.EndsWith(')')) {
                Write-Host "Calling Invoke-Expession " $source -ForegroundColor DarkGreen;
                $target = Invoke-Expression $source;
            }
		    else {
                $target =  $ExecutionContext.InvokeCommand.ExpandString($source);
            }
        }
        catch {
            Write-Host 'Assuming $source is a plain old string -> value: ' $source -ForegroundColor DarkGreen;
            $target = $ExecutionContext.InvokeCommand.ExpandString($source);
        }        
    }    
    Write-Host '$target set to ' $target -ForegroundColor Green;
    return $target;
} 

function Get-FullUserName
(
	[string]$userId,
	$configuration
)
{
	$domain = $(($configuration.UserAccounts.UserAccount | where { $_.identity -ieq $userId }).domain);
	$userName = $(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq $userId }).userName);
	
	return "$($domain)\$($userName)";
}

function New-Feature()
{
  param (
  [string] $identity, 
  [bool] $deleteIfExists,
  [bool] $reactivate,
  [bool] $activateUsingHttpGet
  )

  $feature = new-object PSObject

  $feature | add-member -type NoteProperty -Name identity -Value $identity
  $feature | add-member -type NoteProperty -Name deleteIfExists -Value $deleteIfExists
  $feature | add-member -type NoteProperty -Name reactivate -Value $reactivate
  $feature | add-member -type NoteProperty -Name activateUsingHttpGet -Value $activateUsingHttpGet
  
  return $feature
}

$DEPLOYMENT_DIRECTORY=(Split-Path -Path $MyInvocation.MyCommand.Definition -Parent);

. ( Join-Path -Path $DEPLOYMENT_DIRECTORY -ChildPath "UtilityScripts\CommerceServer-Configure.ps1");
. ( Join-Path -Path $DEPLOYMENT_DIRECTORY -ChildPath "UtilityScripts\IIS.ps1");
. ( Join-Path -Path $DEPLOYMENT_DIRECTORY -ChildPath "UtilityScripts\Windows.ps1");
. ( Join-Path -Path $DEPLOYMENT_DIRECTORY -ChildPath "UtilityScripts\File.ps1");
. ( Join-Path -Path $DEPLOYMENT_DIRECTORY -ChildPath "UtilityScripts\SQL.ps1");
. ( Join-Path -Path $DEPLOYMENT_DIRECTORY -ChildPath "UtilityScripts\zip.ps1");


<#
.Synopsis
	Using the Environment.xml file, create a Commerce Server site
.Description
	
.Example
	Deploy-CommerceServer -ConfigurationIdentity "Domain.Dev.Unpup" -PreCompile;
	Runs the Domain.Dev.Unpup configuration and all actions that normally happen under preCompile
.Example
	Deploy-CommerceServer -ConfigurationIdentities @("Domain.Dev.Unpup","Domain.Dev")
	Runs the Domain.Dev.Unpup and Domain.Dev configurations
.Parameter Precompile
	Runs precompile for the solution.
.Parameter Postcompile
	Runs postcompile for the solution.	
.Parameter ConfigurationIdentities
	An array of strings that coorespond to one or more of the identity attributes of the <Configurations><Configuration> node of the Environment.xml.
#>
function Deploy-CommerceServer
(
	[switch]$Precompile = $false,
	[switch]$Postcompile = $false,
	[switch]$GenerateWSP = $false,
	[switch]$Debug=$false,
	[switch]$SP2013=$false,
	[string]$ConfigurationIdentity="Domain.Dev",
	$DeploymentIdentities=@()
)
{
	# if COMMERCE_SERVER_ROOT is not defined we should not do anything
	if(((Test-Path Env:\COMMERCE_SERVER_ROOT) -eq $false) -or ($($env:COMMERCE_SERVER_ROOT) -eq $null) -or ($($env:COMMERCE_SERVER_ROOT) -eq "")){

		Write-Host "The COMMERCE_SERVER_ROOT environmental variable has not been definied, please ensure Commerce Server is installed and the variable is registed. If it is installed try closing and re-opening all Powershell and Command windows, if this does not work you may need to reboot this machine." -ForegroundColor Red;
		exit 1;
	}

	#Clear-Host;
	
	$scriptStartDate = Get-Date;
	$transactionLogPath = ( Join-Path -Path $DEPLOYMENT_DIRECTORY -ChildPath "Deploy-CommerceServer.log" );
	$success = "FAILED";

	try
	{
        try {
		    Start-Transcript -Force -Path $transactionLogPath -Debug -Confirm:$false -ErrorAction SilentlyContinue;
        }
        catch { 
            # to allow hosts which do not support transcription, you must catch terminating errors ... -ErrorAction SilentlyContinue doesn't work
        }

		Write-Host "Script started @ $($scriptStartDate).";

		Clear-EventLog -LogName "Application";
		Clear-EventLog -LogName "System";
		Clear-EventLog -LogName "Windows PowerShell";

		Write-Host "Restarting IIS";
		#IISRESET
		
		$environmentXml = [xml]( Get-Content -Path ( Join-Path -Path $DEPLOYMENT_DIRECTORY -ChildPath "Environment.xml" ) );

		$configuration = $environmentXml.CommerceServer.Configurations.Configuration | where { $_.identity -ieq $ConfigurationIdentity };
		if( $configuration )
		{
			Write-Host "Using configuration $($configuration.identity)";

			Write-Host "Loading variables";
			
			$variables = $configuration.SelectNodes("Variables/Variable");

			foreach( $variable in $variables )
			{
                $variableValue = Expand-String $variable.value

                Write-Host "$($variable.identity) =" $variableValue -ForegroundColor Green;			
				Set-Variable -Name $variable.identity -Value $variableValue -Scope Global;
			}
            foreach( $node in $configuration.SelectNodes( ".//*" ) )
			{
				foreach( $attribute in $node.Attributes )
				{
                    # The act of expanding the string here will have side-effects of evaluating $($variable)) and $env:variables.
					$attribute.Value = Expand-String $attribute.Value
				}
			}
		}
		else
		{
			Write-Error "No configuration with the identity $($ConfigurationIdentity) was found in the Environment.xml file.";
		}

		#Get-Variable | ft Name, Value -auto
		Write-Host "Writing complete variable list..." -ForegroundColor Green;
		Get-Variable | out-default;

		if( $Precompile )
		{
            $iisVersion = Get-ItemProperty "HKLM:\software\microsoft\InetStp";
            $iis8 = $false;
            # Windows Server 2008
            if ($iisVersion.MajorVersion -eq 7 -and $iisVersion.MinorVersion -lt 5 -and (-not (Get-PSSnapIn | Where {$_.Name -eq "WebAdministration";})) ) {
                Add-PSSnapIn WebAdministration;                
            }
            else # Windows Server 2008 R2 (IIS 7.5) and Windows 8 (IIS 8)
            {
                Import-Module WebAdministration;
                $iis8 = $true;
            }
			
			if((Get-WebItemState 'IIS:\Sites\Default Web Site' -Protocol http).Value -eq 'Started')
			{
				Stop-Website -Name "Default Web Site";
			}
			
			if($configuration.UserGroups -and $configuration.UserGroups.UserGroup){
			
				Write-Host "Adding users to groups..." -ForegroundColor Green;
				
				$userGroups = $configuration.UserGroups.SelectNodes("UserGroup");
				
				foreach( $userGroup in $userGroups )
				{
					if($userGroup.Users.User){
						$users = $userGroup.Users.SelectNodes("User");
						
						foreach( $user in $users )
						{						
							$actualUser = $configuration.UserAccounts.UserAccount | where { $_.identity -ieq $($user.userAccountIdentity) }
							Write-Host "`$user.userAccountIdentity = $($user.userAccountIdentity)";
							Windows-AddUserToLocalGroup -LocalGroupName $userGroup.name -UserName "$($actualUser.domain)\$($actualUser.username)" -Password $actualUser.password;
						}
					}
				}
			}		
			
			if($configuration.Events -and $configuration.Events.Definition){
			
				Write-Host "Registering new events for the event log..." -ForegroundColor Green;
				
				$events = $configuration.Events.SelectNodes("Definition");
				
				foreach( $event in $events )
				{
					Add-NewEventLogSource $event.EventSource;
				}
			}			
			
            if($configuration.IIS){
				# IIS Sites
				if( $configuration.IIS.Websites -and $configuration.IIS.Websites.Website ){
					$websites = $configuration.IIS.SelectNodes("Websites/Website");
					
					Write-Host "Creating sites..." -ForegroundColor Green;
					foreach( $website in $websites )
					{
						Write-Host "Working on $($website.identity) site..." -ForegroundColor Yellow;
						$siteInstance = Get-WebSite | where { $_.Name -eq $($website.identity) };

						if($siteInstance -ne $null){
							if($website.deleteIfExists -eq "true"){
								Write-Host "Site $($website.identity) exists, deleting...";

								Remove-Item "IIS:\Sites\$($website.identity)" -recurse;

								$siteInstance = $null;
							}
						}
						else{
							Write-Host "Site $($website.identity) does not exist.";
						}

						if($siteInstance -eq $null)
						{
							if($website.create -eq "true"){
								Write-Host "Site $($website.identity) does not exist, creating...";
                                
                                $physicalPath = $website.path;
                                Write-Host "Physical Path: " $physicalPath -ForegroundColor Green;
                                $siteIdentity = $website.identity;
                                Write-Host "Site identity: " $siteIdentity -ForegroundColor Green;
                                $protocol = $($website.protocol);
                                # Null or empty = http
                                $protocol = @{$true=$protocol;$false="http"}[$protocol -ne $null -and $protocol -ne ""];                               
                                Write-Host "Protocol: " $protocol;
                                $ssl = @{$true=$true;$false=$false}[$protocol -eq "https"];
                                Write-Host "SSL: " $ssl;
                                $port = $website.port;
                                Write-Host "Port: " $port;
                                
                                # On Windows 8, there is no protocol property on the website object.
                                if($iis8) {
                                    # must create the -PhysicalPath if it does not exist
                                    if(-not (Test-Path -Path $physicalPath)) {
                                        New-Item -Path $physicalPath -ItemType Directory;
                                    }

                                    if($ssl) {
                                        $siteInstance = New-Website $siteIdentity -PhysicalPath $physicalPath -Ssl -Port $port;
                                        #New-WebBinding -Name $siteIdentity -Port 443 -Protocol https;
                                    } else {
                                        $siteInstance = New-Website $siteIdentity -PhysicalPath $physicalPath -Port $port;
                                        #New-WebBinding -Name $siteIdentity -Port $port -Protocol http;
                                    }
                                                                        
                                }
                                else {
								    $siteInstance = New-Item IIS:\Sites\CFCSServices -PhysicalPath c:\inetpub\cfcsservices -bindings @{protocol="$($website.protocol)";bindingInformation="*:$($website.port):"};
                                }
							
                                Assign-AppPoolToSite $configuration $website.applicationPool $siteIdentity;
							}
							else{
								Write-Host "Will not create $($website.identity).";
							}
						}
						
						if($siteInstance -and $website.VirtualDirectories -and $website.VirtualDirectories.VirtualDirectory){
							$vds = $website.SelectNodes("VirtualDirectories/VirtualDirectory");
							
							foreach($vd in $vds){
								$vdInstance = Get-ChildItem "IIS:\Sites\$($website.identity)" | where { $_.Name -eq $($vd.identity) };
								
								if($vdInstance -ne $null){
									if($vd.deleteIfExists -eq "true"){
										Write-Host "Virtual Directory $($vd.identity) exists, deleting...";

										Remove-Item "IIS:\Sites\$($website.identity)\$($vd.identity)" -recurse;

										$vdInstance = $null;
									}
									else{
										Write-Host "Virtual Directory $($vd.identity) exists.";
									}
								}
								
								if($vdInstance -eq $null)
								{
									if($vd.create -eq "true"){
										Write-Host "Creating Virtual Directory $($vd.identity)";
										
										if($vd.applicationPool -ne $null){
											$vdInstance = New-Item "IIS:\Sites\$($website.identity)\$($vd.identity)" -Type Application -PhysicalPath "$($vd.path)";
										
											Write-Host "Creating app pool $($vd.applicationPool) with $($website.identity)\$($vd.identity)";
											Assign-AppPoolToSite $configuration $vd.applicationPool "$($website.identity)\$($vd.identity)" $true;
										}
										else{
											$vdInstance = New-Item "IIS:\Sites\$($website.identity)\$($vd.identity)" -Type VirtualDirectory -PhysicalPath "$($vd.path)";
										}
									}
								}						
							}
						}
						else{
							Write-Host "$($website.identity) does not exist so cannot create virtual directories." -ForegroundColor Yellow;
						}
						
						if($siteInstance -ne $null)
						{
							if($website.changeAppPool -eq "true")
							{
								Write-Host "Changing the appPool of $($website.identity) to $($website.applicationPool)." -ForegroundColor Green;
								Assign-AppPoolToSite $configuration $website.applicationPool $website.identity;
							}
						}
					}
				
					Write-Host "Done." -ForegroundColor Yellow;
				}
				
				# IIS Certificates
				if( $configuration.IIS.Certificates -and $configuration.IIS.Certificates.Certificate ){
					$certificates = $configuration.IIS.SelectNodes("Certificates/Certificate");
					
					Write-Host "Importing certificates..." -ForegroundColor Green;
					foreach( $iisCertificate in $certificates )
					{
						$cert = ( Get-ChildItem -Path "cert:\localmachine\MY" | where { $_.FriendlyName -ieq $iisCertificate.identity -or $_.Subject -ieq "CN=$($iisCertificate.identity)" });

						if( $cert -ne $null )
						{
							Write-Host "Deleting pre-existing certificate: $($iisCertificate.identity)";
							
							$store = New-Object System.Security.Cryptography.X509Certificates.X509Store "My", "localmachine"
							$store.Open("ReadWrite")
							$store.Remove($cert)
							$store.Close()
						}

						if($iisCertificate.selfSigned -and $iisCertificate.selfSigned -eq "true"){
							Create-SelfSignedCert $iisCertificate.identity;
							continue;
						}
						
						Write-Host "Importing $($iisCertificate.identity)";
						$certPath = $iisCertificate.path;
						
						Import-IIS7PfxCertificate -certPath "$certPath" -pfxPass $iisCertificate.password;
					}
				
					Write-Host "Done." -ForegroundColor Yellow;
				}

				# IIS Bindings
				if( $configuration.IIS.WebBindings -and $configuration.IIS.WebBindings.WebBinding )
				{
					Write-Host "Importing IIS bindings...";
							
					foreach( $iisWebBinding in $configuration.IIS.WebBindings.WebBinding )
					{
						Import-Module -Name WebAdministration;
																
						$existingBindingConfig = "$($iisWebBinding.ip):$($iisWebBinding.port):$($iisWebBinding.hostheader)";
						$existingBinding = Get-WebBinding | where {$_.bindingInformation -eq $existingBindingConfig -and $_.protocol -eq "$($iisWebBinding.protocol)"};							
								
						if($existingBinding -ne $null){
							Write-Host "Deleting already existing binding $($existingBindingConfig )";
							(Get-WebBinding | where {$_.bindingInformation -eq $existingBindingConfig -and $_.protocol -eq "$($iisWebBinding.protocol)"}) | Remove-WebBinding;
						}
						else{
							Write-Host "A binding with this config does not already exist: $($existingBindingConfig)";
						}
								
						Write-Host "Creating an IIS binding";
						New-WebBinding -Name $iisWebBinding.webApplicationIdentity -Port $iisWebBinding.port -HostHeader $iisWebBinding.hostheader -Protocol $iisWebBinding.protocol -IP $iisWebBinding.ip;

						Write-Host "Adding binding to hosts file";
						Windows-UpdateHostsFile 127.0.0.1 $($iisWebBinding.hostheader);
									
						if($iisWebBinding.protocol -eq "https")
						{
							Write-Host "Adding certificate to binding...";
							$commerceCert = ( Get-ChildItem -Path "cert:\localmachine\MY" | where { $_.FriendlyName -ieq $iisWebBinding.certificate -or $_.Subject -ieq "CN=$($iisWebBinding.certificate)" });
							$sslBinding = Get-WebBinding -Name $iisWebBinding.webApplicationIdentity -Port $iisWebBinding.port -HostHeader $iisWebBinding.hostheader -Protocol $iisWebBinding.protocol -IP $iisWebBinding.ip;
							$sslBinding.AddSslCertificate( $commerceCert.ThumbPrint, "MY" );
						}
					}

					Write-Host "Done." -ForegroundColor Yellow;
				}
				else
				{
					Write-Host "No IIS web bindings defined in the Environment.xml file." -ForegroundColor Yellow;
				}				
			}

			if($configuration.Sitecore -and $configuration.Sitecore.MergeFiles -and $configuration.Sitecore.MergeFiles.File){
				$files = $configuration.Sitecore.MergeFiles.SelectNodes("File");

				Write-Host "Found Sitecore files to merge." -ForegroundColor Green;
				foreach( $file in $files )
				{
					Write-Host "Merging $($file.in) into $($file.out)";

					if(Test-Path -path $($file.in))
					{
						$returnValue = Start-Process -FilePath $MERGE_TOOL -ArgumentList @("inputfile=`"$($file.in)`"", "destinationfile=`"$($file.out)`"") -NoNewWindow -Wait -PassThru;
						
						if( $returnValue.ExitCode -ne 0 )
						{
							Write-Error "Program Exit Code was $($returnValue.ExitCode), aborting.`r$($returnValue.StandardError)";
						}						
					}
					else
					{
						Write-Error "Input file $($file.in) does not exist, no merge occured";
					}
				}
			}
			else
			{
				if($configuration.Sitecore)
				{
					Write-Host "No Sitecore files to merge." -ForegroundColor Yellow;
				}
			}

			# Sitecore Install
			if($configuration.SitecoreInstall)
			{
				if(Test-Path $installDir)
				{
					Write-Error "Install dir $installDir already exists; Cannot create the sitecore instance $instanceName over an existing instance" -Category InvalidData
					return
				}
                
                Push-Location $DEPLOYMENT_DIRECTORY
				
				New-Item -ItemType directory -Path $installDir | out-null

				# unzip Sitecore zip to install dir
				Write-Host "Extracting Sitecore to $installDir"
				UnZipFile $sitecoreZip $installDir
				$sitecoreVer = Get-ChildItem $installDir -Filter "Sitecore*" -Name
				Write-Host "Installing sitecore version $sitecoreVer" -ForegroundColor Green 
                foreach($child in Get-ChildItem -Path ($installDir + "\" + $sitecoreVer))
                {
                    $child.MoveTo($installDir+"\"+$child.BaseName)
                }
				Remove-Item ($installDir + "\" + $sitecoreVer) -Recurse

                # test to see if the DB folder exists
                if(!(Test-Path $SitecoreDBFolder))
				{
					Write-Error 'Database directory $SitecoreDBFolder does not exist.  Verify the SitecoreDBFolder variable in the environment xml file.  The zip file contains a folder named "Databases"' -Category InvalidData
					return
				}

				# move the config files to App_Config\Includes folder
				get-childitem -Path $installDir -Filter "Sitecore.Analytics.*config" | move-item -destination $SitecoreAppConfigIncFolder

				# apply Modify permissions to web and data folders
				if($configuration.UserAccounts)
				{
					$users = $configuration.SelectNodes("UserAccounts/UserAccount");
				
					foreach($user in $users)
					{
						Write-Host "Creating permissions for $($user.Domain)\$($user.UserName) on the folders $($SitecoreDataFolder) and $($SitecoreWebsiteFolder)";
						# modify permissions on data and web folders
						Windows-GrantAccessToFolder $SitecoreDataFolder "$($user.Domain)\$($user.UserName)" ([System.Security.AccessControl.FileSystemRights]"Modify")
						Windows-GrantAccessToFolder $SitecoreWebsiteFolder "$($user.Domain)\$($user.UserName)" ([System.Security.AccessControl.FileSystemRights]"Modify")
					}
				}

				# place license file in data folder
				Copy-Item $licenseFile ($SitecoreDataFolder + "\license.xml") 

				if($configuration.SitecoreInstall.installTds -ne $null)
				{
					$installTds = [System.Convert]::ToBoolean($configuration.SitecoreInstall.installTds);

					if(($installTds -eq $true) -and (Test-Path $tdsDir) -and (Test-Path $SitecoreWebsiteFolder)){

						Write-Host "Copying over TDS files..." -ForegroundColor Green;
						Copy-Item (Join-Path $tdsDir "_Dev") $SitecoreWebsiteFolder -recurse -force;
						Copy-Item (Join-Path $tdsDir "bin") $SitecoreWebsiteFolder -recurse -force;
					}
					else{
						Write-Host "Not installing TDS because some of the files are missing." -ForegroundColor Yellow;
					}
				}

				# modify data folder location in Sitecore.config
				Write-Host "Modifying Sitecore.config"
				$doc = New-Object System.Xml.XmlDocument
				$doc.Load($SitecoreWebsiteFolder + "\App_Config\Sitecore.config")
				$node = $doc.SelectSingleNode("//sitecore/sc.variable[@name = 'dataFolder']")
				$node.value = $SitecoreDataFolder + "\"
				$doc.Save($SitecoreWebsiteFolder + "\App_Config\Sitecore.config")

                # add snapin for adding the db's
                Add-SQLPSSnapin

				# connect DB's to SQL Server
				#Write-Host "Connecting Databases"
				#Rename-Item ($SitecoreDBFolder) $SitecoreDBFolder

				# rename the DB files to add the instance name prefix
				$files = Get-ChildItem -Path $SitecoreDBFolder
				foreach ($file in $files)
				{
					Rename-Item -path $file.FullName -newname ($instanceName + $file.Name)
				}

				# create the DB sub dirs
				New-Item -ItemType directory -Path $SitecoreDB_MDF_Folder | out-null
				New-Item -ItemType directory -Path $SitecoreDB_LDF_Folder | out-null

				get-childitem -Path $SitecoreDBFolder -Filter "*.mdf" | move-item -destination $SitecoreDB_MDF_Folder
				get-childitem -Path $SitecoreDBFolder -Filter "*.ldf" | move-item -destination $SitecoreDB_LDF_Folder

				$files = Get-ChildItem -Path $SitecoreDB_MDF_Folder
				foreach ($file in $files)
				{
					# get the matching ldf file
					$ldfFile = $SitecoreDB_LDF_Folder + "\" + $file.BaseName + ".ldf"
					# create DB Name
					$dbName = $file.BaseName.Replace('.', '_')
					# Hook the files to SQL Server
					Add-SQL-Database $dbName "$($file.FullName)" $ldfFile
				}

				# edit ConnectionStrings.config to add DB instances
				Write-Host "Editing connection strings"
				$doc = New-Object System.Xml.XmlDocument
				$doc.Load($SitecoreWebsiteFolder + "\App_Config\ConnectionStrings.config")
				
                if(!$trustedSQLConnection)
                {
                    # use specific user for connection strings
                    $connectionString = "user id=" + $sql_user_name + ";password=" + $sql_user_password + ";Data Source=" + $sql_server_data_source + ";Database="
                }
				else
                {
                    # use trusted connections for the connection strings
                    $connectionString = "Server=" + $sql_server_data_source + ";Trusted_Connection=Yes;Database="
				}

                $node = $doc.SelectSingleNode("//connectionStrings/add[@name = 'core']")
				$node.connectionString = $connectionString + $Sitecore_DB_Core_Name
				$node = $doc.SelectSingleNode("//connectionStrings/add[@name = 'master']")
				$node.connectionString = $connectionString + $Sitecore_DB_Master_Name
				$node = $doc.SelectSingleNode("//connectionStrings/add[@name = 'web']")
				$node.connectionString = $connectionString + $Sitecore_DB_Web_Name
				
                # set up the reporting node
				$node = $doc.SelectSingleNode("//connectionStrings/add[@name = 'reporting']")
				$node.connectionString = $connectionString + $Sitecore_DB_DMS_Name
				
				# Add the DMS connection string
                #$element = $doc.CreateElement("add")
				#$element.SetAttribute("name", "analytics");
            	#$element.SetAttribute("connectionString", $connectionString + $Sitecore_DB_DMS_Name);
				#$doc.connectionStrings.AppendChild($element)
				
				# modify MongoDB names
				$mongoConnectionString = "mongodb://localhost/"
				$node = $doc.SelectSingleNode("//connectionStrings/add[@name = 'analytics']")
				$node.connectionString = $mongoConnectionString + $Sitecore_MONGODB_Analytics_Name
				$node = $doc.SelectSingleNode("//connectionStrings/add[@name = 'tracking.live']")
				$node.connectionString = $mongoConnectionString + $Sitecore_MONGODB_Live_Name
				$node = $doc.SelectSingleNode("//connectionStrings/add[@name = 'tracking.history']")
				$node.connectionString = $mongoConnectionString + $Sitecore_MONGODB_History_Name
				
				$doc.Save($SitecoreWebsiteFolder + "\App_Config\ConnectionStrings.config")

				# configure IIS
				Import-Module -Name WebAdministration;
				Write-Host "Configuring IIS"
				Invoke-Expression -Command "& $($env:systemroot)\system32\inetsrv\APPCMD.exe add site /name:`"$instanceName`" /physicalPath:`"$SitecoreWebsiteFolder`" /bindings:http/*`:$SitecorePort`:";
				if( $configuration.SitecoreInstall.IIS.ApplicationPool )
				{
					$appPool = $configuration.SitecoreInstall.IIS.ApplicationPool

		            if($appPool.name -ne $null) 
					{
						# if appPool does not exist, create it
                        $appPoolInstance = Get-ChildItem "IIS:\AppPools" | where { $_.Name -eq $($appPool.fullName) };
			            if($appPoolInstance -eq $null)
                        {
				            Write-Host "App Pool $($appPool.fullName) does not exist, creating...";
				            $appPoolInstance = New-Item "IIS:\AppPools\$($appPool.fullName)";
				            $userAccountInstance = $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "$($appPool.userAccountIdentity)" };

				            if($userAccountInstance -ne $null)
                            {
                                $appPoolInstance.processModel.identityType = 3;
                                $appPoolInstance.processModel.userName = "$($userAccountInstance.domain)\$($userAccountInstance.username)";
                                $appPoolInstance.processModel.password = $userAccountInstance.password;
                                $appPoolInstance | Set-Item;
                            }
                        }

                        if($appPool.framework -ne $null -and $appPool.framework -ne "") 
                        {
				            Write-Host "Setting the framework version to be $($appPool.framework)...";
                            $appPoolInstance.managedRuntimeVersion = "$($appPool.framework)";	
                            $appPoolInstance | Set-Item				
			            }

                        Write-Host "Setting Sitecore AppPool to $($appPool.fullName)" -ForegroundColor Green;
						Set-ItemProperty "IIS:\Sites\$instanceName" ApplicationPool $appPool.fullName
					}

					# Set Use App Pool Identity explictly
                    Write-Host "Setting the site to run as App Pool Identity"
                    Invoke-Expression -Command "& $($env:systemroot)\system32\inetsrv\APPCMD.exe set config $instanceName -section:system.webServer/security/authentication/anonymousAuthentication /userName:`"`" /commit:apphost";
				}

				if( $configuration.SitecoreInstall.IIS.Certificates -and $configuration.SitecoreInstall.IIS.Certificates.Certificate ){
					$certificates = $configuration.SitecoreInstall.IIS.SelectNodes("Certificates/Certificate");
					
					Write-Host "Importing certificates..." -ForegroundColor Green;
					foreach( $iisCertificate in $certificates )
					{
						$cert = ( Get-ChildItem -Path "cert:\LocalMachine\My" | where { $_.FriendlyName -ieq $iisCertificate.identity -or $_.Subject -ieq "CN=$($iisCertificate.identity)" });

						if( $cert -ne $null )
						{
							Write-Host "Deleting pre-existing certificate: $($iisCertificate.identity)";
							
							$store = New-Object System.Security.Cryptography.X509Certificates.X509Store "My", "LocalMachine"
							$store.Open("ReadWrite")
							$store.Remove($cert)
							$store.Close()
						}

						if($iisCertificate.selfSigned -and $iisCertificate.selfSigned -eq "true"){
							New-SelfSignedCertificate -DnsName $iisCertificate.identity -CertStoreLocation Cert:\LocalMachine\My
							continue;
						}
						
						Write-Host "Importing $($iisCertificate.identity)";
						$certPath = $iisCertificate.path;
						
						Import-IIS7PfxCertificate -certPath "$certPath" -pfxPass $iisCertificate.password;
					}
				
					Write-Host "Done." -ForegroundColor Yellow;
				}

				if( $configuration.SitecoreInstall.IIS.WebBindings )
				{
					foreach( $binding in $configuration.SitecoreInstall.IIS.WebBindings.WebBinding )
					{
						Write-Host "Setting Sitecore bindings port $($binding.port) and host header $($binding.hostheader)" -ForegroundColor Green;
						New-WebBinding -Name $binding.webApplicationIdentity -Port $binding.port -HostHeader $binding.hostheader -Protocol $binding.protocol -IP $binding.ip;

						if($binding.protocol -eq "https")
						{
							Write-Host "Adding certificate to binding...";
							$commerceCert = ( Get-ChildItem -Path "cert:\localmachine\MY" | where { $_.FriendlyName -ieq $binding.certificate -or $_.Subject -ieq "CN=$($binding.certificate)" });
							$sslBinding = Get-WebBinding -Name $binding.webApplicationIdentity -Port $binding.port -HostHeader $binding.hostheader -Protocol $binding.protocol -IP $binding.ip;
							$sslBinding.AddSslCertificate( $commerceCert.ThumbPrint, "MY" );
						}

						Write-Host "Adding binding to hosts file";
						Windows-UpdateHostsFile 127.0.0.1 $($binding.hostheader);
					}
				}

				# update hosts file with instance name
				Windows-UpdateHostsFile "127.0.0.1" $instanceName

				# Add web application for transaction service
				Write-Host "Configuring Transaction Service application"
				if( $configuration.SitecoreInstall.IIS.WebApplication )
				{
				    $webApp =  $configuration.SitecoreInstall.IIS.WebApplication
					$appPool = $configuration.SitecoreInstall.IIS.WebApplication.ApplicationPool

		            if($appPool.name -ne $null) 
					{
						# if appPool does not exist, create it
                        $appPoolInstance = Get-ChildItem "IIS:\AppPools" | where { $_.Name -eq $($appPool.fullName) };
			            if($appPoolInstance -eq $null)
                        {
				            Write-Host "App Pool $($appPool.fullName) does not exist, creating...";
				            $appPoolInstance = New-Item "IIS:\AppPools\$($appPool.fullName)";
				            $userAccountInstance = $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "$($appPool.userAccountIdentity)" };

				            if($userAccountInstance -ne $null)
                            {
                                $appPoolInstance.processModel.identityType = 3;
                                $appPoolInstance.processModel.userName = "$($userAccountInstance.domain)\$($userAccountInstance.username)";
                                $appPoolInstance.processModel.password = $userAccountInstance.password;
                                $appPoolInstance | Set-Item;
                            }
                        }

                        if($appPool.framework -ne $null -and $appPool.framework -ne "") 
                        {
				            Write-Host "Setting the framework version to be $($appPool.framework)...";
                            $appPoolInstance.managedRuntimeVersion = "$($appPool.framework)";	
                            $appPoolInstance | Set-Item				
			            }

                        Write-Host "Setting Transaction service AppPool to $($appPool.fullName)" -ForegroundColor Green;

						Invoke-Expression -Command "& $($env:systemroot)\system32\inetsrv\APPCMD.exe add app /site.Name:`"$($instanceName)`" /path:`"/$($webApp.name)`" /physicalPath:`"$($webApp.path)`" ";
						Invoke-Expression -Command ("& $($env:systemroot)\system32\inetsrv\APPCMD.exe set app `"$($instanceName)/$($webApp.name)`" /applicationPool:$($appPool.fullName) ");						
					}					
				}				

                Pop-Location
			}

			if($configuration.Sitecore.Databases -or $configuration.Sitecore.DatabaseScripts.DatabaseScript -or
				$configuration.CommerceServer.Databases -or $configuration.CommerceServer.DatabaseScripts.DatabaseScript)
			{
				$dbRoot = $null;

				if($configuration.Sitecore.DatabaseScripts)
				{
					$dbRoot = $configuration.Sitecore;
				}
				else
				{
					$dbRoot = $configuration.CommerceServer;
				}

				$SQL_VARIABLES_BASE=@(
					"CS_USER_RUNTIME=`"$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSRuntimeUser" }).domain )\$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSRuntimeUser" }).userName )`"",
					"CS_USER_FOUNDATION=`"$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSFoundationUser" }).domain )\$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSFoundationUser" }).userName )`"",
					"CS_USER_CATALOG=`"$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSCatalogUser" }).domain )\$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSCatalogUser" }).userName )`"",
					"CS_USER_MARKETING=`"$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSMarketingUser" }).domain )\$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSMarketingUser" }).userName )`"",
					"CS_USER_ORDERS=`"$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSOrdersUser" }).domain )\$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSOrdersUser" }).userName )`"",
					"CS_USER_PROFILES=`"$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSProfilesUser" }).domain )\$(( $configuration.UserAccounts.UserAccount | where { $_.identity -ieq "CSProfilesUser" }).userName )`"",
					"SC_DB_NAME_CORE=`"$($Sitecore_DB_Core_Name)`"",
					"SC_DB_NAME_WEB=`"$($Sitecore_DB_Web_Name)`"",
					"SC_DB_NAME_MASTER=`"$($Sitecore_DB_Master_Name)`"",
					"SC_DB_NAME_DMS=`"$($Sitecore_DB_DMS_Name)`""
				);																				
															
				if($dbRoot.DatabaseScripts.DatabaseScript ){
					Write-Host "Updating CS databases...";
			
					Add-SQLPSSnapin;
						
					foreach( $databaseScript in $dbRoot.DatabaseScripts.DatabaseScript )
					{
						Write-Host "$($databaseScript.path)" -ForegroundColor Green;
						$databaseIdentity = ( $dbRoot.Databases.Database | where { $_.identity -ieq $databaseScript.databaseIdentity } ) ;

						$SQL_VARIABLES = $SQL_VARIABLES_BASE;
						$SQL_VARIABLES += "CS_DB_SERVER=`"$($databaseIdentity.serverName)`"";
							
						$SQL_VARIABLES_STRING = [System.String]::Join( " -v ", $SQL_VARIABLES );
						$returnValue = Start-Process -Wait -NoNewWindow -PassThru -WorkingDirectory $DEPLOYMENT_DIRECTORY -FilePath $SQLCMD_PATH -ArgumentList @( "-b", "-E", "-S $($databaseIdentity.serverName)", "-i `"$($databaseScript.path)`"", "-v $($SQL_VARIABLES_STRING)");
						Write-Host $returnValue.StandardOutput;
						if( $returnValue.ExitCode -ne 0 )
						{
							if( $Error )
							{
								Write-Host $Error -ForegroundColor Red;
							}
							Write-Error -Message $returnValue.StandardError -ErrorId $returnValue.ExitCode ;
						}
					}
				}	
			}

			if($configuration.CommerceServer){

				if($configuration.CommerceServer.Configure){
					$stagingUser = $configuration.UserAccounts.UserAccount | where { $_.identity -ieq $($configuration.CommerceServer.Configure.stagingUser) };
					$mailerUser = $configuration.UserAccounts.UserAccount | where { $_.identity -ieq $($configuration.CommerceServer.Configure.mailerUser) }
				
					CS2007-Configure $($CS_SQL_Server) $stagingUser.domain $stagingUser.username $stagingUser.password $mailerUser.domain $mailerUser.username $mailerUser.password;
				}
			
				if($configuration.CommerceServer.SetupSite) {		
					
					$csServiceWebsite = $configuration.IIS.Websites.Website | where { $_.identity -ieq $($CS_WEBSERVICE_IIS_SITE_NAME) };
					$catalogVD = $csServiceWebsite.VirtualDirectories.VirtualDirectory | where { $_.identity -ieq "$($PROJECT_NAME)_CatalogWebService" };
					$ordersVD = $csServiceWebsite.VirtualDirectories.VirtualDirectory | where { $_.identity -ieq "$($PROJECT_NAME)_MarketingWebService" };
					$profilesVD = $csServiceWebsite.VirtualDirectories.VirtualDirectory | where { $_.identity -ieq "$($PROJECT_NAME)_OrdersWebService" };
					$marketingVD = $csServiceWebsite.VirtualDirectories.VirtualDirectory | where { $_.identity -ieq "$($PROJECT_NAME)_ProfilesWebService" };

					$catalogAppPool = $configuration.IIS.ApplicationPools.ApplicationPool | where { $_.name -ieq "$($catalogVD.applicationPool)" };
					$ordersAppPool = $configuration.IIS.ApplicationPools.ApplicationPool | where { $_.name -ieq "$($ordersVD.applicationPool)" };
					$profilesAppPool = $configuration.IIS.ApplicationPools.ApplicationPool | where { $_.name -ieq "$($profilesVD.applicationPool)" };
					$marketingAppPool = $configuration.IIS.ApplicationPools.ApplicationPool | where { $_.name -ieq "$($marketingVD.applicationPool)" };

					.\CS-Setup.ps1 -csSiteName $configuration.CommerceServer.SetupSite.siteName -runtimeSiteUser $(Get-FullUserName "CSFoundationUser" $configuration) -catalogWSUser $(Get-FullUserName "CSCatalogUser" $configuration) -ordersWSUser $(Get-FullUserName "CSOrdersUser" $configuration) -profilesWSUser $(Get-FullUserName "CSProfilesUser" $configuration) -marketingWSUser $(Get-FullUserName "CSMarketingUser" $configuration) -webServiceSiteName $csServiceWebsite.identity -webServiceSiteDiskPath $csServiceWebsite.path -webServicePortNumber $csServiceWebsite.port -catalogAppPool $catalogAppPool.fullName -ordersAppPool $ordersAppPool.fullName -profilesAppPool $profilesAppPool.fullName -marketingAppPool $marketingAppPool.fullName -catalogAzmanFile $configuration.CommerceServer.SetupSite.catalogAzmanFile;
				}										

				if($configuration.CommerceServer.Schemas){
					$schemas = $configuration.CommerceServer.Schemas;
					$profilesDacpacFile = $null;

					if($configuration.CommerceServer.Dacpacs -and $configuration.CommerceServer.Dacpacs.Dacpac)
					{
						$profilesDacpac = $configuration.CommerceServer.Dacpacs.Dacpac | where { $_.database -ieq "Profiles" };
						if($profilesDacpac){$profilesDacpacFile = $profilesDacpac.path;}
					}

					.\CS-ImportData.ps1 -csSiteName $PROJECT_NAME -catalogFile $schemas.Catalog.path -inventoryFile $schemas.Inventory.path -marketingFile $schemas.Marketing.path -ordersFile $schemas.Orders.path -ordersConfigFile $schemas.OrdersConfig.path -profilesFile $schemas.Profiles.path -profilesDacpacFile $profilesDacpacFile -catalogAzmanFile $schemas.Catalog.AzmanFile.path;
				}									
			}

			#create any required folders and assign permissions
			if($configuration.Folders -and $configuration.Folders.Folder){
				Write-Host "Creating folders..." -ForegroundColor Green;
				
				$folders = $configuration.SelectNodes("Folders/Folder");
			
				foreach($folder in $folders){
					if ((Test-Path $folder.path) -ne $true){
						Write-Host "Creating $($folder.path)";
						
						New-Item $folder.path -type directory > $null;											
					}
					else{
						Write-Host "$($folder.path) already exists will not re-create.";
					}
					
					if($folder.UserAccounts -and $folder.UserAccounts.UserAccount){
						Write-Host "Creating permissions for $($folder.path)";
						
						$users = $folder.SelectNodes("UserAccounts/UserAccount");
					
						foreach($user in $users){
							$userAccount = $configuration.UserAccounts.UserAccount | where { $_.identity -ieq $user.userAccountIdentity};
							
							Write-Host "Creating permissions for $($userAccount.domain)\$($userAccount.username) on $($folder.path)";
							Windows-GrantFullReadWriteAccessToFolder "$($folder.path)" "$($userAccount.domain)\$($userAccount.username)";
						}
					}					
				}
			}


			Write-Host "Done." -ForegroundColor Yellow;
		}	

		if($configuration.Files -and $configuration.Files.File){
			
			$files = $configuration.Files.SelectNodes("File");
		
			foreach($file in $files){
				if($file.UserAccounts -and $file.UserAccounts.UserAccount){
					Write-Host "Creating permissions for $($file.path)";
					
					$users = $file.SelectNodes("UserAccounts/UserAccount");
				
					foreach($user in $users){
						$userAccount = $configuration.UserAccounts.UserAccount | where { $_.identity -ieq $user.userAccountIdentity};
						
						Write-Host "Creating permissions for $($userAccount.domain)\$($userAccount.username) on $($file.path)";
						Windows-GrantFullReadWriteAccessToFile "$($file.path)" "$($userAccount.domain)\$($userAccount.username)";
					}
				}				
			}
		}
		
		if($configuration.Registry -and $configuration.Registry.File){
		
			Write-Host "Running registry files..." -ForegroundColor Green;
			
			$files = $configuration.Registry.SelectNodes("File");
			
			foreach( $file in $files )
			{
				$argumentListReg = @( "/s", $file.path );
			
				Write-Host "Running file $($file.path)";
				Write-Host "64 bit" -ForegroundColor Green;
				$returnValue = Start-Process -FilePath $REGEDIT_64_PATH -Wait -NoNewWindow -ArgumentList $argumentListReg -PassThru;
				Write-Host $returnValue.StandardOutput;
				if( $returnValue.ExitCode -ne 0 )
				{
					Write-Error -Message $returnValue.StandardError -ErrorId $returnValue.ExitCode ;
				}

				Write-Host "32 bit" -ForegroundColor Green;
				$returnValue = Start-Process -FilePath $REGEDIT_PATH -Wait -NoNewWindow -ArgumentList  $argumentListReg -PassThru;
				Write-Host $returnValue.StandardOutput;
				if( $returnValue.ExitCode -ne 0 )
				{
					Write-Error -Message $returnValue.StandardError -ErrorId $returnValue.ExitCode ;
				}
			}
		}
		
		$success = "SUCCESSFUL";
	}
	catch
	{
		foreach( $errorRecord in $Error )
		{
			Write-Host -Object $errorRecord -ForegroundColor Red;
			Write-Host -Object $errorRecord.InvocationInfo.PositionMessage -ForegroundColor Red;
		}
	}
	finally
	{
		$scriptEndDate = Get-Date;
		$scriptDuration = New-TimeSpan -Start $scriptStartDate -End $scriptEndDate;
		Write-Host "Script ended @ $($scriptEndDate) ( $($scriptDuration.Minutes) minutes, $($scriptDuration.Seconds) seconds. ).";

		if( Get-WinEvent -ErrorAction SilentlyContinue -MaxEvents 1 -FilterHashTable @{LogName="*"; StartTime=$scriptStartDate} -Oldest | where { $_.LevelDisplayName -ieq 'Error' -or $_.LevelDisplayName -eq 'Critical' } )
		{
			Get-WinEvent -ErrorAction SilentlyContinue -FilterHashTable @{LogName="*"; StartTime=$scriptStartDate} -Oldest | where { $_.LevelDisplayName -ieq 'Error' -or $_.LevelDisplayName -eq 'Critical' } | Format-List;
		}
		
		if( Get-Job )
		{
			Stop-Job -Name *;
		}

        try {
		    Stop-Transcript -ErrorAction SilentlyContinue;
        }
        catch {
            # workaround for hosts which don't support transcription
        }
	}
	
}