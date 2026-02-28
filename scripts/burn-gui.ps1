# ============================================================================
# DICOM BURNER - WPF GUI for DVD Burning
# Copyright (c) 2026 Bejenaru Adrian. All rights reserved.
# Unauthorized copying, modification, or distribution is strictly prohibited.
# ============================================================================

param(
    [Parameter(Mandatory=$true)][string]$ZipPath,
    [string]$DriveID = "",
    [int]$BurnSpeed = 4,
    [switch]$AutoConfirm,
    [switch]$SimulateOnly
)

# Build verification token
$_bvt = "Q29weXJpZ2h0IDIwMjYgQmVqZW5hcnUgQWRyaWFu"
# --- STA Guard (WPF requires Single-Threaded Apartment) ---
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Write-Host "ERROR: Must run with -sta flag."
    exit 1
}

# --- Load WPF Assemblies ---
try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
} catch {
    Write-Host "ERROR: Cannot load WPF assemblies: $($_.Exception.Message)"
    exit 1
}

# ============================================================================
# LANGUAGE DETECTION
# ============================================================================
function Get-Strings {
    $lang = (Get-Culture).TwoLetterISOLanguageName
    switch ($lang) {
        "ro" {
            return @{
                StepVerify    = "Verificare sistem..."
                StepClean     = "Pregatire spatiu..."
                StepExtract   = "Extragere ZIP..."
                StepDicom     = "Organizare fisiere DICOM..."
                StepPatient   = "Citire date pacient..."
                StepWeasis    = "Copiere Weasis pe disc..."
                StepTemplates = "Copiere sabloane..."
                StepLauncher  = "Creare launcher..."
                StepDicomdir  = "Generare DICOMDIR..."
                StepSummary   = "Sumar disc"
                StepBurn      = "Ardere disc..."
                StepSimulate  = "Simulare ardere..."
                StepCleanup   = "Curatare..."
                WaitDisc      = "Introdu un DVD-R gol..."
                Success       = "DISC ARDS CU SUCCES!"
                SimSuccess    = "SIMULARE FINALIZATA!"
                BtnClose      = "Inchide"
                BtnContinue   = "Continuare"
                DiscSwap      = "Introdu un disc gol si apasa Continuare."
                NoDrive       = "Nu am gasit nicio unitate optica!"
                NoDisc        = "Discul nu este gol sau nu este inserat corect."
                NoZip         = "Fisierul ZIP nu exista!"
                NoWeasis      = "Weasis portable nu a fost gasit! Ruleaza setup.bat."
                NoDicom       = "Nu am gasit fisiere DICOM in ZIP!"
                Burning       = "Ardere in curs... nu scoate discul!"
                PhaseLeadIn   = "Lead-in"
                PhaseWrite    = "Scriere"
                PhaseLeadOut  = "Lead-out"
                PhaseDone     = "Finalizat"
                Ejecting      = "Ejectare disc..."
                DeleteZip     = "ZIP-ul sters"
                DiscSize      = "Dimensiune: {0} MB ({1}% din DVD)"
                Preparing     = "Se pregateste..."
                AutoClose     = "Se inchide in {0}s..."
                OverCapacity  = "Depaseste capacitatea DVD-R (4.7 GB)!"
                DcmtkMissing  = "dcmmkdir.exe nu a fost gasit - DICOMDIR nu va fi generat"
            }
        }
        "ru" {
            return @{
                StepVerify    = "Проверка системы..."
                StepClean     = "Подготовка..."
                StepExtract   = "Распаковка ZIP..."
                StepDicom     = "Организация файлов DICOM..."
                StepPatient   = "Чтение данных пациента..."
                StepWeasis    = "Копирование Weasis..."
                StepTemplates = "Копирование шаблонов..."
                StepLauncher  = "Создание лаунчера..."
                StepDicomdir  = "Генерация DICOMDIR..."
                StepSummary   = "Сводка диска"
                StepBurn      = "Запись на диск..."
                StepSimulate  = "Симуляция записи..."
                StepCleanup   = "Очистка..."
                WaitDisc      = "Вставьте чистый DVD-R..."
                Success       = "ДИСК ЗАПИСАН УСПЕШНО!"
                SimSuccess    = "СИМУЛЯЦИЯ ЗАВЕРШЕНА!"
                BtnClose      = "Закрыть"
                BtnContinue   = "Продолжить"
                DiscSwap      = "Вставьте чистый диск и нажмите Продолжить."
                NoDrive       = "Оптический привод не найден!"
                NoDisc        = "Диск не вставлен или не пуст."
                NoZip         = "ZIP-файл не найден!"
                NoWeasis      = "Weasis portable не найден! Запустите setup.bat."
                NoDicom       = "Файлы DICOM не найдены в ZIP!"
                Burning       = "Запись... не извлекайте диск!"
                PhaseLeadIn   = "Lead-in"
                PhaseWrite    = "Запись"
                PhaseLeadOut  = "Lead-out"
                PhaseDone     = "Завершено"
                Ejecting      = "Извлечение диска..."
                DeleteZip     = "ZIP удален"
                DiscSize      = "Размер: {0} МБ ({1}% DVD)"
                Preparing     = "Подготовка..."
                AutoClose     = "Закрытие через {0}с..."
                OverCapacity  = "Превышена емкость DVD-R (4.7 ГБ)!"
                DcmtkMissing  = "dcmmkdir.exe не найден - DICOMDIR не будет создан"
            }
        }
        default {
            return @{
                StepVerify    = "Verifying system..."
                StepClean     = "Preparing..."
                StepExtract   = "Extracting ZIP..."
                StepDicom     = "Organizing DICOM files..."
                StepPatient   = "Reading patient data..."
                StepWeasis    = "Copying Weasis..."
                StepTemplates = "Copying templates..."
                StepLauncher  = "Building launcher..."
                StepDicomdir  = "Generating DICOMDIR..."
                StepSummary   = "Disc summary"
                StepBurn      = "Burning disc..."
                StepSimulate  = "Simulating burn..."
                StepCleanup   = "Cleaning up..."
                WaitDisc      = "Insert a blank DVD-R..."
                Success       = "DISC BURNED SUCCESSFULLY!"
                SimSuccess    = "SIMULATION COMPLETE!"
                BtnClose      = "Close"
                BtnContinue   = "Continue"
                DiscSwap      = "Insert a blank disc and press Continue."
                NoDrive       = "No optical drive found!"
                NoDisc        = "Disc is not blank or not inserted."
                NoZip         = "ZIP file not found!"
                NoWeasis      = "Weasis portable not found! Run setup.bat."
                NoDicom       = "No DICOM files found in ZIP!"
                Burning       = "Burning... do not eject!"
                PhaseLeadIn   = "Lead-in"
                PhaseWrite    = "Writing"
                PhaseLeadOut  = "Lead-out"
                PhaseDone     = "Done"
                Ejecting      = "Ejecting disc..."
                DeleteZip     = "ZIP deleted"
                DiscSize      = "Size: {0} MB ({1}% of DVD)"
                Preparing     = "Preparing..."
                AutoClose     = "Closing in {0}s..."
                OverCapacity  = "Exceeds DVD-R capacity (4.7 GB)!"
                DcmtkMissing  = "dcmmkdir.exe not found - DICOMDIR will not be generated"
            }
        }
    }
}

$strings = Get-Strings
$modeLabel = if ($SimulateOnly) { "SIMULATE" } else { "DVD-R ${BurnSpeed}x" }

# ============================================================================
# WPF XAML LAYOUT
# ============================================================================
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DICOM Burner"
        Width="560" Height="460"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize"
        Topmost="True"
        ShowInTaskbar="True">

    <Border CornerRadius="12" Background="#1E1E1E" BorderBrush="#333333" BorderThickness="1">
        <Grid>
            <!-- WINDOW CONTROLS (top-right) -->
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top"
                        Margin="0,8,8,0" Panel.ZIndex="10">
                <Button x:Name="btnMinimize" Content="&#x2014;" Width="32" Height="24" Margin="0,0,4,0"
                        FontSize="13" Cursor="Hand" Foreground="#888888" Background="Transparent" BorderThickness="0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="4">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="border" Property="Background" Value="#333333"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
                <Button x:Name="btnCloseWin" Content="&#x2715;" Width="32" Height="24"
                        FontSize="13" Cursor="Hand" Foreground="#888888" Background="Transparent" BorderThickness="0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="4">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                            <ControlTemplate.Triggers>
                                <Trigger Property="IsMouseOver" Value="True">
                                    <Setter TargetName="border" Property="Background" Value="#D32F2F"/>
                                    <Setter Property="Foreground" Value="White"/>
                                </Trigger>
                            </ControlTemplate.Triggers>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </StackPanel>

            <!-- CONTENT -->
            <Grid Margin="24">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="8"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Row 0: Title -->
                <TextBlock Grid.Row="0" Text="DICOM BURNER" FontSize="28" FontWeight="Bold"
                           Foreground="#FFA726" HorizontalAlignment="Center" Margin="0,0,0,4"/>

                <!-- Row 1: Status (animated) -->
                <TextBlock Grid.Row="1" x:Name="txtStatus" FontSize="14" Foreground="#CCCCCC"
                           HorizontalAlignment="Center" Margin="0,0,0,4"/>

                <!-- Row 2: Info (patient, size) -->
                <TextBlock Grid.Row="2" x:Name="txtInfo" FontSize="11" Foreground="#888888"
                           HorizontalAlignment="Center" Margin="0,0,0,8"/>

                <!-- Row 3: Progress bar -->
                <ProgressBar Grid.Row="3" x:Name="progressBar" Height="6" Minimum="0" Maximum="100" Value="0"
                             Background="#333333" Foreground="#0F9B58" BorderThickness="0"/>

                <!-- Row 5: Log area -->
                <Border Grid.Row="5" Background="#151515" CornerRadius="6" Padding="10" Margin="0,0,0,8">
                    <ScrollViewer x:Name="scrollLog" VerticalScrollBarVisibility="Auto">
                        <TextBlock x:Name="txtLog" FontFamily="Consolas" FontSize="11"
                                   Foreground="#AAAAAA" TextWrapping="Wrap"/>
                    </ScrollViewer>
                </Border>

                <!-- Row 6: Bottom bar (mode label + close button) -->
                <Grid Grid.Row="6">
                    <TextBlock x:Name="txtMode" FontSize="10" Foreground="#555555"
                               VerticalAlignment="Center" HorizontalAlignment="Left"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Button x:Name="btnContinue" Content="Continue" Width="140" Height="32" Margin="0,0,8,0"
                                FontSize="13" FontWeight="SemiBold" Cursor="Hand"
                                Foreground="White" Background="#0F9B58" BorderThickness="0"
                                Visibility="Collapsed">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="6" Padding="12,4">
                                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#0DAE4F"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Button.Template>
                        </Button>
                        <Button x:Name="btnDone" Content="Close" Width="120" Height="32"
                                FontSize="13" FontWeight="SemiBold" Cursor="Hand"
                                Foreground="White" Background="#D32F2F" BorderThickness="0"
                                Visibility="Collapsed">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="6" Padding="12,4">
                                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#B71C1C"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Button.Template>
                        </Button>
                    </StackPanel>
                </Grid>
            </Grid>
        </Grid>
    </Border>
</Window>
"@

# ============================================================================
# CREATE WINDOW
# ============================================================================
try {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $window = [System.Windows.Markup.XamlReader]::Load($reader)
} catch {
    Write-Host "ERROR: XAML parse failed: $($_.Exception.Message)"
    exit 1
}

# Get controls
$txtStatus   = $window.FindName("txtStatus")
$txtInfo     = $window.FindName("txtInfo")
$progressBar = $window.FindName("progressBar")
$txtLog      = $window.FindName("txtLog")
$scrollLog   = $window.FindName("scrollLog")
$txtMode     = $window.FindName("txtMode")
$btnDone     = $window.FindName("btnDone")
$btnContinue = $window.FindName("btnContinue")
$btnMinimize = $window.FindName("btnMinimize")
$btnCloseWin = $window.FindName("btnCloseWin")

# Set localized text
$txtStatus.Text = $strings.Preparing
$txtMode.Text = $modeLabel
$btnDone.Content = $strings.BtnClose

# ============================================================================
# SHARED STATE
# ============================================================================
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

$syncHash = [hashtable]::Synchronized(@{
    Window      = $window
    TxtStatus   = $txtStatus
    TxtInfo     = $txtInfo
    TxtLog      = $txtLog
    ProgressBar = $progressBar
    ScrollLog   = $scrollLog
    Completed   = $false
    Success     = $false
    Failed      = $false
    Strings     = $strings
    ZipPath     = $ZipPath
    DriveID     = $DriveID
    BurnSpeed   = $BurnSpeed
    SimulateOnly = [bool]$SimulateOnly
    ProjectRoot = $ProjectRoot
    BurnSuccess = $false
    DiscError   = $false
    RetryBurn   = $false
    CancelBurn  = $false
})

# ============================================================================
# BACKGROUND WORKER (all burn logic)
# ============================================================================
$workerScript = {
    param($sync)

    $s = $sync.Strings
    $zipPath = $sync.ZipPath
    $driveID = $sync.DriveID
    $burnSpeed = $sync.BurnSpeed
    $simulate = $sync.SimulateOnly
    $projectRoot = $sync.ProjectRoot

    # Path setup
    $weasisDir    = Join-Path $projectRoot "tools\weasis-portable"
    $tempRoot     = Join-Path $env:TEMP "WeasisBurn"
    $discStaging  = Join-Path $tempRoot "disc"
    $contentDir   = Join-Path $discStaging "Weasis"
    $templatesDir = Join-Path $projectRoot "templates"
    $dcmtkDir     = Join-Path $projectRoot "tools\dcmtk"
    $discLabel    = "DICOM"

    # --- Helper: Log message to GUI ---
    function Log([string]$msg, [int]$progress = -1) {
        $sync.Window.Dispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{
                if ($sync.TxtLog.Inlines.Count -gt 0) {
                    $sync.TxtLog.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
                }
                $run = New-Object System.Windows.Documents.Run($msg)
                $color = "#AAAAAA"
                if     ($msg -match '^\[OK\]')       { $color = "#4CAF50" }
                elseif ($msg -match '^\[X\]')         { $color = "#FF5252" }
                elseif ($msg -match '^\[!\]')         { $color = "#FFD740" }
                elseif ($msg -match '^\[\d+/\d+\]')   { $color = "#0F9B58" }
                elseif ($msg -match '^>>>')            { $color = "#64B5F6" }
                elseif ($msg -match '^\[SIM\]')        { $color = "#FFA726" }
                $run.Foreground = New-Object System.Windows.Media.SolidColorBrush(
                    [System.Windows.Media.ColorConverter]::ConvertFromString($color))
                $sync.TxtLog.Inlines.Add($run)
                $sync.ScrollLog.ScrollToEnd()
                if ($progress -ge 0) { $sync.ProgressBar.Value = $progress }
            }
        )
    }

    function UpdateStatus([string]$text) {
        $sync.Window.Dispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{ $sync.TxtStatus.Text = $text }
        )
    }

    function UpdateInfo([string]$text) {
        $sync.Window.Dispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{ $sync.TxtInfo.Text = $text }
        )
    }

    function UpdateProgress([int]$pct) {
        $sync.Window.Dispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{ $sync.ProgressBar.Value = $pct }
        )
    }

    # --- Helper: Read DICOM patient info from binary file ---
    function Read-DicomPatientInfo([string]$filePath) {
        $result = @{ PatientName = ""; StudyDate = "" }
        try {
            $bytes = [System.IO.File]::ReadAllBytes($filePath)
            if ($bytes.Length -lt 140) { return $result }
            $magic = [System.Text.Encoding]::ASCII.GetString($bytes, 128, 4)
            if ($magic -ne "DICM") { return $result }
            $pos = 132
            $maxPos = [Math]::Min($bytes.Length, 16384)
            $longVRs = @("OB","OD","OF","OL","OW","SQ","UC","UN","UR","UT")
            while ($pos + 8 -le $maxPos) {
                $group   = [BitConverter]::ToUInt16($bytes, $pos)
                $element = [BitConverter]::ToUInt16($bytes, $pos + 2)
                $pos += 4
                $vr = [System.Text.Encoding]::ASCII.GetString($bytes, $pos, 2)
                $pos += 2
                if ($longVRs -contains $vr) {
                    $pos += 2
                    if ($pos + 4 -gt $maxPos) { break }
                    $valLen = [BitConverter]::ToUInt32($bytes, $pos); $pos += 4
                } else {
                    if ($pos + 2 -gt $maxPos) { break }
                    $valLen = [BitConverter]::ToUInt16($bytes, $pos); $pos += 2
                }
                if ($valLen -eq 0xFFFFFFFF -or $valLen -lt 0) { break }
                $valStart = $pos; $pos += $valLen
                if ($pos -gt $maxPos) { break }
                if ($group -eq 0x0008 -and $element -eq 0x0020 -and $valLen -gt 0) {
                    $result.StudyDate = [System.Text.Encoding]::ASCII.GetString($bytes, $valStart, $valLen).Trim()
                } elseif ($group -eq 0x0010 -and $element -eq 0x0010 -and $valLen -gt 0) {
                    $result.PatientName = [System.Text.Encoding]::ASCII.GetString($bytes, $valStart, $valLen).Trim()
                }
                if ($result.PatientName -and $result.StudyDate) { break }
                if ($group -gt 0x0010) { break }
            }
        } catch {}
        return $result
    }

    # --- Helper: Format disc label from patient info ---
    function Format-DiscLabel([string]$patientName, [string]$studyDate) {
        $name = ""; $date = ""
        if ($patientName) { $name = ($patientName -replace '\^', ' ').Trim().ToUpper() }
        if ($studyDate -and $studyDate.Length -ge 8) {
            $date = "$($studyDate.Substring(6,2))/$($studyDate.Substring(4,2))/$($studyDate.Substring(0,4))"
        }
        if ($name -and $date) { $label = "$name $date" }
        elseif ($name) { $label = $name }
        else { $label = "DICOM" }
        if ($label.Length -gt 32) { $label = $label.Substring(0, 32).Trim() }
        return $label
    }

    try {
        # ======== STEP 1: VERIFY WEASIS ========
        UpdateStatus ($s.StepVerify)
        Log ">>> $($s.StepVerify)" 2
        if (-not (Test-Path $zipPath)) { throw $s.NoZip }
        $launcherJar = Join-Path $weasisDir "weasis-launcher.jar"
        if (-not (Test-Path $launcherJar)) { throw $s.NoWeasis }
        $hasX86 = Test-Path (Join-Path $weasisDir "jre\windows\bin\java.exe")
        $hasX64 = Test-Path (Join-Path $weasisDir "jre\windows-x64\bin\java.exe")
        if (-not $hasX86 -and -not $hasX64) { throw $s.NoWeasis }
        $jreList = @(); if ($hasX86) { $jreList += "x86" }; if ($hasX64) { $jreList += "x64" }
        Log "[OK] Weasis portable (JRE: $($jreList -join ' + '))" 5

        # ======== STEP 2: CLEAN STAGING ========
        UpdateStatus ($s.StepClean)
        Log ">>> $($s.StepClean)" 6
        if (Test-Path $discStaging) { Remove-Item -Recurse -Force $discStaging }
        New-Item -ItemType Directory -Path $discStaging -Force | Out-Null
        New-Item -ItemType Directory -Path $contentDir -Force | Out-Null
        Log "[OK] Staging: $discStaging" 8

        # ======== STEP 2b: DEFENDER EXCLUSION ========
        # Exclude staging dir from Windows Defender real-time scanning (permanent).
        # Prevents 100% CPU on Antimalware Service Executable during ZIP extraction.
        # On non-admin: self-elevates via UAC (user enters admin password once).
        # Subsequent runs skip (exclusion already exists).
        try {
            $prefs = Get-MpPreference -ErrorAction Stop
            if ($prefs.ExclusionPath -and ($prefs.ExclusionPath -contains $tempRoot)) {
                Log "[OK] Defender: excludere deja configurata" 9
            } else {
                $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                if ($isAdmin) {
                    Add-MpPreference -ExclusionPath $tempRoot -ErrorAction Stop
                    Log "[OK] Defender: excludere adaugata" 9
                } else {
                    Log "[!] Se solicita drepturi admin pentru excludere Defender..." 9
                    $cmd = "Add-MpPreference -ExclusionPath '$tempRoot'"
                    $proc = Start-Process powershell -Verb RunAs `
                        -ArgumentList "-NoProfile","-Command",$cmd `
                        -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                    if ($proc.ExitCode -eq 0) {
                        Log "[OK] Defender: excludere adaugata" 9
                    } else {
                        Log "[!] Excluderea Defender nu a reusit" 9
                    }
                }
            }
        } catch {
            # 0x800106ba = Defender service not running / disabled — no exclusion needed
            if ($_.Exception.Message -match '0x800106ba|not running|disabled') {
                Log "[OK] Defender: serviciul nu ruleaza — excludere nu e necesara" 9
            } else {
                Log "[!] UAC refuzat — Defender va scana la extragere" 9
            }
        }

        # ======== STEP 3: EXTRACT ZIP ========
        UpdateStatus ($s.StepExtract)
        Log ">>> $($s.StepExtract) $(Split-Path -Leaf $zipPath)" 10
        $extractDir = Join-Path $tempRoot "extracted"
        if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
        # .NET ZipFile is 2-3x faster than PowerShell's Expand-Archive
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractDir)
        } catch {
            Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        }
        Log "[OK] ZIP -> $extractDir" 18

        # ======== STEP 4: COPY DICOM FILES ========
        UpdateStatus ($s.StepDicom)
        Log ">>> $($s.StepDicom)" 20
        $allDcmFiles = Get-ChildItem -Path $extractDir -Recurse -File | Where-Object {
            $_.Extension -match "^\.(dcm|DCM)$"
        }
        if ($allDcmFiles.Count -eq 0) {
            # Check extensionless files with DICM magic
            $allDcmFiles = @()
            Get-ChildItem -Path $extractDir -Recurse -File | Where-Object {
                $_.Extension -eq "" -and $_.Length -gt 132
            } | ForEach-Object {
                try {
                    $buf = [System.IO.File]::ReadAllBytes($_.FullName)
                    if ($buf.Length -gt 132 -and [System.Text.Encoding]::ASCII.GetString($buf, 128, 4) -eq "DICM") {
                        $allDcmFiles += $_
                    }
                } catch {}
            }
        }
        if ($allDcmFiles.Count -eq 0) { throw $s.NoDicom }
        Log "[OK] $($allDcmFiles.Count) DICOM" 22

        # Check if PACS DICOMDIR can be used directly ("Exclude Viewer" ZIPs)
        $usePacsDicomdir = $false
        $dicomRootFolders = @()
        $pacsDicomdir = Join-Path $extractDir "DICOMDIR"
        if (Test-Path $pacsDicomdir) {
            $topDirsWithDcm = @()
            Get-ChildItem -Path $extractDir -Directory | ForEach-Object {
                $hasDcm = Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -match "^\.(dcm|DCM)$" } | Select-Object -First 1
                if ($hasDcm) { $topDirsWithDcm += $_ }
            }
            if ($topDirsWithDcm.Count -gt 0) {
                $usePacsDicomdir = $true
                foreach ($d in $topDirsWithDcm) {
                    $dest = Join-Path $discStaging $d.Name
                    $null = cmd /c "mklink /J `"$dest`" `"$($d.FullName)`"" 2>&1
                    if (-not (Test-Path $dest)) {
                        Copy-Item -Path $d.FullName -Destination $dest -Recurse -Force
                    }
                    $dicomRootFolders += $d.Name
                    $dirCount = (Get-ChildItem -Path $dest -Recurse -File).Count
                    Log "[OK] $($d.Name)/ -> root ($dirCount files) [junction]" 25
                }
                Copy-Item -Path $pacsDicomdir -Destination (Join-Path $discStaging "DICOMDIR") -Force
                $dSize = [math]::Round((Get-Item (Join-Path $discStaging "DICOMDIR")).Length / 1KB)
                Log "[OK] PACS DICOMDIR ($dSize KB)" 28
            }
        }

        # Fallback: no PACS DICOMDIR — copy DICOM into Weasis/DICOM/
        if (-not $usePacsDicomdir) {
            $firstDcm = $allDcmFiles[0]
            $dicomSourceRoot = $null
            $checkPath = $firstDcm.DirectoryName
            while ($checkPath -and $checkPath.Length -gt $extractDir.Length) {
                if ((Split-Path -Leaf $checkPath) -match "^(DICOM|dicom|IMAGES|images)$") {
                    $dicomSourceRoot = $checkPath; break
                }
                $checkPath = Split-Path -Parent $checkPath
            }
            if ($dicomSourceRoot) {
                $destDicom = Join-Path $contentDir (Split-Path -Leaf $dicomSourceRoot)
                $null = cmd /c "mklink /J `"$destDicom`" `"$dicomSourceRoot`"" 2>&1
                if (-not (Test-Path $destDicom)) {
                    Copy-Item -Path $dicomSourceRoot -Destination $destDicom -Recurse -Force
                }
            } else {
                $dicomDir = Join-Path $contentDir "DICOM"
                New-Item -ItemType Directory -Path $dicomDir -Force | Out-Null
                foreach ($f in $allDcmFiles) {
                    $relPath = $f.FullName.Substring($extractDir.Length).TrimStart('\', '/')
                    $destPath = Join-Path $dicomDir $relPath
                    $destDir2 = Split-Path -Parent $destPath
                    if (-not (Test-Path $destDir2)) { New-Item -ItemType Directory -Path $destDir2 -Force | Out-Null }
                    Copy-Item -Path $f.FullName -Destination $destPath -Force
                }
            }
            Log "[OK] DICOM -> Weasis/DICOM/" 28
        }

        # ======== STEP 5: PATIENT INFO + DISC LABEL ========
        UpdateStatus ($s.StepPatient)
        Log ">>> $($s.StepPatient)" 29
        $dicomSearchDir = $null
        # Check disc root first (PACS DICOMDIR layout: DIR000/ at root)
        if ($dicomRootFolders -and $dicomRootFolders.Count -gt 0) {
            $dicomSearchDir = Join-Path $discStaging $dicomRootFolders[0]
        }
        # Fallback: Weasis/DICOM/
        if (-not $dicomSearchDir -or -not (Test-Path $dicomSearchDir)) {
            $dicomSearchDir = Join-Path $contentDir "DICOM"
        }
        if (-not (Test-Path $dicomSearchDir)) {
            $dicomSearchDir = Get-ChildItem -Path $contentDir -Directory | Where-Object {
                $_.Name -match "^(DICOM|dicom|IMAGES|images)$"
            } | Select-Object -First 1 -ExpandProperty FullName
        }
        $uniquePatients = @{}
        if ($dicomSearchDir) {
            $foldersChecked = @{}
            $allDcmForLabel = @()
            Get-ChildItem -Path $dicomSearchDir -Recurse -File | ForEach-Object {
                if ($_.Extension -match "^\.(dcm|DCM)$") { $allDcmForLabel += $_ }
                elseif ($_.Extension -eq "" -and $_.Length -gt 132) {
                    try {
                        $buf2 = New-Object byte[] 132
                        $fs = [System.IO.File]::OpenRead($_.FullName)
                        $fs.Read($buf2, 0, 132) | Out-Null; $fs.Close()
                        if ([System.Text.Encoding]::ASCII.GetString($buf2, 128, 4) -eq "DICM") { $allDcmForLabel += $_ }
                    } catch {}
                }
                if ($allDcmForLabel.Count -ge 50) { return }
            }
            foreach ($dcmFile in $allDcmForLabel) {
                $folder = $dcmFile.DirectoryName
                if ($foldersChecked.ContainsKey($folder)) { continue }
                $foldersChecked[$folder] = $true
                $info = Read-DicomPatientInfo -filePath $dcmFile.FullName
                if ($info.PatientName) {
                    $key = $info.PatientName.ToUpper().Trim()
                    if (-not $uniquePatients.ContainsKey($key)) { $uniquePatients[$key] = $info }
                }
                if ($uniquePatients.Count -gt 1) { break }
                if ($foldersChecked.Count -ge 20) { break }
            }
        }
        if ($uniquePatients.Count -gt 1) {
            $discLabel = "Multiple"
        } elseif ($uniquePatients.Count -eq 1) {
            $pInfo = $uniquePatients.Values | Select-Object -First 1
            $discLabel = Format-DiscLabel -patientName $pInfo.PatientName -studyDate $pInfo.StudyDate
            UpdateInfo $discLabel
        }
        Log "[OK] $discLabel" 30

        # ======== STEP 6: COPY WEASIS (junctions for large dirs) ========
        UpdateStatus ($s.StepWeasis)
        Log ">>> $($s.StepWeasis)" 32
        $excludeNames = @("viewer-mac.app", "autorun.inf", "viewer-win32.exe")
        $copyDirs = @("conf")  # dirs that get modified — must be real copies
        $junctionCount = 0; $copyCount = 0
        $items = Get-ChildItem -Path $weasisDir
        foreach ($item in $items) {
            if ($excludeNames -contains $item.Name) { continue }
            $destPath = Join-Path $contentDir $item.Name
            if ($item.PSIsContainer) {
                if ($copyDirs -contains $item.Name) {
                    Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force
                    $copyCount++
                } else {
                    $null = cmd /c "mklink /J `"$destPath`" `"$($item.FullName)`"" 2>&1
                    if (Test-Path $destPath) { $junctionCount++ }
                    else { Copy-Item -Path $item.FullName -Destination $destPath -Recurse -Force; $copyCount++ }
                }
            } else {
                Copy-Item -Path $item.FullName -Destination $destPath -Force
                $copyCount++
            }
        }
        $jreInfo = @()
        if (Test-Path (Join-Path $contentDir "jre\windows\bin\java.exe")) { $jreInfo += "x86" }
        if (Test-Path (Join-Path $contentDir "jre\windows-x64\bin\java.exe")) { $jreInfo += "x64" }
        Log "[OK] Weasis: ${junctionCount}J + ${copyCount}C (JRE: $($jreInfo -join ' + '))" 48

        # ======== STEP 7: TEMPLATES ========
        UpdateStatus ($s.StepTemplates)
        Log ">>> $($s.StepTemplates)" 50
        # Generate autorun.inf at disc root
        $autoLabel = if ($discLabel) { $discLabel } else { "DICOM Viewer" }
        $autorunContent = "[autorun]`r`nopen=Weasis\start-weasis.bat`r`nicon=Weasis\weasis.ico`r`nlabel=$autoLabel`r`naction=Open DICOM Viewer"
        [System.IO.File]::WriteAllText((Join-Path $discStaging "autorun.inf"), $autorunContent, [System.Text.Encoding]::ASCII)
        # Copy templates into Weasis/
        Copy-Item -Path (Join-Path $templatesDir "start-weasis.bat") -Destination $contentDir -Force
        Copy-Item -Path (Join-Path $templatesDir "splash-loader.ps1") -Destination $contentDir -Force
        $readmeHtml = Join-Path $templatesDir "README.html"
        if (Test-Path $readmeHtml) { Copy-Item -Path $readmeHtml -Destination $contentDir -Force }
        # Tutorial script + images
        $tutorialScript = Join-Path $templatesDir "tutorial.ps1"
        if (Test-Path $tutorialScript) { Copy-Item -Path $tutorialScript -Destination $contentDir -Force }
        $tutorialSrc = Join-Path $templatesDir "tutorial"
        if (Test-Path $tutorialSrc) {
            $tutorialDest = Join-Path $contentDir "tutorial"
            New-Item -ItemType Directory -Path $tutorialDest -Force | Out-Null
            Get-ChildItem "$tutorialSrc\?.png" | Copy-Item -Destination $tutorialDest -Force
        }
        Log "[OK] autorun.inf + start-weasis.bat + splash-loader.ps1 + tutorial.ps1" 53

        # ======== STEP 8: LAUNCHER WRAPPER ========
        UpdateStatus ($s.StepLauncher)
        Log ">>> $($s.StepLauncher)" 54
        # Copy icon
        $iconSrc = Join-Path $templatesDir "weasis.ico"
        if (Test-Path $iconSrc) { Copy-Item $iconSrc -Destination $contentDir -Force }
        # Copy bat wrapper to root
        $wrapperSrc = Join-Path $templatesDir "Weasis Viewer.bat"
        if (Test-Path $wrapperSrc) { Copy-Item $wrapperSrc -Destination $discStaging -Force }
        # Create .lnk shortcut at disc root
        try {
            $lnkPath = Join-Path $discStaging "Weasis Viewer.lnk"
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($lnkPath)
            $shortcut.TargetPath = "$env:SystemRoot\System32\cmd.exe"
            $shortcut.Arguments = '/c "Weasis\start-weasis.bat"'
            $shortcut.WorkingDirectory = ""
            $shortcut.WindowStyle = 7
            $shortcut.Description = "DICOM Viewer"
            $shortcut.Save()
            Log "[OK] Launcher (.lnk + .bat + .ico)" 57
        } catch {
            Log "[!] Shortcut: $($_.Exception.Message)" 57
        }

        # ======== STEP 9: DICOMDIR ========
        UpdateStatus ($s.StepDicomdir)
        Log ">>> $($s.StepDicomdir)" 58

        if ($usePacsDicomdir) {
            # PACS DICOMDIR already copied in STEP 4 — skip dcmmkdir entirely
            Log "[OK] PACS DICOMDIR already at root (correct paths, full metadata)" 65

            # Configure Weasis to scan DICOM at disc root (../DIR000 etc.)
            $configPath2 = Join-Path $contentDir "conf\config.properties"
            if (Test-Path $configPath2) {
                $configContent2 = [System.IO.File]::ReadAllText($configPath2, [System.Text.Encoding]::UTF8)
                $extraDirs2 = ($dicomRootFolders | ForEach-Object { "../$_" }) -join ","
                $oldLine2 = "weasis.portable.dicom.directory=dicom,DICOM,IMAGES,images"
                $newLine2 = "weasis.portable.dicom.directory=dicom,DICOM,IMAGES,images,$extraDirs2"
                $configContent2 = $configContent2.Replace($oldLine2, $newLine2)
                [System.IO.File]::WriteAllText($configPath2, $configContent2, [System.Text.Encoding]::UTF8)
                Log "[OK] config: $extraDirs2" 65
            }
        } else {
            # Fallback: generate DICOMDIR with dcmmkdir
            $dcmmkdir = Join-Path $dcmtkDir "bin\dcmmkdir.exe"
            if (-not (Test-Path $dcmmkdir)) {
                Log "[!] $($s.DcmtkMissing)" 65
            } else {
                $dicomDir3 = Join-Path $contentDir "DICOM"
                if (Test-Path $dicomDir3) {
                    # Strip .DCM extensions
                    $renamed = 0
                    Get-ChildItem -Path $dicomDir3 -Recurse -File | Where-Object {
                        $_.Extension -match "^\.(dcm|DCM)$"
                    } | ForEach-Object {
                        Rename-Item -Path $_.FullName -NewName $_.BaseName -ErrorAction SilentlyContinue
                        $renamed++
                    }
                    if ($renamed -gt 0) { Log "[OK] .DCM ext removed: $renamed" 60 }

                    # Make directory names DICOM-compliant
                    Get-ChildItem -Path $dicomDir3 -Recurse -Directory | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
                        $newName = $_.Name.ToUpper() -replace '[^A-Z0-9_]', ''
                        if ($newName.Length -gt 8) { $newName = $newName.Substring(0, 8) }
                        if ($newName -eq '') { $newName = 'D' + (Get-Random -Minimum 1000 -Maximum 9999) }
                        if ($_.Name -cne $newName) {
                            $parentDir = Split-Path $_.FullName
                            $tempName = "_ren_" + (Get-Random -Minimum 10000 -Maximum 99999)
                            $tempPath2 = Join-Path $parentDir $tempName
                            Rename-Item -Path $_.FullName -NewName $tempName -ErrorAction SilentlyContinue
                            if (Test-Path $tempPath2) { Rename-Item -Path $tempPath2 -NewName $newName -ErrorAction SilentlyContinue }
                        }
                    }

                    # Make file names DICOM-compliant
                    Get-ChildItem -Path $dicomDir3 -Recurse -File | ForEach-Object {
                        $newName = ($_.BaseName.ToUpper()) -replace '[^A-Z0-9_]', ''
                        if ($newName.Length -gt 8) { $newName = $newName.Substring(0, 8) }
                        if ($newName -eq '') { $newName = 'F' + (Get-Random -Minimum 10000 -Maximum 99999) }
                        $ext = $_.Extension
                        $fullNew = $newName + $ext
                        if ($_.Name -cne $fullNew) {
                            $parentDir = Split-Path $_.FullName
                            $tempName = "_ren_" + (Get-Random -Minimum 10000 -Maximum 99999)
                            $tempPath3 = Join-Path $parentDir $tempName
                            Rename-Item -Path $_.FullName -NewName $tempName -ErrorAction SilentlyContinue
                            if (Test-Path $tempPath3) { Rename-Item -Path $tempPath3 -NewName $fullNew -ErrorAction SilentlyContinue }
                        }
                    }
                    Log "[OK] DICOM-compliant names" 62

                    # Set DICOM dictionary
                    $dictPath = Join-Path $dcmtkDir "share\dcmtk-3.7.0\dicom.dic"
                    if (-not (Test-Path $dictPath)) { $dictPath = Join-Path $dcmtkDir "share\dcmtk\dicom.dic" }
                    if (Test-Path $dictPath) { $env:DCMDICTPATH = $dictPath }

                    # Run dcmmkdir
                    $dicomdirPath = Join-Path $discStaging "DICOMDIR"
                    $cmdLine = "cd /d `"$discStaging`" && `"$dcmmkdir`" +r +id Weasis\DICOM +D DICOMDIR +I -Pgp"
                    $output = cmd /c $cmdLine 2>&1

                    if ($LASTEXITCODE -eq 0 -and (Test-Path $dicomdirPath)) {
                        $dSize = [math]::Round((Get-Item $dicomdirPath).Length / 1KB)
                        Log "[OK] DICOMDIR ($dSize KB)" 65
                    } else {
                        Log "[!] dcmmkdir failed (code: $LASTEXITCODE)" 65
                    }
                } else {
                    Log "[!] No DICOM folder in staging" 65
                }
            }
        }

        # ======== STEP 10: SUMMARY ========
        UpdateStatus ($s.StepSummary)
        Log ">>> $($s.StepSummary)" 66
        # .NET GetFiles follows NTFS junctions (Get-ChildItem -Recurse does NOT)
        try {
            $allFiles = [System.IO.DirectoryInfo]::new($discStaging).GetFiles('*', [System.IO.SearchOption]::AllDirectories)
            $totalSize = ($allFiles | Measure-Object -Property Length -Sum).Sum
        } catch {
            $totalSize = (Get-ChildItem -Path $discStaging -Recurse -File -Force | Measure-Object -Property Length -Sum).Sum
        }
        $totalSizeMB = [math]::Round($totalSize / 1MB, 1)
        $dvdCapacity = 4700
        $percentage = [math]::Round(($totalSizeMB / $dvdCapacity) * 100, 1)
        $infoText = $s.DiscSize -f $totalSizeMB, $percentage
        if ($discLabel -and $discLabel -ne "DICOM") { $infoText = "$discLabel  |  $infoText" }
        UpdateInfo $infoText
        Log "[OK] $totalSizeMB MB ($percentage%)" 68

        if ($totalSizeMB -gt $dvdCapacity) {
            Log "[X] $($s.OverCapacity)" 68
            throw $s.OverCapacity
        }

        # ======== STEP 11: BURN OR SIMULATE ========
        if ($simulate) {
            # --- SIMULATE ---
            UpdateStatus ($s.StepSimulate)
            Log ">>> $($s.StepSimulate)" 69
            $speedKBs = $burnSpeed * 1385
            $totalSizeKB = $totalSize / 1024
            $estimatedSec = [math]::Max([math]::Ceiling($totalSizeKB / $speedKBs), 3)
            $steps2 = $estimatedSec * 4
            $sleepMs = [math]::Round(($estimatedSec * 1000) / $steps2)
            $lastPhase = ""

            for ($i = 1; $i -le $steps2; $i++) {
                $pct = $i / $steps2
                $guiPct = 69 + [int]($pct * 28)
                $writtenMB = [math]::Round($totalSizeMB * $pct, 1)

                # Phase detection
                if ($pct -lt 0.06) { $phase = $s.PhaseLeadIn }
                elseif ($pct -lt 0.92) { $phase = $s.PhaseWrite }
                else { $phase = $s.PhaseLeadOut }

                if ($phase -ne $lastPhase) {
                    Log "[SIM] $phase" $guiPct
                    $lastPhase = $phase
                }

                $pctInt = [int]($pct * 100)
                UpdateStatus "$phase - $pctInt% ($writtenMB / $totalSizeMB MB)"
                UpdateProgress $guiPct
                Start-Sleep -Milliseconds $sleepMs
            }

            UpdateProgress 97
            UpdateStatus ($s.PhaseDone)
            Log "[OK] $($s.SimSuccess)" 97
            $sync.BurnSuccess = $true

        } else {
            # --- REAL BURN (with retry loop for disc swap) ---
            $burnDone = $false
            while (-not $burnDone) {
                UpdateStatus ($s.StepBurn)
                Log ">>> $($s.StepBurn)" 69

                # Find optical drive
                $discMaster = New-Object -ComObject IMAPI2.MsftDiscMaster2
                if ($discMaster.Count -eq 0) { throw $s.NoDrive }

                $recorder = $null
                if ($driveID) {
                    for ($di = 0; $di -lt $discMaster.Count; $di++) {
                        if ($discMaster.Item($di) -eq $driveID) {
                            $recorder = New-Object -ComObject IMAPI2.MsftDiscRecorder2
                            $recorder.InitializeDiscRecorder($discMaster.Item($di))
                            break
                        }
                    }
                }
                if (-not $recorder) {
                    $recorder = New-Object -ComObject IMAPI2.MsftDiscRecorder2
                    $recorder.InitializeDiscRecorder($discMaster.Item(0))
                }
                $driveLetter = ($recorder.VolumePathNames | Select-Object -First 1)
                $driveVendor = "$($recorder.VendorId.Trim()) $($recorder.ProductId.Trim())"
                Log "[OK] $driveVendor ($driveLetter)" 70

                # Release discMaster - no longer needed after drive selection
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($discMaster) | Out-Null } catch {}

                # Create disc format
                $discFormat = New-Object -ComObject IMAPI2.MsftDiscFormat2Data
                $discFormat.Recorder = $recorder
                $discFormat.ClientName = "WeasisBurn"

                # Check media - if not blank, allow disc swap and retry
                if (-not $discFormat.CurrentMediaStatus) {
                    Log "[!] $($s.NoDisc)" 70
                    Log "[..] $($s.DiscSwap)" 70

                    # Release COM objects before waiting
                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($discFormat) | Out-Null } catch {}
                    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($recorder) | Out-Null } catch {}
                    [GC]::Collect()

                    # Signal UI to show Continue/Close buttons
                    $sync.DiscError = $true

                    # Wait for user to click Continue or Close
                    while ($sync.DiscError -and -not $sync.CancelBurn) {
                        Start-Sleep -Milliseconds 500
                    }

                    # User clicked Close - abort
                    if ($sync.CancelBurn) {
                        throw $s.NoDisc
                    }

                    # User clicked Continue - retry burn loop
                    $sync.RetryBurn = $false
                    continue
                }

                # Create file system image
                $fsImage = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
                $fsImage.FileSystemsToCreate = 3  # ISO9660 + Joliet
                $fsImage.VolumeName = if ($discLabel) { $discLabel } else { "DICOM" }
                $fsImage.FreeMediaBlocks = $discFormat.TotalSectorsOnMedia
                $capacityMB = [math]::Round($discFormat.TotalSectorsOnMedia * 2048 / 1MB)
                Log "[OK] $capacityMB MB" 72

                # Add files
                Log "[..] Adding files..." 73
                $fsImage.Root.AddTree($discStaging, $false)

                # Generate ISO
                Log "[..] ISO image..." 75
                $result2 = $fsImage.CreateResultImage()
                $stream = $result2.ImageStream

                # Set speed
                $speedKBs = $burnSpeed * 1385
                try { $discFormat.SetWriteSpeed($speedKBs, $false) } catch {}
                Log "[OK] ${burnSpeed}x ($speedKBs KB/s)" 77

                # BURN (blocking) - progress estimated by UI timer based on size/speed
                $speedKBs = $burnSpeed * 1385
                $totalSizeKB = $totalSize / 1024
                # Add 90 sec overhead for IMAPI2 lead-in (laser calibration) + lead-out (session close/finalize)
                $sync.BurnEstimatedSec = [math]::Max([math]::Ceiling($totalSizeKB / $speedKBs) + 90, 30)
                $sync.BurnStartTime = [DateTime]::Now
                $sync.BurnTotalSizeMB = $totalSizeMB
                $sync.BurnSpeed = $burnSpeed
                UpdateStatus ($s.Burning)
                Log "[..] $($s.Burning)" 78
                $discFormat.Write($stream)
                $sync.BurnStartTime = $null  # signal burn finished

                # Release COM objects BEFORE eject (prevents Windows "Insert disc" dialog)
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($stream) | Out-Null } catch {}
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($result2) | Out-Null } catch {}
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsImage) | Out-Null } catch {}
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($discFormat) | Out-Null } catch {}

                # Disable Media Change Notification before eject
                try { $recorder.DisableMcn() } catch {}

                # Eject
                UpdateStatus ($s.Ejecting)
                Log "[..] $($s.Ejecting)" 95
                $recorder.EjectMedia()

                # Re-enable MCN and release recorder
                try { $recorder.EnableMcn() } catch {}
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($recorder) | Out-Null } catch {}
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()

                # Close Windows "Insert disc" dialog if it appears after eject
                Start-Sleep -Seconds 2
                try {
                    $wsh = New-Object -ComObject WScript.Shell
                    foreach ($dlgTitle in @("Insert disc", "Introduceti un disc", "Introduceți un disc")) {
                        if ($wsh.AppActivate($dlgTitle)) {
                            Start-Sleep -Milliseconds 300
                            $wsh.SendKeys("{ESCAPE}")
                            break
                        }
                    }
                } catch {}

                Log "[OK] $($s.Success)" 97
                $sync.BurnSuccess = $true
                $burnDone = $true
            }  # end while (-not $burnDone)
        }

        # ======== STEP 12: CLEANUP ========
        UpdateStatus ($s.StepCleanup)
        Log ">>> $($s.StepCleanup)" 98
        Start-Sleep -Seconds 1
        if (Test-Path $tempRoot) {
            # Remove NTFS junctions BEFORE Remove-Item -Recurse!
            # PowerShell follows junctions and would delete source files in tools/weasis-portable/
            try {
                Get-ChildItem -Path $tempRoot -Recurse -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
                    ForEach-Object { cmd /c "rmdir `"$($_.FullName)`"" 2>$null }
            } catch {}
            try { Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue } catch {}
            if (Test-Path $tempRoot) {
                Start-Sleep -Seconds 2
                Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
            }
        }

        # Delete source ZIP on successful burn
        if ($sync.BurnSuccess -and (Test-Path $zipPath)) {
            try {
                Remove-Item -Force $zipPath
                Log "[OK] $($s.DeleteZip): $(Split-Path -Leaf $zipPath)" 99
            } catch {
                Log "[!] ZIP: $($_.Exception.Message)" 99
            }
        }

        Log "[OK] 100%" 100
        $sync.Success = $true
        $sync.Completed = $true

    } catch {
        # Cleanup COM objects on error to prevent Windows "Insert disc" dialog
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($stream) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($result2) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($fsImage) | Out-Null } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($discFormat) | Out-Null } catch {}
        try { $recorder.EnableMcn() } catch {}
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($recorder) | Out-Null } catch {}
        [GC]::Collect()

        Log "[X] $($_.Exception.Message)" -1
        $sync.Failed = $true
        $sync.Completed = $true
    }
}

# ============================================================================
# START WORKER
# ============================================================================
function Start-Worker {
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = "MTA"
    $runspace.Open()

    $psCmd = [PowerShell]::Create()
    $psCmd.Runspace = $runspace
    $psCmd.AddScript($workerScript).AddArgument($syncHash) | Out-Null
    $script:asyncResult = $psCmd.BeginInvoke()
    $script:workerRunspace = $runspace
    $script:workerCmd = $psCmd
}

# ============================================================================
# TIMERS
# ============================================================================

# --- Animated dots for status ---
$script:dotIndex = 0
$script:discErrorShown = $false

# Pre-create frozen brushes (reused in timer callbacks — avoids GC churn)
$script:brushOrange  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#FFA726")); $script:brushOrange.Freeze()
$script:brushGreen   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#0F9B58")); $script:brushGreen.Freeze()
$script:brushSuccess = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#4CAF50")); $script:brushSuccess.Freeze()
$script:brushError   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#FF5252")); $script:brushError.Freeze()
$script:brushDefault = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#CCCCCC")); $script:brushDefault.Freeze()
$animTimer = New-Object System.Windows.Threading.DispatcherTimer
$animTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$animTimer.Add_Tick({
    $script:dotIndex = ($script:dotIndex + 1) % 4
    $dots = "." * $script:dotIndex
    $base = $txtStatus.Text -replace '\.+$', ''
    if ($base -and -not $syncHash.Completed) {
        $txtStatus.Text = "$base$dots"
    }
})

# --- Completion check ---
$completionTimer = New-Object System.Windows.Threading.DispatcherTimer
$completionTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$completionTimer.Add_Tick({
    # Update progress bar during burn (time-based estimation)
    if ($syncHash.BurnStartTime -and -not $syncHash.Completed) {
        $elapsed = ([DateTime]::Now - $syncHash.BurnStartTime).TotalSeconds
        $estimated = $syncHash.BurnEstimatedSec
        if ($estimated -gt 0) {
            $pct = [math]::Min($elapsed / $estimated, 0.99)
            # Map 0-99% burn progress to 78-95 on progress bar
            $progressBar.Value = 78 + [int]($pct * 17)
            # Phase detection + status text
            $writtenMB = [math]::Round($syncHash.BurnTotalSizeMB * $pct, 1)
            $pctInt = [int]($pct * 100)
            if ($pct -lt 0.06) { $phase = $strings.PhaseLeadIn }
            elseif ($pct -lt 0.92) { $phase = $strings.PhaseWrite }
            else { $phase = $strings.PhaseLeadOut }
            $txtStatus.Text = "$phase - $pctInt% ($writtenMB / $($syncHash.BurnTotalSizeMB) MB)"
        }
    }
    # --- DISC ERROR: show Continue + Close (no countdown) ---
    if ($syncHash.DiscError -and -not $script:discErrorShown) {
        $script:discErrorShown = $true
        $animTimer.Stop()  # Stop dot animation (prevents overwriting status text)
        $txtStatus.Text = $strings.NoDisc
        $txtStatus.Foreground = $script:brushOrange
        $progressBar.Foreground = $script:brushOrange
        $btnContinue.Content = $strings.BtnContinue
        $btnContinue.Visibility = "Visible"
        $btnDone.Content = $strings.BtnClose
        $btnDone.Visibility = "Visible"
    }

    # --- DISC ERROR cleared (user clicked Continue) - hide buttons, resume ---
    if (-not $syncHash.DiscError -and $script:discErrorShown) {
        $script:discErrorShown = $false
        $animTimer.Start()  # Resume dot animation
        $btnContinue.Visibility = "Collapsed"
        $btnDone.Visibility = "Collapsed"
        $txtStatus.Foreground = $script:brushDefault
        $progressBar.Foreground = $script:brushGreen
    }

    if (-not $syncHash.Completed) { return }
    $completionTimer.Stop()
    $animTimer.Stop()

    if ($syncHash.Success) {
        # SUCCESS
        $msg = if ($syncHash.SimulateOnly) { $strings.SimSuccess } else { $strings.Success }
        $txtStatus.Text = $msg
        $txtStatus.Foreground = $script:brushSuccess
        $btnContinue.Visibility = "Collapsed"
        $btnDone.Visibility = "Visible"

        # Auto-close after 5 seconds
        $script:closeCount = 5
        $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
        $closeTimer.Interval = [TimeSpan]::FromSeconds(1)
        $closeTimer.Add_Tick({
            $script:closeCount--
            if ($script:closeCount -le 0) {
                $this.Stop()
                $window.Close()
            } else {
                $btnDone.Content = "$($strings.BtnClose) ($($script:closeCount))"
            }
        })
        $btnDone.Content = "$($strings.BtnClose) ($($script:closeCount))"
        $closeTimer.Start()
    } else {
        # ERROR
        $txtStatus.Foreground = $script:brushError
        $progressBar.Foreground = $script:brushError
        $btnContinue.Visibility = "Collapsed"
        $btnDone.Visibility = "Visible"
    }
})

# ============================================================================
# EVENT HANDLERS
# ============================================================================

$window.Add_Loaded({
    Start-Worker
    $animTimer.Start()
    $completionTimer.Start()
})

# --- Continue button: signal worker to retry burn ---
$btnContinue.Add_Click({ param($s,$e)
    $syncHash.DiscError = $false
    $syncHash.RetryBurn = $true
})

# --- Close/Done button ---
$btnDone.Add_Click({ param($s,$e)
    if ($syncHash.DiscError) {
        # Worker is waiting for disc swap - signal cancel
        $syncHash.CancelBurn = $true
        $syncHash.DiscError = $false
    }
    $window.Close()
})

$btnMinimize.Add_Click({ param($s,$e)
    $window.WindowState = [System.Windows.WindowState]::Minimized
})

$btnCloseWin.Add_Click({ param($s,$e)
    if ($syncHash.DiscError) {
        $syncHash.CancelBurn = $true
        $syncHash.DiscError = $false
    }
    $window.Close()
})

$window.Add_MouseLeftButtonDown({ $window.DragMove() })

# ============================================================================
# HIDE PARENT CMD WINDOW
# ============================================================================
try {
    Add-Type -Name Win32 -Namespace Native -MemberDefinition @'
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    $consoleWindow = [Native.Win32]::GetConsoleWindow()
    if ($consoleWindow -ne [IntPtr]::Zero) {
        [Native.Win32]::ShowWindow($consoleWindow, 0) | Out-Null
    }
} catch { }

# ============================================================================
# SHOW WINDOW
# ============================================================================
$window.ShowDialog() | Out-Null

# Cleanup runspace
if ($script:workerRunspace) {
    try { $script:workerRunspace.Close(); $script:workerRunspace.Dispose() } catch { }
}

exit 0
