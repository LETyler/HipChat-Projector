############################################
#		 		  _Params_
############################################
param(
	[string]$Subtitles,
	[string]$Video
	)

# Example: -subtitles wonka.srt -video.wonka.avi

############################################
#		 		  _Functions_
############################################

function ChatLog ($Message, $Color, $TheFormat, [switch]$SkipLocalOutput)
{
	if (($TheFormat -eq $null) -or (($TheFormat -ne "text") -and ($TheFormat -ne "html")))
	{
		$TheFormat = "text"
	}

	if (($TheFormat -ne "html") -or ($SkipLocalOutput -eq $false))
	{
		Write-Host $Message
	}	

	Start-Sleep -Milliseconds 317
	CreateWebRequest -TargetURL "https://api.hipchat.com/v1/rooms/message?format=json&auth_token=$($HCSecurityToken)&room_id=$($HCLogRoomID)&color=$($Color)&message=$($Message)&message_format=$($TheFormat)&notify=0&from=$($HCLoggerName)" -TargetHost "api.hipchat.com"  -RequestType "POST" | Out-Null
}

function CreateWebRequest ($TargetURL, $TargetHost, $RequestType)
{
	$WebReq = [System.Net.WebRequest]::create($TargetURL)
	$WebReq.Host = $TargetHost
	$WebReq.Method = $RequestType
	$WebReq.ContentType = "application/xml"
	$WebResp = $WebReq.GetResponse()
	$ReqStream = $WebResp.GetResponseStream()
	$StreamObject = new-object System.IO.StreamReader $ReqStream
	$Result = $StreamObject.ReadToEnd()

	Return $Result		
}

function CreateAndGetAWSClientObject ($ClientType)
{
	# Create creds object
	$AccountInfo = New-Object PSObject -Property @{
	AWSAccessKey = $AWSAccKeyID
	AWSSecretKey = $AWSSecKeyID
	}

	switch ($ClientType)
	{
		"EC2"
		{
			# Sets the end-point to the specified region
			$EC2Config = New-Object Amazon.EC2.AmazonEC2Config
			$EC2Config.set_ServiceURL("https://ec2.$($MyAWSRegion).amazonaws.com")	

			#Sets the Client property for making calls -- queries across all regions (uses default end-point)
			$MyClientObject = [Amazon.AWSClientFactory]::CreateAmazonEC2Client($AccountInfo.AWSAccessKey,$AccountInfo.AWSSecretKey,$EC2Config)
		}
		"S3"
		{
			# Sets the end-point to the specified region
			$S3Config = New-Object Amazon.S3.AmazonS3Config

			#Sets the Client property for making calls -- queries across all regions (uses default end-point)
			$MyClientObject = [Amazon.AWSClientFactory]::CreateAmazonS3Client($AccountInfo.AWSAccessKey,$AccountInfo.AWSSecretKey,$S3Config)
		}
	}
		
	Return $MyClientObject
}

function UploadS3Object($MyTargetBucket, $MyTargetKeyPath, $MyLocalFilePath)
{

	# Create the Client Object
	$AWSClientType = "S3"
	$AWSClientObject = CreateAndGetAWSClientObject $AWSClientType
	
	# Upload
	$MyPutObjectRequest = New-Object -TypeName amazon.S3.Model.PutObjectRequest
	$MyPutObjectRequest.BucketName = $MyTargetBucket
	$MyPutObjectRequest.Key = $MyTargetKeyPath
	$MyPutObjectRequest.FilePath = $MyLocalFilePath
	
	$MyPutObjectResponse = $AWSClientObject.PutObject($MyPutObjectRequest)
	
	$AWSClientObject.Dispose()

}

############################################
#		 		  _Globals_
############################################

$BasePath = [System.IO.Path]::GetDirectoryName($myInvocation.MyCommand.Definition)

# HipChat
$HCLoggerName = "[HipChat user account this script will run under]"
$HCLogRoomID = "[HipChat room ID]"
$HCSecurityToken = "[HipChat security token]"

# Paths
$SubtitlesPath = "$($BasePath)\$Subtitles"
$VideoPath = "$($BasePath)\$Video"
$FramesPath = "$($BasePath)\Frames\"
$FfmpegPath = "[Path to ffmpeg executable]" # Example: "$($BasePath)\ffmpeg-20141113-git-3e1ac10-win64-static\bin\ffmpeg.exe"

# Control play speed / frame posting speed here
$PlaySpeedMultiple = 1
$ImgFrequencyThreshold = (5 / $PlaySpeedMultiple)

# S3
$AWSAccKeyID = "[AWS Access Key]"
$AWSSecKeyID = "[AWS Secret Key]"
$TargetBucket = "[S3 Bucket in which to store the video frames]"

# Load the AWS assembly
Add-Type -Path "C:\Program Files (x86)\AWS SDK for .NET\bin\AWSSDK.dll"
	
############################################
#		 		  _Main_
############################################

cls

# Import subtitle file
$SubContent = Get-Content -Path $SubtitlesPath 

# Define when the next frame can be posted
$NextFrame = [DateTime]::Now.AddSeconds($ImgFrequencyThreshold)

# For each line in the subtitle file...
foreach ($SubLine in $SubContent)
{
	# If it's a timestamp line...
	if ($SubLine.contains("-->"))
	{
		$TargetStamp = $($($SubLine.replace(" --> ",";")).split(";")[0]).split(",")[0]
		$OutIMGPrefix = $TargetStamp.Replace(":","_")
		$OutIMGName = "$($OutIMGPrefix).jpg"
		
		### FRAME ###
		# If enough time has gone by since the last frame post, post a new one
		if ([DateTime]::Now -ge $NextFrame)
		{
			# Export the frame
			$OutImgPath = "$($FramesPath)\$($OutImgName)"
			
			if (!(Test-Path -Path $OutImgPath))
			{
				# Frame hasn't already been exported; export it
				$Ffmpegcmd = 
@"
$FfmpegPath -ss $TargetStamp -i $VideoPath -frames:v 1 $OutImgPath -v quiet -y
"@
				cmd /c $Ffmpegcmd
			}

			# Wait for the frame to be extracted from the .avi
			$DoesImgExistYet = $false
			do
			{
				$DoesImgExistYet = Test-Path -Path $OutImgPath
			}
			while ($DoesImgExistYet -eq $false)
			
			# Upload it to S3
			UploadS3Object -MyLocalFilePath $OutImgPath -MyTargetBucket $TargetBucket -MyTargetKeyPath $OutImgName
			
			# Post the link to the Img in HipChat 
			$HTMLPost =
@"
<img src="https://s3.amazonaws.com/$($TargetBucket)/$($OutImgName)">
"@
			ChatLog -Message $HTMLPost -TheFormat html -SkipLocalOutput

			# Define when the next frame can be posted
			$NextFrame = [DateTime]::Now.AddSeconds($ImgFrequencyThreshold)			
		}
		
		### DIALOG ###
		$CurrLineNum = [array]::IndexOf($SubContent, $SubLine)		
		do
		{
			$NextLineNum = $CurrLineNum + 1
			$NextLineTxt = $SubContent[$NextLineNum]
			if ($NextLineTxt -ne "")
			{				
				# Post the dialog
				$ThePost = $SubContent[$NextLineNum]
				ChatLog -Message $ThePost -Color "green"
			}
			$CurrLineNum++
		}
		while ($NextLineTxt -ne "")
		
		# Find the next dialog line and wait for it...
		$WaitComplete = $false
		do
		{
			$NextLineNum = $CurrLineNum + 1
			$NextLineTxt = $SubContent[$NextLineNum]
			
			if ($NextLineTxt.contains("-->"))
			{
				$NextStamp = $($($NextLineTxt.replace(" --> ",";")).split(";")[0]).split(",")[0]
				$NextSecond = $NextStamp.Split(":")[2]
				$CurrentSecond = $TargetStamp.Split(":")[2]
				if ($NextSecond -lt $CurrentSecond)
				{
					$RemainingSecondsInMinute = 60 - $CurrentSecond
					$MyWaitSeconds = $RemainingSecondsInMinute + $NextSecond
				}
				else
				{
					$MyWaitSeconds = ($NextSecond - $CurrentSecond) / $PlaySpeedMultiple
				}				

				start-sleep -seconds  $MyWaitSeconds
				$WaitComplete = $true
			}
			else
			{
				$CurrLineNum++
			}
		}
		while ($WaitComplete -ne $true)
			
		# Increment
	    $CurrLineNum++
	}
}