#Requires -Version 3
#
#
# Used to flip a Sitecore site between using Solr and Lucene
#
#

trap
{
	Write-Host "Error: $($_.Exception.GetType().FullName)" -ForegroundColor Red ; 
	Write-Host $_.Exception.Message; 
	Write-Host $_.Exception.StackTrack;
	return;
}

Clear-Host;

# Change the instance name to the Sitecore instance name you want to delete
$instanceName = "CFRefStorefront"

# Common directories
$installDir = "c:\inetpub\" + $instanceName
$SitecoreWebsiteFolder = "$($installDir)\Website"
$websiteIncludeFolder = "$($SitecoreWebsiteFolder)\App_Config\Include";

# The path to any Sitecore search config files
$scLuceneFiles = "$websiteIncludeFolder\Sitecore.ContentSearch.Lucene.*";
$scSolrFiles = "$websiteIncludeFolder\Sitecore.ContentSearch.Solr.*";

# The path to any custom config files
$luceneConfigList = @("$websiteIncludeFolder\CommerceServer\*.Lucene.*.config", "$websiteIncludeFolder\ContentTesting\*.Lucene.*.config", "$websiteIncludeFolder\FXM\*.Lucene.*.config","$websiteIncludeFolder\ListManagement\*.Lucene.*.config", "$websiteIncludeFolder\Reference.Storefront\*.Lucene.config", "$websiteIncludeFolder\Social\*.Lucene.*.config", "$websiteIncludeFolder\*.MarketingAssets.Repositories.Lucene.*.config", "$websiteIncludeFolder\*.Marketing.Lucene.*.config", "$websiteIncludeFolder\Sitecore.Speak.ContentSearch.Lucene.config");
$solrConfigList = @("$websiteIncludeFolder\CommerceServer\*.Solr.*.config", "$websiteIncludeFolder\ContentTesting\*.Solr.*.config", "$websiteIncludeFolder\FXM\*.Solr.*.config", "$websiteIncludeFolder\ListManagement\*.Solr.*.config", "$websiteIncludeFolder\Reference.Storefront\*.Solr.config", "$websiteIncludeFolder\Social\*.Solr.*.config", "$websiteIncludeFolder\*.MarketingAssets.Repositories.Solr.*.config", "$websiteIncludeFolder\*.Marketing.Solr.*.config", "$websiteIncludeFolder\Sitecore.Speak.ContentSearch.Solr.config");


Write-Host "Checking to see which search provider is active inside " -NoNewline;
Write-Host "$($websiteIncludeFolder)" -ForegroundColor Green;

# Check and see which search provider is currently active

$solrFiles = @(gci "$scSolrFiles" -exclude "Sitecore.ContentSearch.Solr.DefaultIndexConfiguration.IOC.*")
$solrActive = $false;

if($solrFiles -ne $null -and $solrFiles.Length -gt 0){
	$solrActive = -not $solrFiles[0].Name.endsWith(".example");
}
else{
	Write-Host "No Solr files found.";
}

$luceneFiles = @(gci "$scLuceneFiles")
$luceneActive = $false;

if($luceneFiles -ne $null -and $luceneFiles.Length -gt 0){
	$luceneActive = -not $luceneFiles[0].Name.endsWith(".example");
}
else{
	Write-Host "No Lucene files found.";
}

function RenameMessage([string] $oldFile, [string] $newFile){
    Write-Host "Renaming " -nonewline;
    Write-Host "$($oldFile) " -nonewline -ForegroundColor Yellow;
    Write-Host "to " -nonewline;
    Write-Host "$($newFile)" -ForegroundColor Green;
}

function EnableFiles([string] $files) {
	gci "$files" -exclude *.sharded.*, Sitecore.ContentSearch.Solr.DefaultIndexConfiguration.IOC.*   | Foreach {$i=1} {
		$newName = ($_.Name -replace ".example",'');
        $newName = ($newName -replace ".disabled",'');
		RenameMessage $($_.Name) $($newName);
		Rename-Item $_ -NewName $newName -f;
		$i++;
	}
}

function DisableFiles([string] $files) {
	gci "$files" -exclude *.sharded.*, Sitecore.ContentSearch.Solr.DefaultIndexConfiguration.IOC.*  | Foreach {$i=1} {
		$newName = ($_.Name + ".example");
		RenameMessage $($_.Name) $($newName);
		Rename-Item $_ -NewName $newName -f;
		$i++;
	}
}

Write-Host "";

if($solrActive -eq $true){
	Write-Host "Solr " -ForegroundColor Yellow -NoNewline;
    Write-Host "is currently active, enabling " -NoNewline;
    Write-Host "Lucene " -ForegroundColor Green;
    Write-Host "";
		
    Write-Host "Main Files";
    Write-Host "--------------";
	EnableFiles $scLuceneFiles
	DisableFiles $scSolrFiles

    Write-Host "";
    Write-Host "Additional Files";
    Write-Host "----------------";

	foreach ($luceneConfig in $luceneConfigList) {
		EnableFiles "$($luceneConfig).example";
        	EnableFiles "$($luceneConfig).disabled";
		EnableFiles "$($luceneConfig).disable";
	}
	
	foreach ($solrConfig in $solrConfigList) {
		DisableFiles $solrConfig;
	}
}

if($luceneActive -eq $true){
	Write-Host "Lucene " -ForegroundColor Yellow -NoNewline;
    Write-Host "is currently active, enabling " -NoNewline;
    Write-Host "Solr " -ForegroundColor Green;
    Write-Host "";
	
    Write-Host "Main Files";
    Write-Host "--------------";
	EnableFiles $scSolrFiles;
	DisableFiles $scLuceneFiles;

    Write-Host "";
    Write-Host "Additional Files";
    Write-Host "----------------";

	foreach ($solrConfig in $solrConfigList) {
		EnableFiles "$($solrConfig).example";
        EnableFiles "$($solrConfig).disabled";
	}

	foreach ($luceneConfig in $luceneConfigList) {
		DisableFiles $luceneConfig;
	}
}

Write-Host "";