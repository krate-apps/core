[AutoRun]
enabled=false
program=

[Application]
FileLogger\Age=1
FileLogger\AgeType=1
FileLogger\Backup=true
FileLogger\DeleteOld=true
FileLogger\Enabled=true
FileLogger\MaxSizeBytes=66560
FileLogger\Path=__KRATE_CONFIG_DIR__/qBittorrent/data/logs

[BitTorrent]
Session\AddTorrentPaused=false
Session\AddTrackersEnabled=false
Session\AlternativeGlobalDLSpeedLimit=10
Session\AlternativeGlobalUPSpeedLimit=10
Session\BTProtocol=TCP
Session\ChokingAlgorithm=FixedSlots
Session\DefaultSavePath=__KRATE_DOWNLOADS_DIR__
Session\DisableAutoTMMByDefault=true
Session\DisableAutoTMMTriggers\CategoryChanged=true
Session\DisableAutoTMMTriggers\CategorySavePathChanged=true
Session\DisableAutoTMMTriggers\DefaultSavePathChanged=true
Session\DiskCacheSize=64
Session\DiskCacheTTL=60
Session\Encryption=1
Session\GuidedReadCache=true
Session\LSDEnabled=false
Session\MaxConnections=-1
Session\MaxConnectionsPerTorrent=-1
Session\MaxRatioAction=0
Session\MultiConnectionsPerIp=true
Session\PeXEnabled=true
Session\Preallocation=true
Session\QueueingSystemEnabled=true
Session\SeedChokingAlgorithm=FastestUpload
Session\SendBufferLowWatermark=10
Session\SendBufferWatermark=500
Session\SendBufferWatermarkFactor=50
Session\TempPath=__KRATE_INCOMPLETE_DIR__
Session\TorrentContentLayout=Original
Session\UseRandomPort=true
Session\uTPEnabled=false
Session\uTPRateLimited=false

[Core]
AutoDeleteAddedTorrentFile=Never

[LegalNotice]
Accepted=true

[Meta]
MigrationVersion=8

[Network]
PortForwardingEnabled=false

[Preferences]
Bittorrent\AddTrackers=false
Bittorrent\Encryption=1
Bittorrent\LSD=false
Bittorrent\MaxConnecs=-1
Bittorrent\MaxConnecsPerTorrent=-1
Bittorrent\MaxRatioAction=0
Bittorrent\PeX=true
Bittorrent\uTP=false
Bittorrent\uTP_rate_limited=false
Connection\GlobalDLLimitAlt=10
Connection\GlobalUPLimitAlt=10
Connection\UPnP=false
Downloads\DiskWriteCacheSize=64
Downloads\DiskWriteCacheTTL=60
Downloads\PreAllocation=true
Downloads\SavePath=__KRATE_DOWNLOADS_DIR__
Downloads\StartInPause=false
General\Locale=__KRATE_LOCALE__
General\UseRandomPort=true
WebUI\Address=127.0.0.1
WebUI\AuthSubnetWhitelistEnabled=false
WebUI\HTTPS\Enabled=false
WebUI\LocalHostAuth=false
WebUI\Password_PBKDF2="__KRATE_WEBUI_PASSWORD_PBKDF2__"
WebUI\Port=__KRATE_PORT__
WebUI\ServerDomains=*
WebUI\UseUPnP=false
WebUI\Username=__KRATE_USERNAME__

[RSS]
AutoDownloader\DownloadRepacks=true
AutoDownloader\SmartEpisodeFilter=s(\\d+)e(\\d+), (\\d+)x(\\d+), "(\\d{4}[.\\-]\\d{1,2}[.\\-]\\d{1,2})", "(\\d{1,2}[.\\-]\\d{1,2}[.\\-]\\d{4})"
