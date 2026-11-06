<#
  .SYNOPSIS
  Wrapper around FFmpeg that plays music files.

  .DESCRIPTION
  Loads and plays a list of songs using FFmpeg and its utilities.
  Requires an installation of FFmpeg and at least PowerShell 7.

  .PARAMETER Playlist
  The name of the playlist(s) to load.
  Can be a path, or the base leaf name of a file in (user)/Music/Playlists.
  Each line in the playlist file is a path to a song.
  If the line begins and ends with double quotes, it specifies a literal path.
  Otherwise, it specifies a rough path or glob.
  Paths that don't exist are ignored.
  Optional extra parameters may be specified after the path, separated by "|".
  These include:
    - VOLUME: multiplies the volume passed into ffplay for this song
      (final volume still capped 0-100)
    - COLOR: comma-separated colours to use in the spectrogram
    - DOTS: comma-separated colours to use in the visualisation dots
      (defaults to the same as COLOR)
    - BG: comma-separated colours to use in the visualisation background
  For example: path/to/file.mp3 | VOLUME = 1.5 | COLOR = #ff00ff, #0000ff

  .PARAMETER NoShuffle
  By default, the playlist is shuffled on each loop.
  Use -NoShuffle, -Order, -InOrder, -ns, or -o to play the list in order.

  .PARAMETER NoLoop
  By default, the playlist is repeated infinitely.
  Use -NoLoop, -Once, -NoRepeat, -nl, or -nr to only play the list once.

  .PARAMETER DisableFancyVisual
  Use -DisableFancyVisual, -nv, -dv, or -dfv to disable the dots visual
  in the top left of the terminal.

  .PARAMETER KeepHistory
  Use -KeepHistory, -kh, -k, or -h to keep previously played songs
  instead of reusing the same lines for new songs.

  .PARAMETER Volume
  Use -Volume or -v to control the volume, between 0 and 100.
  This is passed into ffplay.

  .INPUTS
  Playlist path.

  .OUTPUTS
  Visual outputs. No data.

  .EXAMPLE
  PS> pl songs

  .EXAMPLE
  PS> pl C:\Users\Guest\Playlists\Songs.txt
#>

#Requires -Version 7

param (
  [Parameter(Mandatory=$false, ValueFromPipeline=$true)]
  [string[]]$Playlist = $null,

  [Parameter(Mandatory=$false)]
  [Alias("Order","InOrder","ns","o")]
  [switch]$NoShuffle = $false,

  [Parameter(Mandatory=$false)]
  [Alias("Once","NoRepeat","nl","nr")]
  [switch]$NoLoop = $false,

  [Parameter(Mandatory=$false)]
  [Alias("nv","dv","dfv")]
  [switch]$DisableFancyVisual = $false,

  [Parameter(Mandatory=$false)]
  [Alias("kh","k","h")]
  [switch]$KeepHistory = $false,

  [Parameter(Mandatory=$false)]
  [ValidateRange(0, 100)]
  [Alias("v")]
  [int]$Volume = 100
)

if (-not (Get-Command -Type Application "ffmpeg.exe" -ErrorAction SilentlyContinue)) {
  Write-Host "ffmpeg.exe was not found! Make sure it is installed on PATH." -ForegroundColor Red
  exit 1
}

if (-not (Get-Command -Type Application "ffplay.exe" -ErrorAction SilentlyContinue)) {
  Write-Host "ffplay.exe was not found! Make sure it is installed on PATH." -ForegroundColor Red
  exit 1
}

if (-not (Get-Command -Type Application "ffprobe.exe" -ErrorAction SilentlyContinue)) {
  Write-Host "ffprobe.exe was not found! Make sure it is installed on PATH." -ForegroundColor Red
  exit 1
}

$ESC = [String][char]0x1b
$CSI = $ESC + "["

$SpectrogramFPS = 40
$FancyVisualFPS = 30
$LastPrintIndex = 0

# columns must be a multiple of 8
[int]$VisualisationColumns = 16
[int]$VisualisationRows = 8

$VolumeDB = 0.0
$SongConfigurations = @{}


class Color {
  [byte]$R = 0
  [byte]$G = 0
  [byte]$B = 0

  Color() {}
  Color([byte]$R, [byte]$G, [byte]$B) {
    $this.R = $R
    $this.G = $G
    $this.B = $B
  }
  Color([string]$ColorString) {
    $ColorString = $ColorString.Trim()
    if ($ColorString -match "^#[0-9a-f]{6}$") {
      $this.R = [Convert]::ToByte($ColorString.Substring(1, 2), 16)
      $this.G = [Convert]::ToByte($ColorString.Substring(3, 2), 16)
      $this.B = [Convert]::ToByte($ColorString.Substring(5, 2), 16)
    } elseif ($ColorString -match "^#[0-9a-f]{3}$") {
      $this.R = [Convert]::ToByte($ColorString[1] * 2, 16)
      $this.G = [Convert]::ToByte($ColorString[2] * 2, 16)
      $this.B = [Convert]::ToByte($ColorString[3] * 2, 16)
    } else {
      $this.R = 255
      $this.G = 0
      $this.B = 0
    }
  }

  static [Color] FromHue([double]$Hue) {
    $C = 1
    $X = 1 - [Math]::Abs(($Hue / 60) % 2 - 1)

    $RGB = $(switch ([Math]::Floor($Hue / 60) % 6) {
      0 { @($C, $X, 00) }
      1 { @($X, $C, 00) }
      2 { @(00, $C, $X) }
      3 { @(00, $X, $C) }
      4 { @($X, 00, $C) }
      5 { @($C, 00, $X) }
    }) | ForEach-Object { [Math]::Clamp([int][Math]::Floor($_ * 255), 0, 255) }

    return [Color]::new($RGB[0], $RGB[1], $RGB[2])
  }

  [string] ToANSI() {
    return "2;$($this.R);$($this.G);$($this.B)"
  }
}

class ColorPalette {
  [Color[]]$Colors = @([Color]::new(0, 0, 0))

  ColorPalette() {}
  ColorPalette([Color]$Color) {
    $this.Colors = @($Color)
  }
  ColorPalette([Color[]]$Colors) {
    $this.Colors = $Colors
  }
  ColorPalette([string]$ColorPaletteString) {
    $this.Colors = [Color[]]($ColorPaletteString -split ",")
  }

  [Color] GetColor([double]$Offset) {
    $Index = [Math]::Clamp([int][Math]::Floor($this.Colors.Count * $Offset), 0, $this.Colors.Count - 1)
    return $this.Colors[$Index]
  }
}


function Start-SongProcess {
  param($File, $PlayFrom)

  $SongConfig = $SongConfigurations[$File]

  $PSI = New-Object System.Diagnostics.ProcessStartInfo
  $PSI.FileName = "ffplay.exe"

  $V = [int]($Volume * [Math]::Pow(10.0, $VolumeDB / 10.0) * $(if ($SongConfig.Volume -ge 0.0) { $SongConfig.Volume } else { 1.0 }))
  $V = [Math]::Clamp($V, 0, 100)
  $PSI.Arguments = "-hide_banner -loglevel quiet -stats -vn -nodisp -sync audio -autoexit -volume $V -ss $PlayFrom -i `"$File`""
  $PSI.RedirectStandardError = $true
  $PSI.UseShellExecute = $false
  $PSI.CreateNoWindow = $true

  $Process = [System.Diagnostics.Process]::Start($PSI)

  Start-Sleep -Milliseconds 10

  return $Process
}

function Stop-Song {
  Get-Process ffplay -ErrorAction SilentlyContinue | Stop-Process
}

function Get-ProgressBar {
  param($Progress, $Width)
  $BlockSymbols = " ▏▎▍▌▋▊▉█"
  (0..($Width - 1) | ForEach-Object {
    $V0 = $_ / $Width
    $V1 = ($_ + 1) / $Width
    $F = ($Progress - $V0) / ($V1 - $V0)
    $N = [Math]::Min([Math]::Max([Math]::Floor($F * 8), 0), 8)
    $BlockSymbols[$N]
  }) -join ""
}

function Write-Time {
  param([string]$Symbol, [double]$PlayTime, [double]$TotalTime, $AmplitudeValues = $null, [ColorPalette]$SpectrumColor = $null)

  $PrintIndex = -1

  $BarPrefix1 = "$($CSI)34;3mloading $($CSI)23m"
  $BarPrefix2 = "$($CSI)34;3mspectrum$($CSI)23m"

  if ($AmplitudeValues) {
    $PrintIndex = [int][Math]::Floor((($PlayTime + 0.05) / $TotalTime) * $AmplitudeValues.Count)
    if ($PrintIndex -eq $LastPrintIndex) { return }

    $AmplitudesHere = $AmplitudeValues[$PrintIndex]
    $IndexArray = $(
      if ($AmplitudesHere) {
        (0..7 | ForEach-Object { [Math]::Clamp([int][Math]::Floor([float]($AmplitudesHere[$_]) / 256 * (1 + $_ / 8) * 12), 0, 15) })
      } else {
        @(0) * 8
      }
    )

    $UpperFilled = "         ▁▂▃▄▅▆▇█"
    $LowerFilled = " ▁▂▃▄▅▆▇█████████"
    $BarPrefix1 = -join $UpperFilled[$IndexArray]
    $BarPrefix2 = -join $LowerFilled[$IndexArray]

    if ($SpectrumColor) {
      $Colors = (0..7 | ForEach-Object {
        $CSI + "38;" + $SpectrumColor.GetColor(1.0 - [Math]::Abs(($PlayTime * 0.5 + $_ / 8) % 2.0 - 1.0)).ToANSI() + "m"
      })

      $Mapper = {
        param($T)
        (0..7 | ForEach-Object { $Colors[$_] + $T[$_] }) -join ""
      }

      $BarPrefix1 = & $Mapper $BarPrefix1
      $BarPrefix2 = & $Mapper $BarPrefix2
    }
  }

  if ($PrintIndex -ne $LastPrintIndex) {
    $LastPrintIndex = $PrintIndex

    Write-Host (
      "$($CSI)F$($CSI)K$BarPrefix1$($CSI)0;97;2m$Symbol $($CSI)96;22m" + [TimeSpan]::FromSeconds([Math]::Round($PlayTime * 100) / 100).ToString("hh\:mm\:ss\.ff") + "$($CSI)90m / $($CSI)94m" + [TimeSpan]::FromSeconds([Math]::Round($TotalTime * 100) / 100).ToString("hh\:mm\:ss\.ff") + "$($CSI)0m" +
      "`n" +
      "$($CSI)K$BarPrefix2$($CSI)0m  $($CSI)96;44m$(Get-ProgressBar ($PlayTime / $TotalTime) 25)$($CSI)0m"
    ) -NoNewline
  }
}

function Write-Visualisation {
  param([ColorPalette]$BG, [ColorPalette]$FG, $Data, [float]$Frame)

  [int]$StartLine = ([int][Math]::Floor($Frame) + 1) * $VisualisationRows
  if ($StartLine -gt $Data.Count - $VisualisationRows) {
    $StartLine = 0
  }

  $Line = 0
  $Column = 0

  Write-Host (
    "$($ESC)7" +
    "$($CSI)f" +
    (" " * ($VisualisationColumns + 2)) + "`n" +
    (
      (
        $Data[$StartLine..($StartLine + $VisualisationRows - 1)] |
          ForEach-Object {
            $Column = 0

            -join (
              [string[]][char[]]$_ | ForEach-Object {
                $Fraction = ($Line / ($VisualisationRows - 1) + 0.5 * $Column / ($VisualisationColumns - 1)) / 1.5
                "$($CSI)48;" + $BG.GetColor($Fraction).ToANSI() + ";38;" + $FG.GetColor($Fraction).ToANSI() + "m" + $_
                $Column++
              }
            ) + "$($CSI)0m  "

            $Line++
          }
      ) -join "`n"
    ) +
    "`n" + (" " * ($VisualisationColumns + 2)) +
    "$($ESC)8"
  ) -NoNewline
}

$Shuffle = -not $NoShuffle

if ($Playlist -eq $null) {
  Write-Host "No playlist specified." -ForegroundColor Red
  exit 1
}


class SongConfiguration {
  [double]$Volume = -1.0
  [ColorPalette]$BG = $null
  [ColorPalette]$Dots = $null
  [ColorPalette]$Color = $null

  [void] Parse([string[]]$Options) {
    foreach ($Option in $Options) {
      if ($Option.Contains("=")) {
        ($OptionName, $OptionValue, $null) = $Option -split "="
        $OptionName = $OptionName.Trim()
        $OptionValue = $OptionValue.Trim()
        try {
          $this.$OptionName = $OptionValue
        } catch {}
      }
    }
  }
}

$Playlist = $Playlist | ForEach-Object {
  $PlaylistFolder = Join-Path $env:USERPROFILE "Music\Playlists"

  $OPlaylistPath = $_
  $PlaylistPath = $_
  try {
    if (-not (Test-Path $PlaylistPath -PathType Leaf)) { $PlaylistPath = Join-Path $PlaylistFolder $PlaylistPath }
    if (-not (Test-Path $PlaylistPath -PathType Leaf)) { $PlaylistPath = $PlaylistPath + ".*" }
    $null = Get-Content $PlaylistPath -ErrorAction Stop # dummy read to ensure access
  } catch {
    Write-Host ("Could not find playlist: " + $OPlaylistPath) -ForegroundColor Red
    exit 1
  }

  return $PlaylistPath
}

function Get-Songs {
  param($Playlist)

  $Songs = [System.Collections.Generic.List[String]]::new()
  try {
    ((Get-Content -Path $Playlist -ErrorAction Stop) -split "`n") | ForEach-Object {

      $P = ($_ -split "(?<!\|.*)#")[0].Trim()
      $Pp = $P -split "\|"

      $P = $Pp[0].Trim()
      $Pp = $Pp[1..($Pp.Count)]

      if ($P) {

        $SongConfig = $null
        if ($Pp) {
          $SongConfig = [SongConfiguration]::new()
          $SongConfig.Parse($Pp)
        }

        $(
          if ($P -match '^".*"$') {
            Get-ChildItem -LiteralPath ($P.Trim('"')) -ErrorAction SilentlyContinue
          } else {
            Get-ChildItem -Path $P -Recurse -ErrorAction SilentlyContinue
          }
        ) | Select-Object -ExpandProperty "FullName" | ForEach-Object {
          if (Test-Path -LiteralPath $_ -PathType Leaf) {
            $Songs.Add($_)
            if ($SongConfig) {
              $SongConfigurations[$_] = $SongConfig
            }
          }
        }

      }

    }
  } catch {
    $_ | Out-File -FilePath "$env:USERPROFILE\script_error.log" -Append
  }
  if ($Songs.Count -eq 0) {
    Write-Host "No song paths found in playlist file." -ForegroundColor Red
    exit 1
  }
  return [string[]]$Songs.ToArray()
}


[string[]]$Songs = Get-Songs $Playlist
$TimeSincePlayed = @{}
foreach ($Song in $Songs) {
  $TimeSincePlayed[$Song] = [int]($Songs.Count * 0.5)
}

function Get-NextSongRandom {

  $PlayNow = [int]($Songs.Count * 1.5)
  $CanPlay = [int]($Songs.Count * 0.5)

  $NextSong = Get-Random $Songs

  [string[]]$AvailableSongs = @()

  $PlayNowValue = ($TimeSincePlayed.GetEnumerator() | ForEach-Object { $_.Value } | Measure-Object -Maximum).Maximum
  if ($PlayNowValue -ge $PlayNow) {
    $CanPlay = $PlayNowValue
  }
  $AvailableSongs = [string[]]($Songs | Where-Object { $TimeSincePlayed[$_] -ge $CanPlay })

  if ($AvailableSongs) {
    $NextSong = Get-Random $AvailableSongs
  }

  foreach ($Song in $Songs) {
    $TimeSincePlayed[$Song]++
  }

  $TimeSincePlayed[$NextSong] = 0

  return $NextSong
}


Clear-Host
Write-Host "$($CSI)?25l"

try {

  Stop-Song

  $Host.UI.RawUI.WindowTitle = "Playlist"

  $Spaces = ("$($CSI)40m" + (" " * $VisualisationColumns) + "$($CSI)0m  ") * (-not $DisableFancyVisual)

  Write-Host "$Spaces$($CSI)7m Escape $($CSI)0m - exit"
  Write-Host "$Spaces$($CSI)7m Tab $($CSI)0m - skip"
  Write-Host "$Spaces$($CSI)7m Backspace $($CSI)0m - stop"
  Write-Host "$Spaces$($CSI)7m P $($CSI)0m - pause"
  Write-Host "$Spaces$($CSI)7m R $($CSI)0m - rewind"
  Write-Host "$Spaces$($CSI)7m ← → $($CSI)0m - seek 10 seconds"
  if ($VisualisationRows -gt 6 -and -not $DisableFancyVisual) {
    Write-Host ("$Spaces`n" * ($VisualisationRows - 6))
  } else {
    Write-Host ""
  }

  $Index = 0

  if ($Shuffle -and $NoLoop) {
    $Songs = $Songs | Get-Random -Count $Songs.Count
  }

  do {

    if ($Shuffle -and -not $NoLoop) {
      $Song = Get-NextSongRandom
    } else {
      $Song = $Songs[$Index]
      $Index++
      $Index %= $Songs.Count
    }

    $LastPlayed = $Song
    $SongName = Get-ChildItem -LiteralPath $Song | Select-Object -ExpandProperty Name

    $FormattedSongName = (Split-Path -Path $SongName -LeafBase) + "$($CSI)90m" + (Split-Path -Path $SongName -Extension)

    Write-Host ("$($CSI)K$($CSI)2;3mPlaying $($CSI)22;23;97m" + $FormattedSongName + "$($CSI)0m`n$($CSI)K$($CSI)97;2m        @ loading$($CSI)0m`n`n$($CSI)F") -NoNewline
    $Host.UI.RawUI.WindowTitle = "Playlist - " + $SongName

    try {
      $SongDuration = [TimeSpan]::FromSeconds([double]((& ffprobe.exe -v error -select_streams a:0 -show_entries stream=duration -of default=noprint_wrappers=1:nokey=1 $Song 2>&1) | Out-String))
    } catch {
      Write-Host "$($CSI)F        $($CSI)91mno audio data found$($CSI)0m"
      return
    }
    #if (-not ((& ffprobe.exe -i $Song 2>&1 | Out-String) -match 'Duration: (?<time>\d\d+:\d\d:\d\d\.\d\d+)[^\d]')) {
    #}
    #$SongDuration = [TimeSpan]$Matches.time

    $SongAmplitudeValues_Job = Start-ThreadJob -ScriptBlock {
      param([string]$File, [int]$Width)

      try {

        $VisualisationSize = "$($Using:VisualisationColumns*2)x$($Using:VisualisationRows*4)"

        $FilterGraph = "
        $(if (-not $Using:DisableFancyVisual) { "[0:a]asplit[a1][a2];" })

        $(if ($Using:DisableFancyVisual) { "[0:a]" } else { "[a1]" })
          showspectrum=s=256x1:color=intensity:orientation=horizontal:saturation=0:fps=$($Using:SpectrogramFPS):data=magnitude:legend=disabled:scale=sqrt:fscale=log:win_func=hamming:start=60:stop=20000
          ,scale=w=8:h=0:scaler=area
          ,tmix=frames=4:weights='0.25 1 1 0.25'
        [spec];

        $(if (-not $Using:DisableFancyVisual) {"
          [a2]
            showcwt=s=1x20:r=$($Using:FancyVisualFPS):scale=fm:iscale=sqrt:min=20:max=20000:slide=scroll:mode=magnitude:pps=20
            ,format=pix_fmts=gray
            ,tmix=frames=3:weights='1 2 1'
            ,vflip
            ,scale=$($VisualisationSize):scaler=point
            ,format=pix_fmts=gray
            ,geq=lum=st(0\,(N*H+Y)*W+X+2963000601)\;st(1\,(X/W*20/(.5+(lum(0\,Y)*(4+2*Y/H)+lumsum(0\,Y)/H*3)/255)-3))\;min(max((gauss(ld(1))*3)^4\,lt(ld(1)\,0)*(random(0)^16))*lt(ld(1)\,.25)\,1)*255
            ,vflip
            ,format=pix_fmts=gray
            ,geq=lum=st(1\,hypot((Y+.5)/H*2-1\,(X+.5)/W*2-1))\;lt(ld(1)\,1)*min(max(lum(ld(1)*ld(1)*W\,abs(atan2((X+.5)/W*2-1\,(Y+.5)/H*2-1))/PI*H)*4\,0)\,255)
            ,format=pix_fmts=monob
          [vis];
        "})
        "

        $TmpSpec = [IO.Path]::GetTempFileName()
        $TmpVis = $(if ($Using:DisableFancyVisual) { $null } else { [IO.Path]::GetTempFileName() })
        try {
          & ffmpeg.exe (&{
            "-i"; $File;
            "-loglevel"; "quiet";
            "-filter_complex"; $FilterGraph;
            "-map"; "[spec]"; "-f"; "rawvideo"; "-pix_fmt"; "gray"; $TmpSpec;
            if (-not $Using:DisableFancyVisual) { "-map"; "[vis]"; "-f"; "rawvideo"; "-pix_fmt"; "monob"; $TmpVis; }
            "-y";
          })
          $SpecOutputRaw = [IO.File]::ReadAllBytes($TmpSpec)
        } finally {
          Remove-Item $TmpSpec -ErrorAction SilentlyContinue
        }

        return @{
          "Spectrum" = (0..($Width - 1)) | ForEach-Object { , $SpecOutputRaw[($_ * 8)..($_ * 8 + 7)] }
          "VisualFile" = $TmpVis
        }

      } catch {
        $_ | Out-File -FilePath "$env:USERPROFILE\script_error.log" -Append
      }

    } -ArgumentList $Song,([Math]::Round($SongDuration.TotalSeconds * $SpectrogramFPS))

    $SongVisualFrames_Job = $null

    $SongAmplitudeValues = $null
    $SongVisualFrames = [System.Collections.Generic.List[String]](@("*" * $VisualisationColumns) * $VisualisationRows)

    [ColorPalette]$SongSpectrumColor = $SongConfigurations[$Song].Color ?? [ColorPalette]::new([Color]::FromHue((Get-Random -Minimum 0.0 -Maximum 360.0)))
    [ColorPalette]$SongVisualForeground = $SongConfigurations[$Song].Dots ?? $SongSpectrumColor
    [ColorPalette]$SongVisualBackground = $SongConfigurations[$Song].BG ?? [ColorPalette]::new([Color]::new(0, 0, 0))

    $SongProcess = Start-SongProcess $Song 0
    $PlayTime = 0.0
    $Paused = $false

    $Skip = $false

    while ($Paused -or -not $SongProcess.HasExited) {

      if ($SongAmplitudeValues_Job -and $SongAmplitudeValues_Job.State -eq "Completed") {

        $SongVisualData = Receive-Job -Job $SongAmplitudeValues_Job -Wait -AutoRemoveJob
        $SongAmplitudeValues_Job = $null

        $SongAmplitudeValues = $SongVisualData["Spectrum"]

        if (-not $DisableFancyVisual) {
          $SongVisualFrames_Job = Start-ThreadJob -ScriptBlock {
            param([string]$VisualDataFile)

            $LineBytes = [int]$Using:VisualisationColumns
            $PixelRowBytes = [int]($LineBytes -shr 2)

            $SW = [System.Diagnostics.Stopwatch]::new()

            $FileStream = [System.IO.File]::Open($VisualDataFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $Buffer = New-Object byte[] $LineBytes

            [int]$BaseChar = 0x2800

            $SW.Start()
            [int]$Lines = 0

            try {
              while (($BytesRead = $FileStream.Read($Buffer, 0, $LineBytes)) -eq $LineBytes) {

                $Lines++

                # 1 character:
                # AD (<<0) (<<3)
                # BE (<<1) (<<4)
                # CF (<<2) (<<5)
                # GH (<<6) (<<7)

                # 1 line:
                # 00 [a1 d1 a2 d2 a3 d3 a4 d4] [a5 d5 a6 d6 a7 d7 a8 d8] [a9 d9 a10 d10... a24 d24]
                # 06 [b1 e1 b2 e2 b3 e3 b4 e4] [b5 e5 b6 e6 b7 e7 b8 e8] [b9 e9 b10 e10... b24 e24]
                # 12 [c1 f1 c2 f2... ]
                # 18 [g1 h1 g2 h2... ]

                # partial return
                -join $(
                  for ($i = 0; $i -lt $PixelRowBytes; $i++) {

                    foreach ($ShiftEven in 6,4,2,0) {
                      $ShiftOdd = $ShiftEven + 1

                      $AddChar = [int](
                        (($Buffer[$i]                      -shr $ShiftOdd)  -band 1) -bor
                        (($Buffer[$i + $PixelRowBytes]     -shr $ShiftOdd)  -band 1) -shl 1 -bor
                        (($Buffer[$i + $PixelRowBytes * 2] -shr $ShiftOdd)  -band 1) -shl 2 -bor
                        (($Buffer[$i]                      -shr $ShiftEven) -band 1) -shl 3 -bor
                        (($Buffer[$i + $PixelRowBytes]     -shr $ShiftEven) -band 1) -shl 4 -bor
                        (($Buffer[$i + $PixelRowBytes * 2] -shr $ShiftEven) -band 1) -shl 5 -bor
                        (($Buffer[$i + $PixelRowBytes * 3] -shr $ShiftOdd)  -band 1) -shl 6 -bor
                        (($Buffer[$i + $PixelRowBytes * 3] -shr $ShiftEven) -band 1) -shl 7
                      )

                      [char]($BaseChar + $AddChar)
                      # partial return (passed into -join)

                    }
                  }
                )

              }
            } catch {
              $_ | Out-File -FilePath "$env:USERPROFILE\script_error.log" -Append
            } finally {
              $FileStream.Close()
              Remove-Item $VisualDataFile -ErrorAction SilentlyContinue
            }

            $SW.Stop()
            "Processing $Lines lines took $($SW.Elapsed.ToString("hh\:mm\:ss\.fff"))`n  for an average of $(($Lines / $SW.Elapsed.TotalSeconds).ToString('F3')) lines per second" | Out-File -FilePath "$env:USERPROFILE\script_error.log" -Append

          } -ArgumentList $SongVisualData["VisualFile"]
        }

      } elseif ($SongVisualFrames_Job -and -not $DisableFancyVisual) {

        $NewLines = Receive-Job -Job $SongVisualFrames_Job
        if ($NewLines) {
          foreach ($NewLine in $NewLines) {
            $SongVisualFrames.Add($NewLine)
          }
        }

        if ($SongVisualFrames_Job.State -eq "Completed") {
          Remove-Job $SongVisualFrames_Job
          $SongVisualFrames_Job = $null
        }

      }

      if (-not $Paused) {
        $Line = $SongProcess.StandardError.ReadLine()
        if ($Line -match '^ *(?<time>\d+\.\d+) M-A:') {
          $PlayTime = [double]$Matches.time
        }
        Write-Time ">" $PlayTime $SongDuration.TotalSeconds $SongAmplitudeValues $SongSpectrumColor
      } else {
        Write-Time "*" $PlayTime $SongDuration.TotalSeconds $SongAmplitudeValues $SongSpectrumColor
      }
      if (-not $DisableFancyVisual) {
        Write-Visualisation $SongVisualBackground $SongVisualForeground $SongVisualFrames (($PlayTime + 0.05) * $FancyVisualFPS)
      }

      $Host.UI.RawUI.WindowTitle = ("Playlist - " + $SongName + $(if ($Paused) {" - paused"}))

      if ($Paused -or [Console]::KeyAvailable) {

        $InputKey = [Console]::ReadKey($true)

        $Host.UI.RawUI.FlushInputBuffer()

        $Skip = $false
        $Exit = $false
        $Wait = $false
        $PauseSong = $false
        $ResumeSong = $false

        $Modifiers = $()

        if ($InputKey.Modifiers -ne "None") {
          $Modifiers = $InputKey.Modifiers -split ", "
        }

        switch ($InputKey.Key) {

          "Escape" {
            $Skip = $true
            $Exit = $true
          }

          "Tab" {
            $Skip = $true
          }

          "Backspace" {
            $Skip = $true
            $Wait = $true
          }

          "R" {
            $PauseSong = $true
            $ResumeSong = $true
            $PlayTime = 0.0
          }

          "P" {
            $PauseSong = -not $Paused
            $ResumeSong = $Paused
          }

          "LeftArrow" {
            $PauseSong = -not $Paused
            $ResumeSong = -not $Paused
            $PlayTime = [Math]::Max($PlayTime - 10.0, 0.0)
          }

          "RightArrow" {
            $PauseSong = -not $Paused
            $ResumeSong = -not $Paused
            $PlayTime = $PlayTime + 10.0
          }

          default {}

        }

        if ($PauseSong) {
          Stop-Song
          $Paused = $true
        }

        if ($ResumeSong) {
          $SongProcess = Start-SongProcess $Song $PlayTime
          $Paused = $false
        }

        if ($Skip) {
          break
        }

      }
    }

    Stop-Song

    if (-not $DisableFancyVisual) {
      $Black = [ColorPalette]::new([Color]::new(0, 0, 0))
      Write-Visualisation $Black $Black (@(" " * $VisualisationColumns) * $VisualisationRows) -1
    }

    $Host.UI.RawUI.WindowTitle = "Playlist"

    if (-not $Exit) {

      $ASymbol = $(if ($Skip) { ">" } else { "*" })
      $AWord = $(if ($Skip) { "skipped" } else { "finished" })

      $Line1 = "$ASymbol $ASymbol $ASymbol $AWord" + (" " * 40)

      (0..25) | ForEach-Object {

        $N = if ($_ -eq 25) { $Line1.Length } else { ([Math]::Pow(($_ / 25.0), 0.5) * 40) }
        $F = if ($_ -eq 25) { "$($CSI)K" }

        Write-Host (
          "$($CSI)F$F$($CSI)97;2m        $($Line1[0..$N] -join '')`n" +
          "$($CSI)K$($CSI)0m"
        ) -NoNewline
        Start-Sleep -Milliseconds 20

      }

    }

    Get-Job | ForEach-Object { Stop-Job $_; Wait-Job $_; Remove-Job $_ }

    if ($Wait) {
      Write-Host "$($CSI)96;3mPress Tab to continue..."
      while ([Console]::ReadKey($true).Key -ne "Tab") {}
      if (-not $KeepHistory) {
        Write-Host "$($CSI)F$($CSI)K" -NoNewline
      }
    }

    if ($Exit) {
      Write-Host "$($CSI)?25h"
      exit
    }

    if (-not $KeepHistory) {
      Write-Host "$($CSI)2F" -NoNewline
    }

  } while (-not $NoLoop)

  Write-Host "$($CSI)92mPlaylist ended$($CSI)0m"

} catch {
  Write-Host ""
  Write-Host "$($CSI)?25h" -NoNewline
  $_ | Out-File -FilePath "$env:USERPROFILE\script_error.log" -Append
  exit 1
} finally {
  Get-Job | ForEach-Object { Stop-Job $_; Wait-Job $_; Remove-Job $_ }
  Stop-Song
  Write-Host "$($CSI)?25h" -NoNewline
}