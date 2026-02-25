# ============================================================================
# PACS Burner - Aplicatie WPF + WebView2
# Copyright (c) 2026 Bejenaru Adrian. All rights reserved.
# Unauthorized copying, modification, or distribution is strictly prohibited.
# ============================================================================

param(
    [string]$SettingsFile = ""
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Paths
# ============================================================================

$AppDir       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot  = Split-Path -Parent $AppDir
$ToolsDir     = Join-Path $ProjectRoot "tools"
$DownloadsDir = Join-Path $ProjectRoot "downloads"
$WebView2Dir  = Join-Path $ToolsDir "webview2"
$BurnScript   = Join-Path $ProjectRoot "scripts\burn.ps1"
$BurnGuiScript = Join-Path $ProjectRoot "scripts\burn-gui.ps1"

if (-not $SettingsFile) {
    $SettingsFile = Join-Path $AppDir "settings.json"
}

# Session validation hash
$script:_svh = "QXV0aG9yOiBCZWplbmFydSBBZHJpYW4gfCBXZWFzaXNCdXJu"
# WebView2 user data (cookies, cache) - persistent between sessions
$WebView2DataDir = Join-Path $env:APPDATA "WeasisBurn\WebView2Data"

# ============================================================================
# Verify WebView2 SDK
# ============================================================================

$wv2CoreDll = Join-Path $WebView2Dir "Microsoft.Web.WebView2.Core.dll"
$wv2WpfDll  = Join-Path $WebView2Dir "Microsoft.Web.WebView2.Wpf.dll"
$wv2Loader  = Join-Path $WebView2Dir "WebView2Loader.dll"

if (-not (Test-Path $wv2CoreDll) -or -not (Test-Path $wv2WpfDll) -or -not (Test-Path $wv2Loader)) {
    [System.Windows.MessageBox]::Show(
        "WebView2 SDK nu este instalat.`n`nRuleaza scripts\setup.ps1 mai intai.",
        "PACS Burner - Eroare",
        "OK", "Error"
    )
    exit 1
}

# ============================================================================
# Load assemblies
# ============================================================================

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms

# Win32 API for forcing window to foreground (Activate() alone doesn't work from background)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Focus {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    public const int SW_RESTORE = 9;
    public const int SW_SHOW = 5;
}
"@

# WebView2 DLLs - WebView2Loader.dll must be in same directory or PATH
$env:Path = "$WebView2Dir;$env:Path"
Add-Type -Path $wv2CoreDll
Add-Type -Path $wv2WpfDll

# Ensure downloads directory exists
New-Item -ItemType Directory -Path $DownloadsDir -Force | Out-Null
New-Item -ItemType Directory -Path $WebView2DataDir -Force | Out-Null

# ============================================================================
# Settings management
# ============================================================================

function Get-DefaultSettings {
    return @{
        networks = @(
            @{
                name     = "External"
                url      = "http://imagistica.scr.md/portal/"
                username = ""
                password = ""
            },
            @{
                name     = "Internal"
                url      = "http://192.168.22.10/portal/"
                username = ""
                password = ""
            }
        )
        lastNetwork   = 0
        autoLogin     = $true
        autoUnlock    = $true
        autoExcludeViewer = $true
        burnSpeed     = 4
        burnDriveId   = ""
        simulateOnly  = $false
    }
}

function Load-Settings {
    if (Test-Path $SettingsFile) {
        try {
            $json = Get-Content $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            # Migrate: add missing properties from defaults (for settings added in newer versions)
            $defaults = Get-DefaultSettings
            foreach ($key in $defaults.Keys) {
                if (-not ($json.PSObject.Properties.Name -contains $key)) {
                    $json | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
                }
            }
            return $json
        } catch {
            Write-Host "Eroare la citirea settings.json: $($_.Exception.Message)"
        }
    }
    return Get-DefaultSettings
}

function Save-Settings {
    param($settings)
    $settings | ConvertTo-Json -Depth 5 | Set-Content -Path $SettingsFile -Encoding UTF8
}

function Encrypt-Password {
    param([string]$plainText)
    if ([string]::IsNullOrEmpty($plainText)) { return "" }
    $secure = ConvertTo-SecureString $plainText -AsPlainText -Force
    return ConvertFrom-SecureString $secure
}

function Decrypt-Password {
    param([string]$encrypted)
    if ([string]::IsNullOrEmpty($encrypted)) { return "" }
    try {
        $secure = ConvertTo-SecureString $encrypted
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    } catch {
        return ""
    }
}

$script:Settings = Load-Settings

# ============================================================================
# XAML - Main Window
# ============================================================================

[xml]$mainXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PACS Burner - Weasis"
        Width="1200" Height="800"
        MinWidth="800" MinHeight="500"
        WindowStartupLocation="CenterScreen"
        Background="#1E1E1E">
    <Window.Resources>
        <Style x:Key="ToolbarBtn" TargetType="Button">
            <Setter Property="Background" Value="#333333"/>
            <Setter Property="Foreground" Value="#CCCCCC"/>
            <Setter Property="BorderBrush" Value="#555555"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="Margin" Value="2,0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#4A4A4A"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#0F9B58"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#2A2A2A"/>
                                <Setter Property="Foreground" Value="#666666"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="BurnBtn" TargetType="Button">
            <Setter Property="Background" Value="#0F9B58"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="16,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="border" Background="{TemplateBinding Background}"
                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#12B866"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="border" Property="Background" Value="#0A7A42"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="border" Property="Background" Value="#2A2A2A"/>
                                <Setter Property="Foreground" Value="#666666"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- TOOLBAR -->
        <Border Grid.Row="0" Background="#2D2D2D" BorderBrush="#3F3F3F" BorderThickness="0,0,0,1" Padding="6,4">
            <DockPanel>
                <!-- Right side buttons -->
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                    <Button x:Name="btnSettings" Style="{StaticResource ToolbarBtn}" ToolTip="Setari retele">
                        <TextBlock Text="&#x2699; Setari" FontSize="13"/>
                    </Button>
                    <Button x:Name="btnRefresh" Style="{StaticResource ToolbarBtn}" ToolTip="Reincarca pagina" Margin="4,0,0,0">
                        <TextBlock Text="&#x21BB;" FontSize="15"/>
                    </Button>
                </StackPanel>

                <!-- Left side: network selector -->
                <StackPanel Orientation="Horizontal">
                    <TextBlock Text="Retea:" Foreground="#AAAAAA" VerticalAlignment="Center" Margin="4,0,6,0" FontSize="13"/>
                    <ComboBox x:Name="cmbNetwork" Width="250" FontSize="13" VerticalAlignment="Center"/>
                    <Button x:Name="btnConnect" Style="{StaticResource ToolbarBtn}" Margin="6,0,0,0">
                        <TextBlock Text="&#x27A4; Conectare" FontSize="13"/>
                    </Button>
                </StackPanel>
            </DockPanel>
        </Border>

        <!-- WEBVIEW2 HOST (Row 1) - control added programmatically -->
        <Border x:Name="webViewHost" Grid.Row="1" Background="#1E1E1E"/>

        <!-- STATUS BAR -->
        <Border Grid.Row="2" Background="#252526" BorderBrush="#3F3F3F" BorderThickness="0,1,0,0" Padding="8,5">
            <DockPanel>
                <!-- Right side: BURN button -->
                <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
                    <Button x:Name="btnOpenFolder" Style="{StaticResource ToolbarBtn}" ToolTip="Deschide folderul Downloads" Margin="0,0,4,0">
                        <TextBlock Text="&#x25A3;" FontSize="13"/>
                    </Button>
                    <Button x:Name="btnBurn" Style="{StaticResource BurnBtn}">
                        <TextBlock Text="&#x25CF; BURN DVD" FontSize="13"/>
                    </Button>
                </StackPanel>

                <!-- Left side: status -->
                <StackPanel Orientation="Horizontal">
                    <Ellipse x:Name="statusDot" Width="10" Height="10" Fill="#666666" Margin="0,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock x:Name="txtStatus" Text="Deconectat" Foreground="#AAAAAA" FontSize="12" VerticalAlignment="Center"/>
                    <TextBlock x:Name="txtZipInfo" Text="" Foreground="#0F9B58" FontSize="12" VerticalAlignment="Center" Margin="16,0,0,0"/>
                </StackPanel>
            </DockPanel>
        </Border>
    </Grid>
</Window>
"@

# ============================================================================
# XAML - Settings Dialog
# ============================================================================

[xml]$settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Setari PACS Burner"
        Width="550" Height="580"
        WindowStartupLocation="CenterOwner"
        ResizeMode="NoResize"
        Background="#1E1E1E">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <TextBlock Grid.Row="0" Text="Retele PACS" Foreground="White" FontSize="16" FontWeight="Bold" Margin="0,0,0,10"/>

        <!-- Network list + reorder buttons -->
        <Grid Grid.Row="1" Margin="0,0,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <ListBox x:Name="lstNetworks" Grid.Column="0" Background="#2D2D2D" Foreground="White"
                     BorderBrush="#555555" FontSize="13"/>
            <StackPanel Grid.Column="1" VerticalAlignment="Center" Margin="6,0,0,0">
                <Button x:Name="btnNetUp" Width="32" Height="32" Margin="0,2"
                        Background="#333333" Foreground="#CCCCCC" BorderBrush="#555555"
                        FontSize="14" ToolTip="Muta sus (prioritate mai mare)">
                    <TextBlock Text="&#x25B2;" FontSize="14"/>
                </Button>
                <Button x:Name="btnNetDown" Width="32" Height="32" Margin="0,2"
                        Background="#333333" Foreground="#CCCCCC" BorderBrush="#555555"
                        FontSize="14" ToolTip="Muta jos (prioritate mai mica)">
                    <TextBlock Text="&#x25BC;" FontSize="14"/>
                </Button>
            </StackPanel>
        </Grid>

        <!-- Edit form -->
        <Grid Grid.Row="2" Margin="0,4,0,8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="80"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Grid.Column="0" Text="Nume:" Foreground="#AAAAAA" VerticalAlignment="Center" Margin="0,2"/>
            <TextBox x:Name="txtNetName" Grid.Row="0" Grid.Column="1" Background="#333333" Foreground="White"
                     BorderBrush="#555555" Margin="0,2" Padding="4,2" FontSize="13"/>

            <TextBlock Grid.Row="1" Grid.Column="0" Text="URL:" Foreground="#AAAAAA" VerticalAlignment="Center" Margin="0,2"/>
            <TextBox x:Name="txtNetUrl" Grid.Row="1" Grid.Column="1" Background="#333333" Foreground="White"
                     BorderBrush="#555555" Margin="0,2" Padding="4,2" FontSize="13"/>

            <TextBlock Grid.Row="2" Grid.Column="0" Text="Username:" Foreground="#AAAAAA" VerticalAlignment="Center" Margin="0,2"/>
            <TextBox x:Name="txtNetUser" Grid.Row="2" Grid.Column="1" Background="#333333" Foreground="White"
                     BorderBrush="#555555" Margin="0,2" Padding="4,2" FontSize="13"/>

            <TextBlock Grid.Row="3" Grid.Column="0" Text="Parola:" Foreground="#AAAAAA" VerticalAlignment="Center" Margin="0,2"/>
            <PasswordBox x:Name="txtNetPass" Grid.Row="3" Grid.Column="1" Background="#333333" Foreground="White"
                         BorderBrush="#555555" Margin="0,2" Padding="4,2" FontSize="13"/>
        </Grid>

        <!-- Burning settings -->
        <StackPanel Grid.Row="3" Margin="0,4,0,8">
            <StackPanel.Resources>
                <Style TargetType="ComboBox">
                    <Setter Property="Background" Value="#333333"/>
                    <Setter Property="Foreground" Value="White"/>
                    <Setter Property="FontSize" Value="13"/>
                    <Setter Property="Margin" Value="0,2"/>
                    <Setter Property="Padding" Value="4,3"/>
                </Style>
                <Style TargetType="ComboBoxItem">
                    <Setter Property="Background" Value="#333333"/>
                    <Setter Property="Foreground" Value="White"/>
                    <Setter Property="Padding" Value="4,3"/>
                    <Style.Triggers>
                        <Trigger Property="IsHighlighted" Value="True">
                            <Setter Property="Background" Value="#0F9B58"/>
                        </Trigger>
                    </Style.Triggers>
                </Style>
            </StackPanel.Resources>
            <TextBlock Text="Burning" Foreground="White" FontSize="16" FontWeight="Bold" Margin="0,0,0,8"/>
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="80"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <TextBlock Grid.Row="0" Grid.Column="0" Text="Writer:" Foreground="#AAAAAA" VerticalAlignment="Center" Margin="0,2"/>
                <ComboBox x:Name="cmbBurnDrive" Grid.Row="0" Grid.Column="1"/>
                <Button x:Name="btnRefreshDrives" Grid.Row="0" Grid.Column="2" Width="32" Height="26" Margin="4,2,0,2"
                        Background="#333333" Foreground="#CCCCCC" BorderBrush="#555555" ToolTip="Detecteaza unitati">
                    <TextBlock Text="&#x21BB;" FontSize="13"/>
                </Button>

                <TextBlock Grid.Row="1" Grid.Column="0" Text="Viteza:" Foreground="#AAAAAA" VerticalAlignment="Center" Margin="0,2"/>
                <ComboBox x:Name="cmbBurnSpeed" Grid.Row="1" Grid.Column="1"/>
            </Grid>
        </StackPanel>

        <!-- Automation checkboxes -->
        <StackPanel Grid.Row="4" Margin="0,0,0,10">
            <CheckBox x:Name="chkAutoLogin" Content="Auto-login la conectare" Foreground="#CCCCCC" FontSize="12" Margin="0,2"/>
            <CheckBox x:Name="chkAutoUnlock" Content="Auto-deblocare sesiune" Foreground="#CCCCCC" FontSize="12" Margin="0,2"/>
            <CheckBox x:Name="chkAutoExclude" Content="Auto-bifare 'Exclude Viewer'" Foreground="#CCCCCC" FontSize="12" Margin="0,2"/>
            <CheckBox x:Name="chkSimulate" Content="Simulare (fara ardere pe disc)" Foreground="#FFA500" FontSize="12" Margin="0,6,0,2"/>
        </StackPanel>

        <!-- Buttons -->
        <StackPanel Grid.Row="5" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="btnNetAdd" Content="Adauga" Width="80" Margin="4,0" Padding="4,6"
                    Background="#333333" Foreground="#CCCCCC" BorderBrush="#555555"/>
            <Button x:Name="btnNetSave" Content="Salveaza" Width="80" Margin="4,0" Padding="4,6"
                    Background="#0F9B58" Foreground="White" BorderThickness="0"/>
            <Button x:Name="btnNetDelete" Content="Sterge" Width="80" Margin="4,0" Padding="4,6"
                    Background="#D32F2F" Foreground="White" BorderThickness="0"/>
            <Button x:Name="btnSettingsOk" Content="OK" Width="80" Margin="16,0,0,0" Padding="4,6"
                    Background="#333333" Foreground="#CCCCCC" BorderBrush="#555555"/>
        </StackPanel>
    </Grid>
</Window>
"@

# ============================================================================
# Create main window
# ============================================================================

$reader = [System.Xml.XmlNodeReader]::new($mainXaml)
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Get controls
$cmbNetwork   = $window.FindName("cmbNetwork")
$btnConnect   = $window.FindName("btnConnect")
$btnSettings  = $window.FindName("btnSettings")
$btnRefresh   = $window.FindName("btnRefresh")
$webViewHost  = $window.FindName("webViewHost")
$statusDot    = $window.FindName("statusDot")
$txtStatus    = $window.FindName("txtStatus")
$txtZipInfo   = $window.FindName("txtZipInfo")
$btnBurn      = $window.FindName("btnBurn")
$btnOpenFolder = $window.FindName("btnOpenFolder")

# ============================================================================
# WebView2 control
# ============================================================================

$script:webView = New-Object Microsoft.Web.WebView2.Wpf.WebView2
$script:webView.Visibility = [System.Windows.Visibility]::Visible

# Add WebView2 to the host border
$webViewHost.Child = $script:webView

# Track state
$script:currentZipPath = $null
$script:isNavigating = $false
$script:webViewReady = $false
$script:autoBurnPending = $false

# ============================================================================
# Initialize WebView2
# ============================================================================

function Initialize-WebView2 {
    try {
        # Event fires on UI thread when initialization completes
        $script:webView.Add_CoreWebView2InitializationCompleted({
            param($s, $e)
            if ($e.IsSuccess) {
                $script:webViewReady = $true
                Setup-WebView2Events
                Update-Status "Gata" "#0F9B58"

                # Auto-connect to last used network
                $lastNet = $script:Settings.lastNetwork
                $netCount = @($script:Settings.networks).Count
                if ($lastNet -ge 0 -and $lastNet -lt $netCount) {
                    Connect-ToNetwork $lastNet
                } elseif ($netCount -gt 0) {
                    Connect-ToNetwork 0
                }
            } else {
                $errMsg = "WebView2 init failed"
                if ($e.InitializationException) {
                    $errMsg = $e.InitializationException.Message
                }
                Update-Status "Eroare: $errMsg" "#D32F2F"
                Write-Host "[EROARE] WebView2 init: $errMsg" -ForegroundColor Red
            }
        })

        # Start async environment creation
        $script:envTask = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync(
            $null,
            $WebView2DataDir,
            $null
        )

        # Poll with DispatcherTimer until environment is ready (avoids ContinueWith issues in PS)
        $script:envPollTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $script:envPollTimer.Interval = [TimeSpan]::FromMilliseconds(200)
        $script:envPollTimer.Add_Tick({
            if ($script:envTask.IsCompleted) {
                $this.Stop()
                if ($script:envTask.IsFaulted) {
                    $errMsg = $script:envTask.Exception.InnerException.Message
                    Update-Status "Eroare environment: $errMsg" "#D32F2F"
                    Write-Host "[EROARE] Environment: $errMsg" -ForegroundColor Red
                    return
                }
                $env = $script:envTask.Result
                $script:webView.EnsureCoreWebView2Async($env)
            }
        })
        $script:envPollTimer.Start()
    } catch {
        Write-Host "[EROARE] Initialize-WebView2: $($_.Exception.Message)" -ForegroundColor Red
        [System.Windows.MessageBox]::Show(
            "WebView2 Runtime nu este instalat.`n`nInstaleaza Microsoft Edge (Chromium) sau WebView2 Runtime.`n`nEroare: $($_.Exception.Message)",
            "PACS Burner - Eroare",
            "OK", "Error"
        )
    }
}

# ============================================================================
# WebView2 Events
# ============================================================================

function Setup-WebView2Events {
    $coreWv2 = $script:webView.CoreWebView2

    # --- Allow popups: wrap window.open so site doesn't detect blocked popups ---
    # PACS site calls window.open() and checks if it returns null (=blocked).
    # We call the ORIGINAL window.open (so NewWindowRequested event fires in WebView2),
    # but always return 'window' instead of null to bypass the popup detection.
    $popupScript = @"
(function() {
    var _origOpen = window.open;
    window.open = function(url, target, features) {
        if (url && url !== '' && url !== 'about:blank') {
            try { _origOpen.call(window, url, target, features); } catch(e) {}
        }
        return window;
    };
})();
"@
    $coreWv2.AddScriptToExecuteOnDocumentCreatedAsync($popupScript) | Out-Null

    # --- Navigation completed: auto-login, auto-unlock, auto-exclude-viewer ---
    $coreWv2.Add_NavigationCompleted({
        param($s, $e)
        $script:isNavigating = $false

        if ($e.IsSuccess) {
            $url = $s.Source
            Update-Status "Conectat: $url" "#0F9B58"

            # Run automation after short delay (let React render)
            # Dispose previous timer to prevent accumulation across navigations
            if ($script:autoTimer) { $script:autoTimer.Stop(); $script:autoTimer = $null }
            $script:autoTimer = [System.Windows.Threading.DispatcherTimer]::new()
            $script:autoTimer.Interval = [TimeSpan]::FromMilliseconds(800)
            $script:autoTimer.Add_Tick({
                $this.Stop()
                Run-PageAutomation
            })
            $script:autoTimer.Start()
        } else {
            # Suppress ConnectionAborted — happens normally when:
            # 1. Navigation redirects to a file download (server responds with Content-Disposition)
            # 2. NewWindowRequested navigates to a download URL
            # The download itself works fine via DownloadStarting event.
            $errStatus = "$($e.WebErrorStatus)"
            if ($errStatus -ne "ConnectionAborted") {
                Update-Status "Eroare navigare: $errStatus" "#D32F2F"
            }
        }
    })

    # --- Download interception ---
    $coreWv2.Add_DownloadStarting({
        param($s, $e)
        $origPath = $e.ResultFilePath
        $filename = [System.IO.Path]::GetFileName($origPath)

        if ($filename -match '\.zip$') {
            # Stop download poll timer — download actually started
            if ($script:downloadPollTimer) { $script:downloadPollTimer.Stop() }

            $downloadPath = Join-Path $DownloadsDir $filename
            $e.ResultFilePath = $downloadPath
            $e.Handled = $true

            $window.Dispatcher.Invoke([Action]{
                $script:currentZipPath = $downloadPath
                $txtZipInfo.Text = "Descarcare: $filename ..."
            })

            # Monitor download progress — throttled to max 2 updates/sec (500ms)
            # BytesReceivedChanged fires 100+ times/sec, Dispatcher.Invoke on each = CPU killer
            $script:lastProgressUpdate = [DateTime]::MinValue
            $e.DownloadOperation.Add_BytesReceivedChanged({
                param($op, $ev2)
                $now = [DateTime]::Now
                if (($now - $script:lastProgressUpdate).TotalMilliseconds -lt 500) { return }
                $script:lastProgressUpdate = $now
                $window.Dispatcher.Invoke([Action]{
                    $received = $op.BytesReceived
                    $total = $op.TotalBytesToReceive
                    if ($total -gt 0) {
                        $pct = [math]::Round(($received / $total) * 100, 0)
                        $sizeMB = [math]::Round($received / 1MB, 1)
                        $totalMB = [math]::Round($total / 1MB, 1)
                        $txtZipInfo.Text = "Descarcare: $filename - $sizeMB / $totalMB MB ($pct%)"
                    } else {
                        $sizeMB = [math]::Round($received / 1MB, 1)
                        $txtZipInfo.Text = "Descarcare: $filename - $sizeMB MB"
                    }
                })
            })

            $e.DownloadOperation.Add_StateChanged({
                param($op, $ev2)
                $window.Dispatcher.Invoke([Action]{
                    if ($op.State -eq [Microsoft.Web.WebView2.Core.CoreWebView2DownloadState]::Completed) {
                        $sizeMB = [math]::Round((Get-Item $script:currentZipPath).Length / 1MB, 1)
                        $fname = [System.IO.Path]::GetFileName($script:currentZipPath)

                        # Always auto-burn when ZIP download completes (no manual BURN click needed)
                        $script:autoBurnPending = $false
                        if ($script:autoBurnTimer) { $script:autoBurnTimer.Stop() }
                        # Guard: don't start burn if one is already running
                        if ($script:burnProc -and -not $script:burnProc.HasExited) {
                            $txtZipInfo.Text = "ZIP: $fname ($sizeMB MB) - Burn deja in curs"
                            Update-Status "ZIP descarcat, burn deja activ" "#FFA500"
                        } else {
                            $txtZipInfo.Text = "ZIP: $fname ($sizeMB MB) - Lansez burn..."
                            Update-Status "ZIP descarcat - pornesc burn..." "#0F9B58"
                            Start-BurnProcess
                        }
                    }
                    elseif ($op.State -eq [Microsoft.Web.WebView2.Core.CoreWebView2DownloadState]::Interrupted) {
                        $txtZipInfo.Text = "Descarcare intrerupta"
                        Update-Status "Descarcare intrerupta" "#D32F2F"
                        $script:autoBurnPending = $false
                        if ($script:autoBurnTimer) { $script:autoBurnTimer.Stop() }
                    }
                })
            })
        }
    })

    # --- New window requests: open in same WebView ---
    $coreWv2.Add_NewWindowRequested({
        param($s, $e)
        $e.Handled = $true
        $s.Navigate($e.Uri)
    })

    # --- Inject MutationObserver for modal detection ---
    $coreWv2.Add_DOMContentLoaded({
        param($s, $e)
        # Re-inject observer after each page load
        # Dispose previous timer to prevent accumulation across page loads
        if ($script:autoTimer2) { $script:autoTimer2.Stop(); $script:autoTimer2 = $null }
        $script:autoTimer2 = [System.Windows.Threading.DispatcherTimer]::new()
        $script:autoTimer2.Interval = [TimeSpan]::FromMilliseconds(1500)
        $script:autoTimer2.Add_Tick({
            $this.Stop()
            Inject-ModalObserver
        })
        $script:autoTimer2.Start()
    })
}

# ============================================================================
# Page Automation
# ============================================================================

function Run-PageAutomation {
    if (-not $script:webViewReady) { return }

    $netIdx = $cmbNetwork.SelectedIndex
    if ($netIdx -lt 0 -or $netIdx -ge $script:Settings.networks.Count) { return }

    $net = $script:Settings.networks[$netIdx]
    $username = $net.username
    $password = Decrypt-Password $net.password

    # Auto-login
    if ($script:Settings.autoLogin -and $username -and $password) {
        # React uses synthetic events - must use native setter to trigger React state update
        $loginJs = @"
(function() {
    var loginForm = document.getElementById('login');
    var userField = document.getElementById('username');
    var passField = document.getElementById('password');
    if (loginForm && userField && userField.offsetParent !== null) {
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(userField, '$($username -replace "'", "\\'")');
        userField.dispatchEvent(new Event('input', {bubbles: true}));
        userField.dispatchEvent(new Event('change', {bubbles: true}));
        setter.call(passField, '$($password -replace "'", "\\'")');
        passField.dispatchEvent(new Event('input', {bubbles: true}));
        passField.dispatchEvent(new Event('change', {bubbles: true}));
        setTimeout(function() {
            var submitBtn = loginForm.querySelector('button[type="submit"]');
            if (submitBtn) submitBtn.click();
        }, 300);
        return 'login-submitted';
    }
    return 'no-login-form';
})();
"@
        $script:webView.CoreWebView2.ExecuteScriptAsync($loginJs) | Out-Null
    }
    elseif ($script:Settings.autoLogin -and (-not $username -or -not $password)) {
        # Credentials not configured - show hint in status bar
        Update-Status "Configureaza username/parola in Setari pentru auto-login" "#FFA500"
    }

    # Auto-unlock
    if ($script:Settings.autoUnlock -and $password) {
        $unlockJs = @"
(function() {
    var lockPanel = document.querySelector('.panel.panel-danger');
    if (lockPanel) {
        var title = lockPanel.querySelector('.panel-title');
        if (title && title.textContent.indexOf('Blocat') >= 0) {
            var passField = document.getElementById('password');
            if (passField) {
                var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
                setter.call(passField, '$($password -replace "'", "\\'")');
                passField.dispatchEvent(new Event('input', {bubbles: true}));
                passField.dispatchEvent(new Event('change', {bubbles: true}));
                setTimeout(function() {
                    var submitBtn = lockPanel.querySelector('button[type="submit"]');
                    if (submitBtn) submitBtn.click();
                }, 300);
                return 'unlock-submitted';
            }
        }
    }
    return 'no-lock';
})();
"@
        $script:webView.CoreWebView2.ExecuteScriptAsync($unlockJs) | Out-Null
    }
}

# ============================================================================
# Modal Observer - auto "Exclude Viewer" checkbox
# ============================================================================

function Inject-ModalObserver {
    if (-not $script:webViewReady) { return }
    if (-not $script:Settings.autoExcludeViewer) { return }

    $observerJs = @"
(function() {
    // Disconnect old observer before creating new one (prevents accumulation across page reloads)
    if (window._pacsBurnerObserver) {
        window._pacsBurnerObserver.disconnect();
        window._pacsBurnerObserver = null;
    }
    if (window._pacsBurnerDebounce) {
        clearTimeout(window._pacsBurnerDebounce);
        window._pacsBurnerDebounce = null;
    }

    // Debounced handler — React re-renders trigger 100+ mutations/sec,
    // but we only need to check for modal once per 500ms
    function checkModal() {
        var modal = document.querySelector('.modal-dialog');
        if (!modal) return;
        var title = modal.querySelector('.modal-title');
        if (!title || title.textContent.indexOf('Descarcare') < 0) return;
        var labels = modal.querySelectorAll('.form-group label.checkbox-inline');
        for (var i = 0; i < labels.length; i++) {
            if (labels[i].textContent.trim() === 'Exclude Viewer') {
                var cb = labels[i].querySelector('input[type="checkbox"]');
                if (cb && !cb.checked) cb.click();
                break;
            }
        }
    }

    window._pacsBurnerObserver = new MutationObserver(function(mutations) {
        if (window._pacsBurnerDebounce) return;
        window._pacsBurnerDebounce = setTimeout(function() {
            window._pacsBurnerDebounce = null;
            checkModal();
        }, 500);
    });

    window._pacsBurnerObserver.observe(document.body, {
        childList: true,
        subtree: true
    });

    return 'observer-injected';
})();
"@
    $script:webView.CoreWebView2.ExecuteScriptAsync($observerJs) | Out-Null
}

# ============================================================================
# PACS Auto-Download (triggered by Burn button)
# ============================================================================

function Start-PacsDownload {
    if (-not $script:webViewReady) { return }

    # Step 1: Click the download toolbar button
    $clickToolbarJs = "var d=document.querySelector('.glyphicon-download');if(d&&d.closest('button')){d.closest('button').click();'ok'}else{'no-btn'}"
    $script:webView.CoreWebView2.ExecuteScriptAsync($clickToolbarJs) | Out-Null

    # Step 2: Poll with DispatcherTimer — stateless JS on each tick:
    #   - No modal yet → keeps polling
    #   - Modal found, checkbox unchecked → clicks checkbox, waits for next tick
    #   - Modal found, checkbox checked → clicks Descarcare
    #   - Timer stops when DownloadStarting event fires (or timeout 180s)
    $script:downloadPollCount = 0

    # Dispose previous timer to prevent handler accumulation across multiple burns
    if ($script:downloadPollTimer) { $script:downloadPollTimer.Stop(); $script:downloadPollTimer = $null }
    $script:downloadPollTimer = [System.Windows.Threading.DispatcherTimer]::new()
    # Start fast (500ms) for UI responsiveness, slow down after modal is found
    $script:downloadPollTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:downloadPollTimer.Add_Tick({
        $script:downloadPollCount++

        # Adaptive interval: fast first 10s (500ms), then slow (3s) to reduce CPU
        if ($script:downloadPollCount -eq 20) {
            $this.Interval = [TimeSpan]::FromMilliseconds(3000)
        }

        # Stop after 160 ticks (~8 min with adaptive intervals)
        if ($script:downloadPollCount -gt 160) {
            $this.Stop()
            Update-Status "Astept descarcarea de pe PACS..." "#FFA500"
            return
        }

        if (-not $script:webViewReady) { return }

        # Stateless JS — no phases needed, each tick tries the full sequence:
        # 1. Find modal → if not found, return (keep polling)
        # 2. Find "Exclude Viewer" checkbox → if unchecked, click it and return (next tick will continue)
        # 3. If checkbox already checked → click btn-primary (Descarcare)
        $js = @"
(function() {
    var modal = document.querySelector('.modal-dialog');
    if (!modal) return 'no-modal';

    var labels = modal.querySelectorAll('label');
    for (var i = 0; i < labels.length; i++) {
        if (labels[i].textContent.indexOf('Exclude Viewer') >= 0) {
            var cb = labels[i].querySelector('input[type=checkbox]');
            if (cb && !cb.checked) {
                cb.click();
                return 'checkbox-clicked';
            }
            break;
        }
    }

    var btns = modal.querySelectorAll('button');
    for (var j = 0; j < btns.length; j++) {
        if (btns[j].className.indexOf('btn-primary') >= 0) {
            btns[j].click();
            return 'download-clicked';
        }
    }
    return 'no-btn';
})();
"@
        $script:webView.CoreWebView2.ExecuteScriptAsync($js) | Out-Null
    })
    $script:downloadPollTimer.Start()
}

# ============================================================================
# Start Burn Process
# ============================================================================

function Start-BurnProcess {
    if (-not $script:currentZipPath -or -not (Test-Path $script:currentZipPath)) {
        Update-Status "Nu exista ZIP pentru burn" "#D32F2F"
        return
    }
    $simLabel = if ($script:Settings.simulateOnly) { " (SIMULARE)" } else { "" }
    Update-Status "Lansez burn.ps1$simLabel..." "#FFA500"
    # Build burn command
    $bSpeed = if ($script:Settings.burnSpeed) { $script:Settings.burnSpeed } else { 4 }
    $bDrive = $script:Settings.burnDriveId

    # Build PowerShell arguments for burn GUI
    $psArgs = "-sta -nologo -noprofile -ExecutionPolicy Bypass -File `"$BurnGuiScript`" -ZipPath `"$($script:currentZipPath)`" -BurnSpeed $bSpeed -AutoConfirm"
    if ($bDrive) {
        $psArgs += " -DriveID `"$bDrive`""
    }
    if ($script:Settings.simulateOnly) {
        $psArgs += " -SimulateOnly"
    }
    # Launch WPF burn GUI — Hidden suppresses console window, GUI shows WPF only
    $script:burnProc = Start-Process powershell -ArgumentList $psArgs -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru

    # Monitor burn process — when CMD closes, bring window to foreground + reload page
    # Dispose previous timer to prevent handler accumulation across multiple burns
    if ($script:burnMonitorTimer) { $script:burnMonitorTimer.Stop(); $script:burnMonitorTimer = $null }
    $script:burnMonitorTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:burnMonitorTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $script:burnMonitorTimer.Add_Tick({
        if (-not $script:burnProc -or -not $script:burnProc.HasExited) { return }
        $this.Stop()
        $script:burnProc = $null
        $script:currentZipPath = $null

        # Reset status bar
        $window.Dispatcher.Invoke([Action]{ $txtZipInfo.Text = "" })

        # Force window to foreground (Win32 API bypasses focus lock)
        $window.Dispatcher.Invoke([Action]{
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
            if ($hwnd -ne [IntPtr]::Zero) {
                $fgWnd = [Win32Focus]::GetForegroundWindow()
                $fgThread = [Win32Focus]::GetWindowThreadProcessId($fgWnd, [IntPtr]::Zero)
                $myThread = [Win32Focus]::GetCurrentThreadId()
                [Win32Focus]::AttachThreadInput($fgThread, $myThread, $true)
                [Win32Focus]::ShowWindow($hwnd, [Win32Focus]::SW_RESTORE)
                [Win32Focus]::SetForegroundWindow($hwnd)
                [Win32Focus]::AttachThreadInput($fgThread, $myThread, $false)
            }
            $window.Activate()
        })

        # Reload page to reset React SPA state after download + auto-login handles re-login
        $script:webView.CoreWebView2.Reload()
        Update-Status "Pagina reincarcata - auto-login..." "#FFA500"
    })
    $script:burnMonitorTimer.Start()
}

# ============================================================================
# UI Helpers
# ============================================================================

function Update-Status {
    param([string]$text, [string]$color = "#AAAAAA")
    $window.Dispatcher.Invoke([Action]{
        $txtStatus.Text = $text
        $statusDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
    })
}

function Populate-NetworkCombo {
    $cmbNetwork.Items.Clear()
    foreach ($net in $script:Settings.networks) {
        $cmbNetwork.Items.Add("$($net.name) - $($net.url)") | Out-Null
    }
    if ($script:Settings.lastNetwork -ge 0 -and $script:Settings.lastNetwork -lt $cmbNetwork.Items.Count) {
        $cmbNetwork.SelectedIndex = $script:Settings.lastNetwork
    } elseif ($cmbNetwork.Items.Count -gt 0) {
        $cmbNetwork.SelectedIndex = 0
    }
}

function Connect-ToNetwork {
    param([int]$index)
    if ($index -lt 0 -or $index -ge $script:Settings.networks.Count) { return }
    if (-not $script:webViewReady) { return }

    $net = $script:Settings.networks[$index]
    $url = $net.url

    $script:Settings.lastNetwork = $index
    Save-Settings $script:Settings

    $script:isNavigating = $true
    Update-Status "Conectare la $($net.name)..." "#FFA500"
    $script:webView.CoreWebView2.Navigate($url)
}

# ============================================================================
# Optical Drive Detection
# ============================================================================

# Cached drive detection — COM instantiation is very slow on weak CPUs (200-500ms).
# Cache is valid for 10 seconds; subsequent calls return cached result instantly.
$script:cachedDrives = $null
$script:lastDriveScan = [DateTime]::MinValue

function Detect-OpticalDrives {
    param([switch]$ForceRefresh)
    if (-not $ForceRefresh -and $script:cachedDrives -ne $null) {
        $elapsed = ([DateTime]::Now - $script:lastDriveScan).TotalSeconds
        if ($elapsed -lt 10) { return $script:cachedDrives }
    }
    $drives = @()
    try {
        $discMaster = New-Object -ComObject IMAPI2.MsftDiscMaster2
        for ($i = 0; $i -lt $discMaster.Count; $i++) {
            $rec = New-Object -ComObject IMAPI2.MsftDiscRecorder2
            $rec.InitializeDiscRecorder($discMaster.Item($i))
            $drives += @{
                Index   = $i
                ID      = $discMaster.Item($i)
                Letter  = ($rec.VolumePathNames | Select-Object -First 1)
                Vendor  = $rec.VendorId.Trim()
                Product = $rec.ProductId.Trim()
                Label   = "$($rec.VendorId.Trim()) $($rec.ProductId.Trim()) ($($rec.VolumePathNames | Select-Object -First 1))"
            }
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($rec) | Out-Null
        }
        [System.Runtime.InteropServices.Marshal]::ReleaseComObject($discMaster) | Out-Null
    } catch {
        # IMAPI2 not available
    }
    $script:cachedDrives = $drives
    $script:lastDriveScan = [DateTime]::Now
    return $drives
}

# ============================================================================
# Settings Dialog
# ============================================================================

function Show-SettingsDialog {
    $settingsReader = [System.Xml.XmlNodeReader]::new($settingsXaml)
    $dlg = [System.Windows.Markup.XamlReader]::Load($settingsReader)
    $dlg.Owner = $window

    $lstNetworks  = $dlg.FindName("lstNetworks")
    $txtNetName   = $dlg.FindName("txtNetName")
    $txtNetUrl    = $dlg.FindName("txtNetUrl")
    $txtNetUser   = $dlg.FindName("txtNetUser")
    $txtNetPass   = $dlg.FindName("txtNetPass")
    $chkAutoLogin   = $dlg.FindName("chkAutoLogin")
    $chkAutoUnlock  = $dlg.FindName("chkAutoUnlock")
    $chkAutoExclude = $dlg.FindName("chkAutoExclude")
    $chkSimulate    = $dlg.FindName("chkSimulate")
    $btnNetAdd    = $dlg.FindName("btnNetAdd")
    $btnNetSave   = $dlg.FindName("btnNetSave")
    $btnNetDelete = $dlg.FindName("btnNetDelete")
    $btnNetUp     = $dlg.FindName("btnNetUp")
    $btnNetDown   = $dlg.FindName("btnNetDown")
    $cmbBurnDrive   = $dlg.FindName("cmbBurnDrive")
    $cmbBurnSpeed   = $dlg.FindName("cmbBurnSpeed")
    $btnRefreshDrives = $dlg.FindName("btnRefreshDrives")
    $btnSettingsOk = $dlg.FindName("btnSettingsOk")

    # Load current settings
    $chkAutoLogin.IsChecked   = $script:Settings.autoLogin
    $chkAutoUnlock.IsChecked  = $script:Settings.autoUnlock
    $chkAutoExclude.IsChecked = $script:Settings.autoExcludeViewer
    $chkSimulate.IsChecked    = $script:Settings.simulateOnly

    # --- Force white text on ComboBox (WPF default template ignores Foreground) ---
    $whiteBrush = [System.Windows.Media.Brushes]::White
    $fgProp = [System.Windows.Documents.TextElement]::ForegroundProperty
    $cmbBurnDrive.SetValue($fgProp, $whiteBrush)
    $cmbBurnSpeed.SetValue($fgProp, $whiteBrush)

    # --- Burn speed ComboBox ---
    $speedOptions = @("1x", "2x", "4x", "8x", "12x", "16x")
    $script:speedValues  = @(1, 2, 4, 8, 12, 16)
    foreach ($opt in $speedOptions) {
        $cmbBurnSpeed.Items.Add($opt) | Out-Null
    }
    # Select current speed
    $currentSpeed = if ($script:Settings.burnSpeed) { $script:Settings.burnSpeed } else { 4 }
    $speedIdx = [Array]::IndexOf($script:speedValues, $currentSpeed)
    if ($speedIdx -lt 0) { $speedIdx = 2 }  # default 4x
    $cmbBurnSpeed.SelectedIndex = $speedIdx

    # --- Burn drive detection ---
    $script:detectedDrives = @()

    function Refresh-DriveList {
        $cmbBurnDrive.Items.Clear()
        $script:detectedDrives = @(Detect-OpticalDrives)

        if ($script:detectedDrives.Count -eq 0) {
            $cmbBurnDrive.Items.Add("Nu s-a gasit nicio unitate") | Out-Null
            $cmbBurnDrive.SelectedIndex = 0
            $cmbBurnDrive.IsEnabled = $false
        }
        elseif ($script:detectedDrives.Count -eq 1) {
            $cmbBurnDrive.Items.Add($script:detectedDrives[0].Label) | Out-Null
            $cmbBurnDrive.SelectedIndex = 0
            $cmbBurnDrive.IsEnabled = $false
        }
        else {
            foreach ($drv in $script:detectedDrives) {
                $cmbBurnDrive.Items.Add($drv.Label) | Out-Null
            }
            $cmbBurnDrive.IsEnabled = $true
            # Try to select saved drive
            $savedId = $script:Settings.burnDriveId
            $matchIdx = -1
            if ($savedId) {
                for ($i = 0; $i -lt $script:detectedDrives.Count; $i++) {
                    if ($script:detectedDrives[$i].ID -eq $savedId) {
                        $matchIdx = $i
                        break
                    }
                }
            }
            $cmbBurnDrive.SelectedIndex = if ($matchIdx -ge 0) { $matchIdx } else { 0 }
        }
    }
    Refresh-DriveList

    # Refresh drives button — force rescan (user explicitly requested)
    $btnRefreshDrives.Add_Click({
        $script:lastDriveScan = [DateTime]::MinValue
        Refresh-DriveList
    })

    function Refresh-NetworkList {
        $lstNetworks.Items.Clear()
        foreach ($net in $script:Settings.networks) {
            $lstNetworks.Items.Add("$($net.name) | $($net.url)") | Out-Null
        }
    }
    Refresh-NetworkList

    # Auto-select first (or last used) network
    if ($lstNetworks.Items.Count -gt 0) {
        $selIdx = [Math]::Min($script:Settings.lastNetwork, $lstNetworks.Items.Count - 1)
        if ($selIdx -lt 0) { $selIdx = 0 }
        $lstNetworks.SelectedIndex = $selIdx
    }

    # Select network in list -> populate edit fields
    $lstNetworks.Add_SelectionChanged({
        $idx = $lstNetworks.SelectedIndex
        if ($idx -ge 0 -and $idx -lt $script:Settings.networks.Count) {
            $net = $script:Settings.networks[$idx]
            $txtNetName.Text = $net.name
            $txtNetUrl.Text  = $net.url
            $txtNetUser.Text = $net.username
            $txtNetPass.Password = Decrypt-Password $net.password
        }
    })

    # Add network
    $btnNetAdd.Add_Click({
        $newNet = @{
            name     = "Noua Retea"
            url      = "http://"
            username = ""
            password = ""
        }
        $script:Settings.networks += $newNet
        Refresh-NetworkList
        $lstNetworks.SelectedIndex = $lstNetworks.Items.Count - 1
    })

    # Save selected network
    $btnNetSave.Add_Click({
        $idx = $lstNetworks.SelectedIndex
        if ($idx -ge 0 -and $idx -lt $script:Settings.networks.Count) {
            $script:Settings.networks[$idx].name     = $txtNetName.Text
            $script:Settings.networks[$idx].url      = $txtNetUrl.Text
            $script:Settings.networks[$idx].username  = $txtNetUser.Text
            $script:Settings.networks[$idx].password  = Encrypt-Password $txtNetPass.Password
            Refresh-NetworkList
            $lstNetworks.SelectedIndex = $idx
        }
    })

    # Delete selected network
    $btnNetDelete.Add_Click({
        $idx = $lstNetworks.SelectedIndex
        if ($idx -ge 0 -and $idx -lt $script:Settings.networks.Count) {
            $confirm = [System.Windows.MessageBox]::Show(
                "Stergi reteaua '$($script:Settings.networks[$idx].name)'?",
                "Confirmare", "YesNo", "Question"
            )
            if ($confirm -eq "Yes") {
                $list = [System.Collections.ArrayList]::new($script:Settings.networks)
                $list.RemoveAt($idx)
                $script:Settings.networks = @($list)
                Refresh-NetworkList
                if ($lstNetworks.Items.Count -gt 0) {
                    $lstNetworks.SelectedIndex = [Math]::Min($idx, $lstNetworks.Items.Count - 1)
                }
            }
        }
    })

    # Move network up (higher priority)
    $btnNetUp.Add_Click({
        $idx = $lstNetworks.SelectedIndex
        if ($idx -gt 0) {
            $list = [System.Collections.ArrayList]::new($script:Settings.networks)
            $item = $list[$idx]
            $list.RemoveAt($idx)
            $list.Insert($idx - 1, $item)
            $script:Settings.networks = @($list)
            Refresh-NetworkList
            $lstNetworks.SelectedIndex = $idx - 1
        }
    })

    # Move network down (lower priority)
    $btnNetDown.Add_Click({
        $idx = $lstNetworks.SelectedIndex
        if ($idx -ge 0 -and $idx -lt ($script:Settings.networks.Count - 1)) {
            $list = [System.Collections.ArrayList]::new($script:Settings.networks)
            $item = $list[$idx]
            $list.RemoveAt($idx)
            $list.Insert($idx + 1, $item)
            $script:Settings.networks = @($list)
            Refresh-NetworkList
            $lstNetworks.SelectedIndex = $idx + 1
        }
    })

    # OK - save all and close
    $btnSettingsOk.Add_Click({
        try {
            $script:Settings.autoLogin        = [bool]$chkAutoLogin.IsChecked
            $script:Settings.autoUnlock       = [bool]$chkAutoUnlock.IsChecked
            $script:Settings.autoExcludeViewer = [bool]$chkAutoExclude.IsChecked
            $script:Settings.simulateOnly     = [bool]$chkSimulate.IsChecked

            # Save burn speed
            $spdIdx = $cmbBurnSpeed.SelectedIndex
            if ($spdIdx -ge 0 -and $spdIdx -lt $script:speedValues.Count) {
                $script:Settings.burnSpeed = $script:speedValues[$spdIdx]
            }

            # Save burn drive ID
            $drvIdx = $cmbBurnDrive.SelectedIndex
            if ($drvIdx -ge 0 -and $drvIdx -lt $script:detectedDrives.Count) {
                $script:Settings.burnDriveId = $script:detectedDrives[$drvIdx].ID
            } else {
                $script:Settings.burnDriveId = ""
            }

            Save-Settings $script:Settings
            Populate-NetworkCombo
            $dlg.Close()
        } catch {
            [System.Windows.MessageBox]::Show("Eroare la salvare: $($_.Exception.Message)", "Eroare", "OK", "Error")
        }
    })

    $dlg.ShowDialog() | Out-Null
}

# ============================================================================
# Button handlers
# ============================================================================

$btnConnect.Add_Click({
    $idx = $cmbNetwork.SelectedIndex
    Connect-ToNetwork $idx
})

$btnSettings.Add_Click({
    Show-SettingsDialog
})

$btnRefresh.Add_Click({
    if ($script:webViewReady) {
        $script:webView.CoreWebView2.Reload()
    }
})

$btnOpenFolder.Add_Click({
    if (Test-Path $DownloadsDir) {
        Start-Process explorer.exe -ArgumentList $DownloadsDir
    }
})

$btnBurn.Add_Click({
    if ($script:currentZipPath -and (Test-Path $script:currentZipPath)) {
        # ZIP already downloaded - confirm and burn
        $zipFile = [System.IO.Path]::GetFileName($script:currentZipPath)
        $confirm = [System.Windows.MessageBox]::Show(
            "Incepe burn pe DVD?`n`nFisier: $zipFile`nDimensiune: $([math]::Round((Get-Item $script:currentZipPath).Length / 1MB, 1)) MB",
            "PACS Burner - Burn DVD",
            "YesNo", "Question"
        )
        if ($confirm -eq "Yes") {
            Start-BurnProcess
        }
    } else {
        # No ZIP - trigger auto download from PACS, then auto-burn
        $script:autoBurnPending = $true
        Update-Status "Se descarca de pe PACS..." "#FFA500"
        $txtZipInfo.Text = "Se initiaza descarcarea..."
        Start-PacsDownload
    }
})

# ============================================================================
# Window events
# ============================================================================

$window.Add_Loaded({
    Populate-NetworkCombo
    Initialize-WebView2
})

$window.Add_Closing({
    # Stop all DispatcherTimers to prevent callbacks after dispose
    try { if ($script:envPollTimer)        { $script:envPollTimer.Stop();        $script:envPollTimer = $null } } catch {}
    try { if ($script:autoTimer)           { $script:autoTimer.Stop();           $script:autoTimer = $null } } catch {}
    try { if ($script:autoTimer2)          { $script:autoTimer2.Stop();          $script:autoTimer2 = $null } } catch {}
    try { if ($script:downloadPollTimer)   { $script:downloadPollTimer.Stop();   $script:downloadPollTimer = $null } } catch {}
    try { if ($script:burnMonitorTimer)    { $script:burnMonitorTimer.Stop();    $script:burnMonitorTimer = $null } } catch {}

    # Terminate burn process if still running
    if ($script:burnProc -and -not $script:burnProc.HasExited) {
        try { $script:burnProc.Kill() } catch {}
        $script:burnProc = $null
    }

    # Clean up WebView2
    if ($script:webView -and $script:webView.CoreWebView2) {
        try {
            $script:webView.Dispose()
        } catch { }
    }
})

# ============================================================================
# Run application
# ============================================================================

$window.ShowDialog() | Out-Null
