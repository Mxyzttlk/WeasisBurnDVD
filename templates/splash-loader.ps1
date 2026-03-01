# ============================================================================
# Weasis DICOM Viewer - WPF Splash Screen & Loader
# Copyright (c) 2026 Bejenaru Adrian. All rights reserved.
# Unauthorized copying, modification, or distribution is strictly prohibited.
# ============================================================================

param(
    [Parameter(Mandatory=$true)][string]$DiscPath,
    [Parameter(Mandatory=$true)][string]$JreDir,
    [Parameter(Mandatory=$true)][string]$ArchLabel
)

# Loader checksum (do not remove)
$_lcs = "QXV0aG9yOiBCZWplbmFydSBBZHJpYW4gfCBXZWFzaXNCdXJu"
# Normalize DiscPath (removes trailing "\." from BAT workaround for CMD quote escaping)
$DiscPath = [System.IO.Path]::GetFullPath($DiscPath)

# Determine Java memory based on architecture (avoids CMD quoting issues with -Xmx)
if ($ArchLabel -eq "64-bit") {
    $JavaMem = "-Xms64m -Xmx2048m"
} else {
    $JavaMem = "-Xms64m -Xmx768m"
}

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
                Loading       = "Se incarca"
                WaitMessage   = "Va rugam asteptati cateva minute..."
                SpaceCheck    = "Verificare spatiu disc..."
                SpaceOk       = "Spatiu disponibil: {0} MB"
                SpaceFail     = "Spatiu insuficient! Necesar: {0} MB, Disponibil: {1} MB"
                Cleaning      = "Se sterge copia veche..."
                FolderLocked  = "Folder blocat (alt Weasis ruleaza?)"
                FolderFail    = "Nu s-a putut crea folderul temporar"
                Copying       = "Se copiaza de pe disc..."
                JarFiles      = "Fisiere JAR"
                BundleOSGI    = "Bundle OSGI"
                Config        = "Configuratie"
                Resources     = "Resurse"
                JreArch       = "JRE {0}"
                DicomLink     = "DICOM"
                DicomJuncFail = "Junction DICOM nu a reusit, se copiaza..."
                Verifying     = "Verificare fisiere..."
                VerifyOk      = "Toate fisierele copiate cu succes!"
                VerifyFail    = "Copierea a esuat! Fisiere lipsa."
                CacheClean    = "Curatare cache OSGI..."
                Launching     = "Se lanseaza Weasis..."
                LaunchOk      = "Weasis pornit cu succes!"
                LaunchFail    = "Weasis nu a pornit! (posibil blocat de antivirus)"
                Fallback      = "Se trece la lansare directa de pe disc..."
                FallbackSlow  = "Poate dura 3-5 minute..."
                Warn32Title   = "Arhitectura calculatorului este pe 32 de biti."
                Warn32Msg     = "Se recomanda utilizarea aplicatiei RadiAnt pentru o experienta optima."
                BtnContinue   = "Continua"
                BtnClose      = "Inchide"
                OsWarnTitle   = "Sistemul de operare nu indeplineste cerintele"
                OsWarnMsg     = "Weasis necesita Windows 10 sau mai nou. Recomandam sa folositi aplicatia RadiAnt pentru o experienta optima."
                RamBlockTitle = "Memorie RAM insuficienta"
                RamBlockMsg   = "Calculatorul are doar {0} GB RAM. Weasis necesita minim 2 GB. Recomandam sa folositi aplicatia RadiAnt pentru o experienta optima."
                RamWarnTitle  = "Memorie RAM redusa"
                RamWarnMsg    = "Calculatorul are doar {0} GB RAM. Weasis poate functiona lent. Recomandam sa folositi aplicatia RadiAnt pentru o experienta optima."
            }
        }
        "ru" {
            return @{
                Loading       = "Загрузка"
                WaitMessage   = "Пожалуйста, подождите несколько минут..."
                SpaceCheck    = "Проверка свободного места..."
                SpaceOk       = "Доступно: {0} МБ"
                SpaceFail     = "Недостаточно места! Необходимо: {0} МБ, Доступно: {1} МБ"
                Cleaning      = "Удаление старой копии..."
                FolderLocked  = "Папка заблокирована (другой Weasis запущен?)"
                FolderFail    = "Не удалось создать временную папку"
                Copying       = "Копирование с диска..."
                JarFiles      = "Файлы JAR"
                BundleOSGI    = "Модули OSGI"
                Config        = "Конфигурация"
                Resources     = "Ресурсы"
                JreArch       = "JRE {0}"
                DicomLink     = "DICOM"
                DicomJuncFail = "Ссылка DICOM не создана, копирование..."
                Verifying     = "Проверка файлов..."
                VerifyOk      = "Все файлы скопированы!"
                VerifyFail    = "Ошибка копирования! Файлы отсутствуют."
                CacheClean    = "Очистка кэша OSGI..."
                Launching     = "Запуск Weasis..."
                LaunchOk      = "Weasis успешно запущен!"
                LaunchFail    = "Weasis не запустился! (возможно, заблокирован антивирусом)"
                Fallback      = "Запуск напрямую с диска..."
                FallbackSlow  = "Это может занять 3-5 минут..."
                Warn32Title   = "Архитектура компьютера — 32 бита."
                Warn32Msg     = "Рекомендуется использовать приложение RadiAnt для оптимальной работы."
                BtnContinue   = "Продолжить"
                BtnClose      = "Закрыть"
                OsWarnTitle   = "Операционная система не соответствует требованиям"
                OsWarnMsg     = "Weasis требует Windows 10 или новее. Рекомендуем использовать приложение RadiAnt для оптимальной работы."
                RamBlockTitle = "Недостаточно оперативной памяти"
                RamBlockMsg   = "На компьютере только {0} ГБ RAM. Weasis требует минимум 2 ГБ. Рекомендуем использовать приложение RadiAnt для оптимальной работы."
                RamWarnTitle  = "Мало оперативной памяти"
                RamWarnMsg    = "На компьютере только {0} ГБ RAM. Weasis может работать медленно. Рекомендуем использовать приложение RadiAnt для оптимальной работы."
            }
        }
        default {
            return @{
                Loading       = "Loading"
                WaitMessage   = "Please wait a few minutes..."
                SpaceCheck    = "Checking disk space..."
                SpaceOk       = "Available space: {0} MB"
                SpaceFail     = "Insufficient space! Required: {0} MB, Available: {1} MB"
                Cleaning      = "Removing old copy..."
                FolderLocked  = "Folder locked (another Weasis running?)"
                FolderFail    = "Cannot create temporary folder"
                Copying       = "Copying from disc..."
                JarFiles      = "JAR files"
                BundleOSGI    = "OSGI Bundles"
                Config        = "Configuration"
                Resources     = "Resources"
                JreArch       = "JRE {0}"
                DicomLink     = "DICOM"
                DicomJuncFail = "DICOM junction failed, copying..."
                Verifying     = "Verifying files..."
                VerifyOk      = "All files copied successfully!"
                VerifyFail    = "Copy failed! Missing files."
                CacheClean    = "Cleaning OSGI cache..."
                Launching     = "Launching Weasis..."
                LaunchOk      = "Weasis started successfully!"
                LaunchFail    = "Weasis failed to start! (possibly blocked by antivirus)"
                Fallback      = "Switching to direct disc launch..."
                FallbackSlow  = "This may take 3-5 minutes..."
                Warn32Title   = "Computer architecture is 32-bit."
                Warn32Msg     = "We recommend using RadiAnt for an optimal experience."
                BtnContinue   = "Continue"
                BtnClose      = "Close"
                OsWarnTitle   = "Operating system does not meet requirements"
                OsWarnMsg     = "Weasis requires Windows 10 or newer. We recommend using RadiAnt for an optimal experience."
                RamBlockTitle = "Insufficient RAM"
                RamBlockMsg   = "This computer has only {0} GB RAM. Weasis requires at least 2 GB. We recommend using RadiAnt for an optimal experience."
                RamWarnTitle  = "Low RAM"
                RamWarnMsg    = "This computer has only {0} GB RAM. Weasis may run slowly. We recommend using RadiAnt for an optimal experience."
            }
        }
    }
}

$strings = Get-Strings
$is32bit = ($ArchLabel -eq "32-bit")

# Detect OS version: Windows 10 = 10.0, Windows 8.1 = 6.3, Windows 7 = 6.1
$osVersion = [System.Environment]::OSVersion.Version
$isOldOS = ($osVersion.Major -lt 10)

# Detect total RAM in GB
$ramBytes = (Get-CimInstance -ClassName Win32_ComputerSystem -Property TotalPhysicalMemory).TotalPhysicalMemory
$ramGB = [math]::Round($ramBytes / 1GB, 1)
$isRamBlock = ($ramGB -lt 2)       # < 2 GB: block completely
$isRamWarn  = ($ramGB -ge 2 -and $ramGB -lt 4)  # 2-3 GB: warning with continue

# ============================================================================
# WPF XAML LAYOUT
# ============================================================================
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Weasis v3.7.1"
        Width="500" Height="420"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        ResizeMode="NoResize"
        Topmost="True"
        ShowInTaskbar="True">

    <Border CornerRadius="12" Background="#1E1E1E" BorderBrush="#333333" BorderThickness="1">
        <Grid>
            <!-- WINDOW CONTROL BUTTONS (top-right) -->
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top"
                        Margin="0,8,8,0" Panel.ZIndex="10">
                <Button x:Name="btnMinimize" Content="&#x2014;" Width="32" Height="24" Margin="0,0,4,0"
                        FontSize="13" Cursor="Hand" Foreground="#888888" Background="Transparent" BorderThickness="0"
                        ToolTip="Minimize">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="border" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="0">
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
                        FontSize="13" Cursor="Hand" Foreground="#888888" Background="Transparent" BorderThickness="0"
                        ToolTip="Close">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="border" Background="{TemplateBinding Background}"
                                    CornerRadius="4" Padding="0">
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

            <!-- CONTENT AREA -->
            <Grid Margin="24">

            <!-- OS WARNING PANEL (Windows < 10) -->
            <StackPanel x:Name="panelOsWarning" Visibility="Collapsed" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,24">
                    <Image x:Name="imgLogoOs" Width="40" Height="40" Margin="0,0,10,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Weasis v3.7.1" FontSize="26" FontWeight="SemiBold" Foreground="#0F9B58" VerticalAlignment="Center"/>
                </StackPanel>

                <TextBlock Text="&#x26A0;" FontSize="40" Foreground="#FF6B35" HorizontalAlignment="Center" Margin="0,0,0,12"/>

                <TextBlock x:Name="txtOsWarnTitle" Text="" FontSize="15" FontWeight="SemiBold"
                           Foreground="#FF6B35" HorizontalAlignment="Center" TextAlignment="Center"
                           Margin="20,0,20,10" TextWrapping="Wrap"/>
                <TextBlock x:Name="txtOsWarnMsg" Text="" FontSize="13"
                           Foreground="#CCCCCC" HorizontalAlignment="Center" TextAlignment="Center"
                           Margin="20,0,20,28" TextWrapping="Wrap"/>

                <Button x:Name="btnOsClose" Content="Close" Width="160" Height="40"
                        FontSize="14" FontWeight="SemiBold" Cursor="Hand"
                        Foreground="White" Background="#D32F2F" BorderThickness="0">
                    <Button.Template>
                        <ControlTemplate TargetType="Button">
                            <Border x:Name="border" Background="{TemplateBinding Background}"
                                    CornerRadius="6" Padding="12,6">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </ControlTemplate>
                    </Button.Template>
                </Button>
            </StackPanel>

            <!-- RAM WARNING PANEL (< 2 GB block, 2-3 GB warning) -->
            <StackPanel x:Name="panelRamWarning" Visibility="Collapsed" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,24">
                    <Image x:Name="imgLogoRam" Width="40" Height="40" Margin="0,0,10,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Weasis v3.7.1" FontSize="26" FontWeight="SemiBold" Foreground="#0F9B58" VerticalAlignment="Center"/>
                </StackPanel>

                <TextBlock Text="&#x26A0;" FontSize="40" Foreground="#FF6B35" HorizontalAlignment="Center" Margin="0,0,0,12"/>

                <TextBlock x:Name="txtRamWarnTitle" Text="" FontSize="15" FontWeight="SemiBold"
                           Foreground="#FF6B35" HorizontalAlignment="Center" TextAlignment="Center"
                           Margin="20,0,20,10" TextWrapping="Wrap"/>
                <TextBlock x:Name="txtRamWarnMsg" Text="" FontSize="13"
                           Foreground="#CCCCCC" HorizontalAlignment="Center" TextAlignment="Center"
                           Margin="20,0,20,28" TextWrapping="Wrap"/>

                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <Button x:Name="btnRamContinue" Content="Continue" Width="120" Height="36" Margin="0,0,16,0"
                            FontSize="14" FontWeight="SemiBold" Cursor="Hand"
                            Foreground="White" Background="#0F9B58" BorderThickness="0">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="border" Background="{TemplateBinding Background}"
                                        CornerRadius="6" Padding="12,6">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                    <Button x:Name="btnRamClose" Content="Close" Width="120" Height="36"
                            FontSize="14" FontWeight="SemiBold" Cursor="Hand"
                            Foreground="White" Background="#D32F2F" BorderThickness="0">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="border" Background="{TemplateBinding Background}"
                                        CornerRadius="6" Padding="12,6">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                </StackPanel>
            </StackPanel>

            <!-- WARNING PANEL (32-bit) -->
            <StackPanel x:Name="panelWarning" Visibility="Collapsed" VerticalAlignment="Center">
                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,24">
                    <Image x:Name="imgLogoWarn" Width="40" Height="40" Margin="0,0,10,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Weasis v3.7.1" FontSize="26" FontWeight="SemiBold" Foreground="#0F9B58" VerticalAlignment="Center"/>
                </StackPanel>

                <TextBlock x:Name="txtWarn32Title" Text="" FontSize="15" FontWeight="SemiBold"
                           Foreground="#FFD740" HorizontalAlignment="Center" TextAlignment="Center"
                           Margin="20,0,20,6" TextWrapping="Wrap"/>
                <TextBlock x:Name="txtWarn32Msg" Text="" FontSize="13"
                           Foreground="#CCCCCC" HorizontalAlignment="Center" TextAlignment="Center"
                           Margin="20,0,20,28" TextWrapping="Wrap"/>

                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <Button x:Name="btnContinue" Content="Continue" Width="120" Height="36" Margin="0,0,16,0"
                            FontSize="14" FontWeight="SemiBold" Cursor="Hand"
                            Foreground="White" Background="#0F9B58" BorderThickness="0">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="border" Background="{TemplateBinding Background}"
                                        CornerRadius="6" Padding="12,6">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                    <Button x:Name="btnClose" Content="Close" Width="120" Height="36"
                            FontSize="14" FontWeight="SemiBold" Cursor="Hand"
                            Foreground="White" Background="#D32F2F" BorderThickness="0">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border x:Name="border" Background="{TemplateBinding Background}"
                                        CornerRadius="6" Padding="12,6">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                </StackPanel>
            </StackPanel>

            <!-- LOADING PANEL -->
            <Grid x:Name="panelLoading" Visibility="Collapsed">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="10"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="10"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <!-- Row 0: Logo + Title -->
                <StackPanel Grid.Row="0" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,0,0,12">
                    <Image x:Name="imgLogo" Width="40" Height="40" Margin="0,0,10,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Weasis v3.7.1" FontSize="26" FontWeight="SemiBold"
                               Foreground="#0F9B58" VerticalAlignment="Center"/>
                </StackPanel>

                <!-- Row 1: Loading animated text -->
                <TextBlock Grid.Row="1" x:Name="txtLoading" Text="Loading..."
                           FontSize="16" Foreground="#CCCCCC" HorizontalAlignment="Center" Margin="0,0,0,4"/>

                <!-- Row 2: Wait message -->
                <TextBlock Grid.Row="2" x:Name="txtWait" Text=""
                           FontSize="12" Foreground="#888888" HorizontalAlignment="Center" Margin="0,0,0,4"/>

                <!-- Row 4: Progress bar -->
                <Grid Grid.Row="4">
                    <ProgressBar x:Name="progressBar" Height="6" Minimum="0" Maximum="100" Value="0"
                                 Background="#333333" Foreground="#0F9B58" BorderThickness="0"/>
                </Grid>

                <!-- Row 6: Log area -->
                <Border Grid.Row="6" Background="#151515" CornerRadius="6" Padding="10" Margin="0,4,0,8">
                    <ScrollViewer x:Name="scrollLog" VerticalScrollBarVisibility="Auto">
                        <TextBlock x:Name="txtLog" FontFamily="Consolas" FontSize="11"
                                   Foreground="#AAAAAA" TextWrapping="Wrap"/>
                    </ScrollViewer>
                </Border>

                <!-- Row 7: Architecture label -->
                <TextBlock Grid.Row="7" x:Name="txtArch" Text=""
                           FontSize="10" Foreground="#555555" HorizontalAlignment="Right"/>
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
$panelOsWarning  = $window.FindName("panelOsWarning")
$panelRamWarning = $window.FindName("panelRamWarning")
$panelWarning    = $window.FindName("panelWarning")
$panelLoading    = $window.FindName("panelLoading")
$imgLogo         = $window.FindName("imgLogo")
$imgLogoWarn     = $window.FindName("imgLogoWarn")
$imgLogoOs       = $window.FindName("imgLogoOs")
$imgLogoRam      = $window.FindName("imgLogoRam")
$txtLoading      = $window.FindName("txtLoading")
$txtWait         = $window.FindName("txtWait")
$progressBar     = $window.FindName("progressBar")
$txtLog          = $window.FindName("txtLog")
$scrollLog       = $window.FindName("scrollLog")
$txtArch         = $window.FindName("txtArch")
$txtWarn32Title  = $window.FindName("txtWarn32Title")
$txtWarn32Msg    = $window.FindName("txtWarn32Msg")
$txtOsWarnTitle  = $window.FindName("txtOsWarnTitle")
$txtOsWarnMsg    = $window.FindName("txtOsWarnMsg")
$txtRamWarnTitle = $window.FindName("txtRamWarnTitle")
$txtRamWarnMsg   = $window.FindName("txtRamWarnMsg")
$btnContinue     = $window.FindName("btnContinue")
$btnClose        = $window.FindName("btnClose")
$btnOsClose      = $window.FindName("btnOsClose")
$btnRamContinue  = $window.FindName("btnRamContinue")
$btnRamClose     = $window.FindName("btnRamClose")
$btnMinimize     = $window.FindName("btnMinimize")
$btnCloseWin     = $window.FindName("btnCloseWin")

# Set localized text
$txtWait.Text = $strings.WaitMessage
$txtArch.Text = "JRE: $ArchLabel"
$txtWarn32Title.Text = $strings.Warn32Title
$txtWarn32Msg.Text = $strings.Warn32Msg
$txtOsWarnTitle.Text = $strings.OsWarnTitle
$txtOsWarnMsg.Text = $strings.OsWarnMsg
$btnContinue.Content = $strings.BtnContinue
$btnClose.Content = $strings.BtnClose
$btnOsClose.Content = $strings.BtnClose
$btnRamContinue.Content = $strings.BtnContinue
$btnRamClose.Content = $strings.BtnClose

# Set RAM warning text (block or warn)
if ($isRamBlock) {
    $txtRamWarnTitle.Text = $strings.RamBlockTitle -f $ramGB
    $txtRamWarnMsg.Text = $strings.RamBlockMsg -f $ramGB
    $btnRamContinue.Visibility = "Collapsed"  # < 2 GB: no Continue, only Close
} elseif ($isRamWarn) {
    $txtRamWarnTitle.Text = $strings.RamWarnTitle -f $ramGB
    $txtRamWarnMsg.Text = $strings.RamWarnMsg -f $ramGB
}

# Load logo image
$logoPath = Join-Path $DiscPath "resources\images\logo-button.png"
if (Test-Path $logoPath) {
    try {
        $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
        $bitmap.BeginInit()
        $bitmap.UriSource = New-Object System.Uri($logoPath, [System.UriKind]::Absolute)
        $bitmap.DecodePixelWidth = 40
        $bitmap.EndInit()
        $bitmap.Freeze()
        $imgLogo.Source = $bitmap
        $imgLogoWarn.Source = $bitmap
        $imgLogoOs.Source = $bitmap
        $imgLogoRam.Source = $bitmap
    } catch { }
}

# ============================================================================
# SHARED STATE FOR BACKGROUND WORKER
# ============================================================================
$script:workerStarted = $false
$syncHash = [hashtable]::Synchronized(@{
    Window      = $window
    TxtLog      = $txtLog
    TxtLoading  = $txtLoading
    ProgressBar = $progressBar
    ScrollLog   = $scrollLog
    Completed   = $false
    ExitCode    = 1
    FallbackDVD = $false
    Strings     = $strings
    DiscPath    = $DiscPath
    JreDir      = $JreDir
    JavaMem     = $JavaMem
    ArchLabel   = $ArchLabel
})

# ============================================================================
# BACKGROUND COPY & LAUNCH LOGIC (runs in separate runspace)
# ============================================================================
$workerScript = {
    param($sync)

    $s = $sync.Strings
    $discPath = $sync.DiscPath.TrimEnd('\')
    $jreDir = $sync.JreDir
    $javaMem = $sync.JavaMem
    $tempDir = Join-Path $env:TEMP "weasis-dvd"
    $needMB = 500

    function Log([string]$msg, [int]$progress = -1) {
        $sync.Window.Dispatcher.Invoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [Action]{
                if ($sync.TxtLog.Inlines.Count -gt 0) {
                    $sync.TxtLog.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
                }
                $run = New-Object System.Windows.Documents.Run($msg)

                $color = "#AAAAAA"
                if     ($msg -match '^\[OK\]')      { $color = "#4CAF50" }
                elseif ($msg -match '^\[X\]')        { $color = "#FF5252" }
                elseif ($msg -match '^\[!\]')        { $color = "#FFD740" }
                elseif ($msg -match '^\[\d+/\d+\]')  { $color = "#0F9B58" }

                $run.Foreground = New-Object System.Windows.Media.SolidColorBrush(
                    [System.Windows.Media.ColorConverter]::ConvertFromString($color))
                $sync.TxtLog.Inlines.Add($run)
                $sync.ScrollLog.ScrollToEnd()

                if ($progress -ge 0) {
                    $sync.ProgressBar.Value = $progress
                }
            }
        )
    }

    try {
        # STEP 1: Check free space
        Log ("[..] " + $s.SpaceCheck) 5
        try {
            $drive = $env:TEMP.Substring(0, 1)
            $freeBytes = (Get-PSDrive $drive).Free
            $freeMB = [math]::Floor($freeBytes / 1MB)

            if ($freeMB -lt $needMB) {
                Log ("[X] " + ($s.SpaceFail -f $needMB, $freeMB)) 5
                $sync.FallbackDVD = $true
                $sync.Completed = $true
                return
            }
            Log ("[OK] " + ($s.SpaceOk -f $freeMB)) 10
        } catch {
            Log "[!] Space check skipped" 10
        }

        # STEP 2: Clean old temp folder
        if (Test-Path $tempDir) {
            Log ("[..] " + $s.Cleaning) 12
            $dicomJunction = Join-Path $tempDir "DICOM"
            if (Test-Path $dicomJunction) {
                cmd /c "rmdir `"$dicomJunction`"" 2>$null
            }
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            if (Test-Path $tempDir) {
                Log ("[X] " + $s.FolderLocked) 12
                $sync.FallbackDVD = $true
                $sync.Completed = $true
                return
            }
        }

        # STEP 3: Create temp folder
        try {
            New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
        } catch {
            Log ("[X] " + $s.FolderFail) 12
            $sync.FallbackDVD = $true
            $sync.Completed = $true
            return
        }

        # STEP 4: Copy files (6 steps)
        Log ("[..] " + $s.Copying) 15

        # [1/6] JARs
        Log ("[1/6] " + $s.JarFiles) 18
        Copy-Item (Join-Path $discPath "weasis-launcher.jar") $tempDir -Force -ErrorAction Stop
        Copy-Item (Join-Path $discPath "felix.jar") $tempDir -Force -ErrorAction Stop
        Copy-Item (Join-Path $discPath "substance.jar") $tempDir -Force -ErrorAction Stop
        Log ("[OK] " + $s.JarFiles) 25

        # [2/6] OSGI Bundles
        Log ("[2/6] " + $s.BundleOSGI) 28
        Copy-Item (Join-Path $discPath "bundle") (Join-Path $tempDir "bundle") -Recurse -Force -ErrorAction Stop
        $bi18n = Join-Path $discPath "bundle-i18n"
        if (Test-Path $bi18n) {
            Copy-Item $bi18n (Join-Path $tempDir "bundle-i18n") -Recurse -Force -ErrorAction SilentlyContinue
        }
        Log ("[OK] " + $s.BundleOSGI) 42

        # [3/6] Config
        Log ("[3/6] " + $s.Config) 45
        Copy-Item (Join-Path $discPath "conf") (Join-Path $tempDir "conf") -Recurse -Force -ErrorAction Stop
        Log ("[OK] " + $s.Config) 52

        # [4/6] Resources
        Log ("[4/6] " + $s.Resources) 55
        $resPath = Join-Path $discPath "resources"
        if (Test-Path $resPath) {
            Copy-Item $resPath (Join-Path $tempDir "resources") -Recurse -Force -ErrorAction SilentlyContinue
        }
        Log ("[OK] " + $s.Resources) 60

        # [5/6] JRE
        Log ("[5/6] " + ($s.JreArch -f $sync.ArchLabel)) 63
        $jreSrc = Join-Path $discPath $jreDir
        $jreDstParent = Join-Path $tempDir (Split-Path $jreDir)
        if (-not (Test-Path $jreDstParent)) {
            New-Item -ItemType Directory -Path $jreDstParent -Force | Out-Null
        }
        Copy-Item $jreSrc (Join-Path $tempDir $jreDir) -Recurse -Force -ErrorAction Stop
        Log ("[OK] " + ($s.JreArch -f $sync.ArchLabel)) 80

        # [6/6] DICOM junction
        Log ("[6/6] " + $s.DicomLink) 83
        $discRoot = Split-Path $discPath -Parent
        $dicomSrc = $null
        # Check disc root first (PACS DICOMDIR layout: DIR000/ at root)
        foreach ($dn in @("DIR000","DICOM","dicom","IMAGES","images")) {
            $candidate = Join-Path $discRoot $dn
            if (Test-Path $candidate) { $dicomSrc = $candidate; break }
        }
        # Fallback: check inside Weasis folder
        if (-not $dicomSrc) {
            foreach ($dn in @("DICOM","dicom","IMAGES","images")) {
                $candidate = Join-Path $discPath $dn
                if (Test-Path $candidate) { $dicomSrc = $candidate; break }
            }
        }
        if ($dicomSrc) {
            $dicomDst = Join-Path $tempDir "DICOM"
            $null = cmd /c "mklink /J `"$dicomDst`" `"$dicomSrc`"" 2>&1
            if (-not (Test-Path $dicomDst)) {
                Log ("[!] " + $s.DicomJuncFail) 83
                Copy-Item $dicomSrc $dicomDst -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Log ("[OK] " + $s.DicomLink) 87

        # STEP 5: Verify essential files
        Log ("[..] " + $s.Verifying) 90
        $essentials = @(
            (Join-Path $tempDir "weasis-launcher.jar"),
            (Join-Path $tempDir "felix.jar"),
            (Join-Path $tempDir "substance.jar"),
            (Join-Path $tempDir "$jreDir\bin\javaw.exe"),
            (Join-Path $tempDir "conf\config.properties")
        )
        $allOk = $true
        foreach ($f in $essentials) {
            if (-not (Test-Path $f)) { $allOk = $false; break }
        }
        if (-not $allOk) {
            Log ("[X] " + $s.VerifyFail) 90
            $dj = Join-Path $tempDir "DICOM"
            if (Test-Path $dj) { cmd /c "rmdir `"$dj`"" 2>$null }
            Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
            $sync.FallbackDVD = $true
            $sync.Completed = $true
            return
        }
        Log ("[OK] " + $s.VerifyOk) 93

        # STEP 6: Clean OSGI cache
        Log ("[..] " + $s.CacheClean) 95
        Get-ChildItem "$env:USERPROFILE\.weasis\cache-*" -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }

        # STEP 7: Launch Weasis
        Log ("[..] " + $s.Launching) 97
        $javaw = Join-Path $tempDir "$jreDir\bin\javaw.exe"
        $cp = (Join-Path $tempDir "weasis-launcher.jar") + ";" + (Join-Path $tempDir "felix.jar") + ";" + (Join-Path $tempDir "substance.jar")
        $portDir = $tempDir + "\."
        $args = "$javaMem -Dweasis.portable.dir=`"$portDir`" -Dgosh.args=`"-sc telnetd -p 17179 start`" -cp `"$cp`" org.weasis.launcher.WeasisLauncher `$dicom:get --portable"

        Start-Process -FilePath $javaw -ArgumentList $args -WindowStyle Hidden

        # Verify javaw started (antivirus may block)
        Start-Sleep -Seconds 3
        $javawProc = Get-Process -Name "javaw" -ErrorAction SilentlyContinue
        if (-not $javawProc) {
            Log ("[X] " + $s.LaunchFail) 97
            $sync.FallbackDVD = $true
            $sync.Completed = $true
            return
        }

        Log ("[OK] " + $s.LaunchOk) 100
        $sync.ExitCode = 0
        $sync.Completed = $true

    } catch {
        Log ("[X] Error: $($_.Exception.Message)") -1
        $sync.FallbackDVD = $true
        $sync.Completed = $true
    }
}

# ============================================================================
# FUNCTION: Start the background worker
# ============================================================================
function Start-Worker {
    if ($script:workerStarted) { return }
    $script:workerStarted = $true

    $panelLoading.Visibility = "Visible"

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
# WINDOW EVENTS & TIMERS
# ============================================================================

# --- Animated loading dots ---
$script:dotIndex = 0
$dotBase = $strings.Loading
$animTimer = New-Object System.Windows.Threading.DispatcherTimer
$animTimer.Interval = [TimeSpan]::FromMilliseconds(400)
$animTimer.Add_Tick({
    $script:dotIndex = ($script:dotIndex + 1) % 4
    $dots = "." * $script:dotIndex
    $txtLoading.Text = "$dotBase$dots"
})

# --- Completion check timer ---
$completionTimer = New-Object System.Windows.Threading.DispatcherTimer
$completionTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$completionTimer.Add_Tick({
    if ($syncHash.Completed) {
        $completionTimer.Stop()
        $animTimer.Stop()

        if ($syncHash.FallbackDVD) {
            # Show fallback message, launch from DVD, then close
            $txtLoading.Text = $strings.Fallback
            $txtLoading.Foreground = (New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString("#FFD740")))

            # Launch directly from DVD
            $javaw = Join-Path $syncHash.DiscPath "$($syncHash.JreDir)\bin\javaw.exe"
            $dp = $syncHash.DiscPath.TrimEnd('\')
            $cp = "$dp\weasis-launcher.jar;$dp\felix.jar;$dp\substance.jar"
            $portDir = "$dp\."
            $fArgs = "$($syncHash.JavaMem) -Dweasis.portable.dir=`"$portDir`" -Dgosh.args=`"-sc telnetd -p 17179 start`" -cp `"$cp`" org.weasis.launcher.WeasisLauncher `$dicom:get --portable"

            # Clean OSGI cache
            Get-ChildItem "$env:USERPROFILE\.weasis\cache-*" -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item -Recurse -Force $_.FullName -ErrorAction SilentlyContinue }

            Start-Process -FilePath $javaw -ArgumentList $fArgs -WindowStyle Hidden

            # Close after 3 seconds
            $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
            $closeTimer.Interval = [TimeSpan]::FromSeconds(3)
            $closeTimer.Add_Tick({
                $this.Stop()
                $window.Close()
            })
            $closeTimer.Start()
        } else {
            # Success — close after 1.5 seconds
            $txtLoading.Text = $strings.LaunchOk
            $txtLoading.Foreground = (New-Object System.Windows.Media.SolidColorBrush(
                [System.Windows.Media.ColorConverter]::ConvertFromString("#4CAF50")))

            # Launch tutorial (separate process, non-blocking)
            # DiscPath is already the Weasis/ folder (set by start-weasis.bat %~dp0)
            $tutorialPath = Join-Path $syncHash.DiscPath "tutorial.ps1"
            if (Test-Path $tutorialPath) {
                try {
                    $discArg = $syncHash.DiscPath.TrimEnd('\') + "\."
                    Start-Process -FilePath "powershell.exe" -ArgumentList @(
                        "-sta", "-nologo", "-noprofile", "-ExecutionPolicy", "Bypass",
                        "-File", "`"$tutorialPath`"",
                        "-DiscPath", "`"$discArg`""
                    ) -WindowStyle Hidden
                } catch { }
            }

            $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
            $closeTimer.Interval = [TimeSpan]::FromSeconds(1.5)
            $closeTimer.Add_Tick({
                $this.Stop()
                $window.Close()
            })
            $closeTimer.Start()
        }
    }
})

# --- Window Loaded event ---
# Priority: OS check > RAM check > 32-bit check > loading
$window.Add_Loaded({
    if ($isOldOS) {
        # Windows < 10: show OS warning (only Close button)
        $panelOsWarning.Visibility = "Visible"
    } elseif ($isRamBlock -or $isRamWarn) {
        # RAM < 2 GB (block) or 2-3 GB (warning with continue)
        $panelRamWarning.Visibility = "Visible"
    } elseif ($is32bit) {
        # 32-bit: show warning (Continue / Close)
        $panelWarning.Visibility = "Visible"
    } else {
        # All checks passed: go straight to loading
        Start-Worker
        $animTimer.Start()
        $completionTimer.Start()
    }
})

# --- OS warning button (Close only) ---
$btnOsClose.Add_Click({
    $syncHash.ExitCode = 0
    $window.Close()
})

# --- RAM warning buttons ---
$btnRamContinue.Add_Click({
    # 2-3 GB: user chose to continue despite low RAM
    $panelRamWarning.Visibility = "Collapsed"
    if ($is32bit) {
        # Also show 32-bit warning
        $panelWarning.Visibility = "Visible"
    } else {
        Start-Worker
        $animTimer.Start()
        $completionTimer.Start()
    }
})

$btnRamClose.Add_Click({
    $syncHash.ExitCode = 0
    $window.Close()
})

# --- 32-bit warning buttons ---
$btnContinue.Add_Click({
    $panelWarning.Visibility = "Collapsed"
    Start-Worker
    $animTimer.Start()
    $completionTimer.Start()
})

$btnClose.Add_Click({
    $syncHash.ExitCode = 0   # User closed intentionally — BAT should exit cleanly
    $window.Close()
})

# --- Window control buttons (top-right) ---
$btnMinimize.Add_Click({
    $window.WindowState = [System.Windows.WindowState]::Minimized
})

$btnCloseWin.Add_Click({
    $syncHash.ExitCode = 0   # User closed intentionally — BAT should exit cleanly
    $window.Close()
})

# --- Allow dragging the borderless window ---
$window.Add_MouseLeftButtonDown({
    $window.DragMove()
})

# ============================================================================
# HIDE PARENT CMD WINDOW (WPF splash replaces it as the UI)
# ============================================================================
try {
    Add-Type -Name Win32 -Namespace Native -MemberDefinition @'
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    $consoleWindow = [Native.Win32]::GetConsoleWindow()
    if ($consoleWindow -ne [IntPtr]::Zero) {
        [Native.Win32]::ShowWindow($consoleWindow, 0) | Out-Null  # SW_HIDE = 0
    }
} catch { }

# ============================================================================
# SHOW WINDOW (blocks until closed)
# ============================================================================
$window.ShowDialog() | Out-Null

# Cleanup runspace
if ($script:workerRunspace) {
    try {
        $script:workerRunspace.Close()
        $script:workerRunspace.Dispose()
    } catch { }
}

# Exit with appropriate code
if ($syncHash.FallbackDVD) {
    exit 0   # Fallback handled internally, BAT doesn't need to do anything
}
exit $syncHash.ExitCode
