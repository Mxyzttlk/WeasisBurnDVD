# ============================================================================
# Weasis DICOM Viewer - WPF Tutorial Window
# Copyright (c) 2026 Bejenaru Adrian. All rights reserved.
# Unauthorized copying, modification, or distribution is strictly prohibited.
# ============================================================================

param(
    [Parameter(Mandatory=$true)][string]$DiscPath
)

# Normalize DiscPath (removes trailing "\." from BAT workaround)
$DiscPath = [System.IO.Path]::GetFullPath($DiscPath)

# --- Check if tutorial was skipped ---
$skipFile = Join-Path $env:APPDATA "WeasisBurn\tutorial-skipped.txt"
if (Test-Path $skipFile) {
    exit 0
}

# --- STA Guard (WPF requires Single-Threaded Apartment) ---
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    exit 1
}

# --- Load WPF Assemblies ---
try {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
} catch {
    exit 1
}

# ============================================================================
# MULTILINGUAL STRINGS (RO / RU / EN)
# ============================================================================
# NOTE: Use simple dash (-) not em dash. Newlines via `n in double-quoted strings.
$allStrings = @{
    "ro" = @{
        Title        = "Tutorial Weasis"
        StepOf       = "Pasul {0} din {1}"
        BtnPrev      = "Inapoi"
        BtnNext      = "Urmatorul"
        BtnSkip      = "Nu mai afisa"
        BtnClose     = "Inchide"
        Slide1       = "[1] Asteptati terminarea incarcarii seriilor.`n[2] Butonul de oprire - daca seria dorita este deja incarcata, puteti opri incarcarea."
        Slide2       = "[1] Panoul cu serii. Pentru a alege seria dorita, faceti dublu-clic pe ea.`n[2] Seria selectata este marcata cu cerc verde."
        Slide3       = "[1] Zona de scrolling. Tineti click stang apasat si miscati mouse-ul sus/jos pentru a naviga prin imagini."
        Slide4       = "[1] Butonul MPR - apasati pentru a reconstrui seria in diferite proiectii (coronal, sagital)."
        Slide5       = "Dupa apasarea butonului MPR, asteptati reconstructia proiectiilor. Barele de progres arata avansarea. Odata reconstruite, navigarea prin imagini devine fluida."
        Slide6       = "[1] Butonul MIP.`n[2] Butonul pentru alegerea ferestrelor (Window/Level).`n[3] Butonul Dispunere vizualizare - pentru a vizualiza in acelasi moment mai multe faze."
        Slide7       = "[1] Pentru a deschide fereastra cu instrumente de masurare, apasati acest buton."
    }
    "ru" = @{
        Title        = ([char[]]@(0x420,0x443,0x43A,0x43E,0x432,0x43E,0x434,0x441,0x442,0x432,0x43E,0x20,0x57,0x65,0x61,0x73,0x69,0x73) -join '')
        StepOf       = ([char[]]@(0x428,0x430,0x433) -join '') + " {0} " + ([char[]]@(0x438,0x437) -join '') + " {1}"
        BtnPrev      = ([char[]]@(0x41D,0x430,0x437,0x430,0x434) -join '')
        BtnNext      = ([char[]]@(0x414,0x430,0x43B,0x435,0x435) -join '')
        BtnSkip      = ([char[]]@(0x411,0x43E,0x43B,0x44C,0x448,0x435,0x20,0x43D,0x435,0x20,0x43F,0x43E,0x43A,0x430,0x437,0x44B,0x432,0x430,0x442,0x44C) -join '')
        BtnClose     = ([char[]]@(0x417,0x430,0x43A,0x440,0x44B,0x442,0x44C) -join '')
        Slide1       = "[1] " + ([char[]]@(0x414,0x43E,0x436,0x434,0x438,0x442,0x435,0x441,0x44C,0x20,0x43E,0x43A,0x43E,0x43D,0x447,0x430,0x43D,0x438,0x44F,0x20,0x437,0x430,0x433,0x440,0x443,0x437,0x43A,0x438,0x20,0x441,0x435,0x440,0x438,0x439) -join '') + ".`n[2] " + ([char[]]@(0x41A,0x43D,0x43E,0x43F,0x43A,0x430,0x20,0x43E,0x441,0x442,0x430,0x43D,0x43E,0x432,0x43A,0x438) -join '') + " - " + ([char[]]@(0x435,0x441,0x43B,0x438,0x20,0x43D,0x443,0x436,0x43D,0x430,0x44F,0x20,0x441,0x435,0x440,0x438,0x44F,0x20,0x443,0x436,0x435,0x20,0x437,0x430,0x433,0x440,0x443,0x436,0x435,0x43D,0x430) -join '') + "."
        Slide2       = "[1] " + ([char[]]@(0x41F,0x430,0x43D,0x435,0x43B,0x44C,0x20,0x441,0x435,0x440,0x438,0x439) -join '') + ". " + ([char[]]@(0x414,0x43B,0x44F,0x20,0x432,0x44B,0x431,0x43E,0x440,0x430,0x20,0x43D,0x443,0x436,0x43D,0x43E,0x439,0x20,0x441,0x435,0x440,0x438,0x438,0x20,0x434,0x432,0x430,0x436,0x434,0x44B,0x20,0x449,0x435,0x43B,0x43A,0x43D,0x438,0x442,0x435) -join '') + ".`n[2] " + ([char[]]@(0x412,0x44B,0x431,0x440,0x430,0x43D,0x43D,0x430,0x44F,0x20,0x441,0x435,0x440,0x438,0x44F,0x20,0x43E,0x442,0x43C,0x435,0x447,0x435,0x43D,0x430,0x20,0x437,0x435,0x43B,0x435,0x43D,0x44B,0x43C,0x20,0x43A,0x440,0x443,0x436,0x43A,0x43E,0x43C) -join '') + "."
        Slide3       = "[1] " + ([char[]]@(0x417,0x43E,0x43D,0x430,0x20,0x43F,0x440,0x43E,0x43A,0x440,0x443,0x442,0x43A,0x438) -join '') + ". " + ([char[]]@(0x423,0x434,0x435,0x440,0x436,0x438,0x432,0x430,0x439,0x442,0x435,0x20,0x43B,0x435,0x432,0x443,0x44E,0x20,0x43A,0x43D,0x43E,0x43F,0x43A,0x443,0x20,0x43C,0x44B,0x448,0x438,0x20,0x438,0x20,0x434,0x432,0x438,0x433,0x430,0x439,0x442,0x435,0x20,0x432,0x432,0x435,0x440,0x445,0x2F,0x432,0x43D,0x438,0x437) -join '') + "."
        Slide4       = "[1] " + ([char[]]@(0x41A,0x43D,0x43E,0x43F,0x43A,0x430,0x20,0x4D,0x50,0x52) -join '') + " - " + ([char[]]@(0x43D,0x430,0x436,0x43C,0x438,0x442,0x435,0x20,0x434,0x43B,0x44F,0x20,0x440,0x435,0x43A,0x43E,0x43D,0x441,0x442,0x440,0x443,0x43A,0x446,0x438,0x438) -join '') + "."
        Slide5       = ([char[]]@(0x41F,0x43E,0x441,0x43B,0x435,0x20,0x43D,0x430,0x436,0x430,0x442,0x438,0x44F,0x20,0x43A,0x43D,0x43E,0x43F,0x43A,0x438,0x20,0x4D,0x50,0x52,0x20,0x434,0x43E,0x436,0x434,0x438,0x442,0x435,0x441,0x44C,0x20,0x440,0x435,0x43A,0x43E,0x43D,0x441,0x442,0x440,0x443,0x43A,0x446,0x438,0x438) -join '') + ". " + ([char[]]@(0x41F,0x43E,0x441,0x43B,0x435,0x20,0x437,0x430,0x432,0x435,0x440,0x448,0x435,0x43D,0x438,0x44F,0x20,0x43D,0x430,0x432,0x438,0x433,0x430,0x446,0x438,0x44F,0x20,0x441,0x442,0x430,0x43D,0x435,0x442,0x20,0x43F,0x43B,0x430,0x432,0x43D,0x43E,0x439) -join '') + "."
        Slide6       = "[1] MIP.`n[2] Window/Level.`n[3] Layout."
        Slide7       = "[1] " + ([char[]]@(0x418,0x43D,0x441,0x442,0x440,0x443,0x43C,0x435,0x43D,0x442,0x44B,0x20,0x438,0x437,0x43C,0x435,0x440,0x435,0x43D,0x438,0x44F) -join '') + "."
    }
    "en" = @{
        Title        = "Weasis Tutorial"
        StepOf       = "Step {0} of {1}"
        BtnPrev      = "Previous"
        BtnNext      = "Next"
        BtnSkip      = "Do not show again"
        BtnClose     = "Close"
        Slide1       = "[1] Wait for the series to finish loading.`n[2] Stop button - if the desired series is already loaded, you can stop the loading process."
        Slide2       = "[1] Series panel. To select the desired series, double-click on it.`n[2] The selected series is marked with a green circle."
        Slide3       = "[1] Scrolling area. Hold left mouse button and move up/down to navigate through images."
        Slide4       = "[1] MPR button - press to reconstruct the series in different projections (coronal, sagittal)."
        Slide5       = "After pressing the MPR button, wait for the projections to reconstruct. Progress bars show the advancement. Once reconstructed, image navigation becomes smooth."
        Slide6       = "[1] MIP button.`n[2] Window selection button (Window/Level).`n[3] Layout Display button - to view multiple phases simultaneously."
        Slide7       = "[1] To open the measurement tools window, press this button."
    }
}

# Detect system language, default to EN
$script:currentLang = (Get-Culture).TwoLetterISOLanguageName
if ($script:currentLang -notin @("ro", "ru")) { $script:currentLang = "en" }

function Get-S { return $allStrings[$script:currentLang] }

$totalSlides = 7
$script:currentSlide = 1

# ============================================================================
# WPF XAML LAYOUT
# ============================================================================
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Tutorial Weasis"
        Width="920" Height="640"
        WindowStartupLocation="CenterScreen"
        WindowState="Maximized"
        WindowStyle="None"
        Background="#1E1E1E"
        ResizeMode="NoResize"
        Topmost="False"
        ShowInTaskbar="True">

    <Border CornerRadius="0" Background="#1E1E1E" BorderBrush="#333333" BorderThickness="0">
        <Grid Margin="0">
            <Grid.RowDefinitions>
                <RowDefinition Height="48"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="50"/>
            </Grid.RowDefinitions>

            <!-- ROW 0: TITLE BAR -->
            <Border Grid.Row="0" Background="#252525" CornerRadius="0">
                <Grid Margin="16,0">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
                        <Image x:Name="imgLogo" Width="28" Height="28" Margin="0,0,10,0" VerticalAlignment="Center"/>
                        <TextBlock x:Name="txtTitle" Text="Tutorial Weasis" FontSize="18" FontWeight="SemiBold"
                                   Foreground="#0F9B58" VerticalAlignment="Center"/>
                    </StackPanel>

                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Border Background="#333333" CornerRadius="4" Margin="0,0,16,0" Padding="2">
                            <StackPanel Orientation="Horizontal">
                                <Button x:Name="btnLangRO" Content="RO" Width="36" Height="26"
                                        FontSize="11" FontWeight="SemiBold" Cursor="Hand"
                                        Foreground="White" Background="#0F9B58" BorderThickness="0">
                                    <Button.Template>
                                        <ControlTemplate TargetType="Button">
                                            <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="3" Padding="4,2">
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
                                <Button x:Name="btnLangRU" Content="RU" Width="36" Height="26"
                                        FontSize="11" FontWeight="SemiBold" Cursor="Hand"
                                        Foreground="#AAAAAA" Background="#444444" BorderThickness="0">
                                    <Button.Template>
                                        <ControlTemplate TargetType="Button">
                                            <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="3" Padding="4,2">
                                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                            </Border>
                                            <ControlTemplate.Triggers>
                                                <Trigger Property="IsMouseOver" Value="True">
                                                    <Setter TargetName="border" Property="Background" Value="#555555"/>
                                                </Trigger>
                                            </ControlTemplate.Triggers>
                                        </ControlTemplate>
                                    </Button.Template>
                                </Button>
                                <Button x:Name="btnLangEN" Content="EN" Width="36" Height="26"
                                        FontSize="11" FontWeight="SemiBold" Cursor="Hand"
                                        Foreground="#AAAAAA" Background="#444444" BorderThickness="0">
                                    <Button.Template>
                                        <ControlTemplate TargetType="Button">
                                            <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="3" Padding="4,2">
                                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                            </Border>
                                            <ControlTemplate.Triggers>
                                                <Trigger Property="IsMouseOver" Value="True">
                                                    <Setter TargetName="border" Property="Background" Value="#555555"/>
                                                </Trigger>
                                            </ControlTemplate.Triggers>
                                        </ControlTemplate>
                                    </Button.Template>
                                </Button>
                            </StackPanel>
                        </Border>

                        <Button x:Name="btnMinimize" Content="&#x2014;" Width="32" Height="26" Margin="0,0,4,0"
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
                        <Button x:Name="btnCloseWin" Content="&#x2715;" Width="32" Height="26"
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
                </Grid>
            </Border>

            <!-- ROW 1: IMAGE AREA -->
            <Border Grid.Row="1" Background="#111111" Margin="12,8,12,4">
                <Image x:Name="imgSlide" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
            </Border>

            <!-- ROW 2: TEXT AREA -->
            <Border Grid.Row="2" Background="#1A1A1A" Margin="12,4,12,4" CornerRadius="6" Padding="16,10">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" x:Name="txtDescription" Text=""
                               FontSize="13" Foreground="#CCCCCC" TextWrapping="Wrap"
                               VerticalAlignment="Center" LineHeight="20"/>
                    <TextBlock Grid.Column="1" x:Name="txtStepCounter" Text="1 / 7"
                               FontSize="13" Foreground="#888888" VerticalAlignment="Center"
                               Margin="20,0,0,0" FontWeight="SemiBold"/>
                </Grid>
            </Border>

            <!-- ROW 3: BUTTON BAR -->
            <Border Grid.Row="3" Background="#252525" CornerRadius="0">
                <Grid Margin="16,0">
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
                        <Button x:Name="btnSkip" Content="Nu mai afisa" Height="32"
                                FontSize="12" Cursor="Hand" Padding="14,0"
                                Foreground="White" Background="#D32F2F" BorderThickness="0">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#E53935"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Button.Template>
                        </Button>
                    </StackPanel>

                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                        <Button x:Name="btnPrev" Content="Inapoi" Height="32" Margin="0,0,8,0"
                                FontSize="12" Cursor="Hand" Padding="14,0"
                                Foreground="#CCCCCC" Background="#444444" BorderThickness="0">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#555555"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Button.Template>
                        </Button>
                        <Button x:Name="btnNext" Content="Urmatorul" Height="32" Margin="0,0,8,0"
                                FontSize="12" Cursor="Hand" Padding="14,0"
                                Foreground="White" Background="#0F9B58" BorderThickness="0">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
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
                        <Button x:Name="btnClose" Content="Inchide" Height="32"
                                FontSize="12" Cursor="Hand" Padding="14,0"
                                Foreground="#CCCCCC" Background="#555555" BorderThickness="0">
                            <Button.Template>
                                <ControlTemplate TargetType="Button">
                                    <Border x:Name="border" Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                    </Border>
                                    <ControlTemplate.Triggers>
                                        <Trigger Property="IsMouseOver" Value="True">
                                            <Setter TargetName="border" Property="Background" Value="#666666"/>
                                        </Trigger>
                                    </ControlTemplate.Triggers>
                                </ControlTemplate>
                            </Button.Template>
                        </Button>
                    </StackPanel>
                </Grid>
            </Border>

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
    exit 1
}

# Get controls
$imgLogo        = $window.FindName("imgLogo")
$txtTitle       = $window.FindName("txtTitle")
$imgSlide       = $window.FindName("imgSlide")
$txtDescription = $window.FindName("txtDescription")
$txtStepCounter = $window.FindName("txtStepCounter")
$btnPrev        = $window.FindName("btnPrev")
$btnNext        = $window.FindName("btnNext")
$btnSkip        = $window.FindName("btnSkip")
$btnClose       = $window.FindName("btnClose")
$btnCloseWin    = $window.FindName("btnCloseWin")
$btnMinimize    = $window.FindName("btnMinimize")
$btnLangRO      = $window.FindName("btnLangRO")
$btnLangRU      = $window.FindName("btnLangRU")
$btnLangEN      = $window.FindName("btnLangEN")

# ============================================================================
# LOAD LOGO
# ============================================================================
$logoPath = Join-Path $DiscPath "Weasis\resources\images\logo-button.png"
# Also try parent path (if DiscPath is Weasis/ itself)
if (-not (Test-Path $logoPath)) {
    $logoPath = Join-Path $DiscPath "resources\images\logo-button.png"
}
if (Test-Path $logoPath) {
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.UriSource = New-Object System.Uri($logoPath, [System.UriKind]::Absolute)
        $bmp.DecodePixelWidth = 28
        $bmp.EndInit()
        $bmp.Freeze()
        $imgLogo.Source = $bmp
    } catch { }
}

# ============================================================================
# IMAGE LOADING
# ============================================================================
$script:imageCache = @{}

function Load-SlideImage([int]$slideNum) {
    if ($script:imageCache.ContainsKey($slideNum)) {
        return $script:imageCache[$slideNum]
    }
    # Try multiple paths: disc layout, then script-relative (local testing)
    $imgPath = $null
    $candidates = @(
        (Join-Path $DiscPath "Weasis\tutorial\$slideNum.png"),
        (Join-Path $DiscPath "tutorial\$slideNum.png"),
        (Join-Path $PSScriptRoot "tutorial\$slideNum.png")
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $imgPath = $c; break }
    }
    if ($imgPath) {
        try {
            $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
            $bmp.BeginInit()
            $bmp.UriSource = New-Object System.Uri($imgPath, [System.UriKind]::Absolute)
            $bmp.EndInit()
            $bmp.Freeze()
            $script:imageCache[$slideNum] = $bmp
            return $bmp
        } catch {
            return $null
        }
    }
    return $null
}

# ============================================================================
# SLIDE TEXT HELPER
# ============================================================================
function Get-SlideText([int]$slideNum) {
    $s = Get-S
    $key = "Slide$slideNum"
    $text = $s[$key]
    if (-not $text) { return "" }
    return $text
}

# ============================================================================
# UPDATE UI FOR CURRENT SLIDE
# ============================================================================
function Update-Slide {
    $num = $script:currentSlide

    # Image
    $img = Load-SlideImage $num
    if ($img) { $imgSlide.Source = $img }

    # Text
    $txtDescription.Text = Get-SlideText $num

    # Counter
    $s = Get-S
    $txtStepCounter.Text = ($s.StepOf -f $num, $totalSlides)

    # Button states
    if ($num -gt 1) {
        $btnPrev.IsEnabled = $true
        $btnPrev.Opacity = 1.0
    } else {
        $btnPrev.IsEnabled = $false
        $btnPrev.Opacity = 0.4
    }

    if ($num -lt $totalSlides) {
        $btnNext.IsEnabled = $true
        $btnNext.Opacity = 1.0
    } else {
        $btnNext.IsEnabled = $false
        $btnNext.Opacity = 0.4
    }
}

# ============================================================================
# UPDATE LANGUAGE BUTTONS (highlight active)
# ============================================================================
function Update-LangButtons {
    $activeBg   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#0F9B58"))
    $activeFg   = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("White"))
    $inactiveBg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#444444"))
    $inactiveFg = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString("#AAAAAA"))

    $btnLangRO.Background = $inactiveBg; $btnLangRO.Foreground = $inactiveFg
    $btnLangRU.Background = $inactiveBg; $btnLangRU.Foreground = $inactiveFg
    $btnLangEN.Background = $inactiveBg; $btnLangEN.Foreground = $inactiveFg

    switch ($script:currentLang) {
        "ro" { $btnLangRO.Background = $activeBg; $btnLangRO.Foreground = $activeFg }
        "ru" { $btnLangRU.Background = $activeBg; $btnLangRU.Foreground = $activeFg }
        "en" { $btnLangEN.Background = $activeBg; $btnLangEN.Foreground = $activeFg }
    }
}

# ============================================================================
# UPDATE ALL LOCALIZED TEXT
# ============================================================================
function Update-AllText {
    $s = Get-S
    $txtTitle.Text = $s.Title
    $btnPrev.Content = $s.BtnPrev
    $btnNext.Content = $s.BtnNext
    $btnSkip.Content = $s.BtnSkip
    $btnClose.Content = $s.BtnClose
    Update-LangButtons
    Update-Slide
}

# ============================================================================
# EVENT HANDLERS
# ============================================================================

# --- Language switch ---
$btnLangRO.Add_Click({ param($s,$e); $script:currentLang = "ro"; Update-AllText })
$btnLangRU.Add_Click({ param($s,$e); $script:currentLang = "ru"; Update-AllText })
$btnLangEN.Add_Click({ param($s,$e); $script:currentLang = "en"; Update-AllText })

# --- Navigation ---
$btnPrev.Add_Click({ param($s,$e)
    if ($script:currentSlide -gt 1) {
        $script:currentSlide--
        Update-Slide
    }
})

$btnNext.Add_Click({ param($s,$e)
    if ($script:currentSlide -lt $totalSlides) {
        $script:currentSlide++
        Update-Slide
    }
})

# --- Skip (don't show again) ---
$btnSkip.Add_Click({ param($s,$e)
    try {
        $dir = Join-Path $env:APPDATA "WeasisBurn"
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($skipFile, "skipped")
    } catch { }
    $window.Close()
})

# --- Close (will show again next time) ---
$btnClose.Add_Click({ param($s,$e); $window.Close() })
$btnCloseWin.Add_Click({ param($s,$e); $window.Close() })

# --- Minimize ---
$btnMinimize.Add_Click({ param($s,$e)
    $window.WindowState = [System.Windows.WindowState]::Minimized
})

# --- Keyboard navigation ---
$window.Add_KeyDown({ param($s,$e)
    if ($e.Key -eq "Left") {
        if ($script:currentSlide -gt 1) { $script:currentSlide--; Update-Slide }
    }
    elseif ($e.Key -eq "Right") {
        if ($script:currentSlide -lt $totalSlides) { $script:currentSlide++; Update-Slide }
    }
    elseif ($e.Key -eq "Escape") {
        $window.Close()
    }
})

# --- Allow dragging the borderless window ---
$window.Add_MouseLeftButtonDown({ param($s,$e)
    try { $window.DragMove() } catch { }
})

# --- Window Loaded ---
$window.Add_Loaded({ param($s,$e)
    Update-AllText
})

# ============================================================================
# SHOW WINDOW
# ============================================================================
$window.ShowDialog() | Out-Null
