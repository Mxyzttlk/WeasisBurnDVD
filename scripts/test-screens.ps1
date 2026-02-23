# Test script - shows each warning/block screen from splash-loader.ps1
# Usage: powershell -sta -ExecutionPolicy Bypass -File test-screens.ps1

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

function Show-Screen {
    param([string]$Title, [string]$Msg, [string]$TitleColor, [bool]$ShowContinue, [string]$WindowTitle)

    $vis = if ($ShowContinue) { "Visible" } else { "Collapsed" }

    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Test" Width="500" Height="420"
        WindowStartupLocation="CenterScreen" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" Topmost="True" ShowInTaskbar="True">
    <Border CornerRadius="12" Background="#1E1E1E" BorderBrush="#333333" BorderThickness="1">
        <Grid Margin="24">
            <StackPanel VerticalAlignment="Center">
                <TextBlock Text="Weasis v3.7.1" FontSize="26" FontWeight="SemiBold"
                           Foreground="#0F9B58" HorizontalAlignment="Center" Margin="0,0,0,24"/>

                <TextBlock Text="&#x26A0;" FontSize="40" Foreground="$TitleColor"
                           HorizontalAlignment="Center" Margin="0,0,0,12"/>

                <TextBlock x:Name="txtTitle" FontSize="15" FontWeight="SemiBold"
                           Foreground="$TitleColor" HorizontalAlignment="Center"
                           TextAlignment="Center" Margin="20,0,20,10" TextWrapping="Wrap"/>
                <TextBlock x:Name="txtMsg" FontSize="13"
                           Foreground="#CCCCCC" HorizontalAlignment="Center"
                           TextAlignment="Center" Margin="20,0,20,28" TextWrapping="Wrap"/>

                <TextBlock x:Name="txtLabel" FontSize="10" Foreground="#666666"
                           HorizontalAlignment="Center" Margin="0,0,0,16"/>

                <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                    <Button x:Name="btnContinue" Content="Continua" Width="120" Height="36" Margin="0,0,16,0"
                            FontSize="14" FontWeight="SemiBold" Cursor="Hand"
                            Foreground="White" Background="#0F9B58" BorderThickness="0"
                            Visibility="$vis">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="12,6">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                    <Button x:Name="btnClose" Content="Inchide" Width="120" Height="36"
                            FontSize="14" FontWeight="SemiBold" Cursor="Hand"
                            Foreground="White" Background="#D32F2F" BorderThickness="0">
                        <Button.Template>
                            <ControlTemplate TargetType="Button">
                                <Border Background="{TemplateBinding Background}" CornerRadius="6" Padding="12,6">
                                    <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </Border>
                            </ControlTemplate>
                        </Button.Template>
                    </Button>
                </StackPanel>
            </StackPanel>
        </Grid>
    </Border>
</Window>
"@

    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $win = [System.Windows.Markup.XamlReader]::Load($reader)

    # Set text via code (avoids XML escaping issues)
    $win.FindName("txtTitle").Text = $Title
    $win.FindName("txtMsg").Text = $Msg
    $win.FindName("txtLabel").Text = $WindowTitle
    $win.FindName("btnClose").Add_Click({ $win.Close() })
    $win.FindName("btnContinue").Add_Click({ $win.Close() })
    $win.Add_MouseLeftButtonDown({ $win.DragMove() })
    $win.ShowDialog() | Out-Null
}

$screens = @(
    @{
        Id    = "os-block"
        WTitle = "[1/4]  OS Block  -  Windows < 10"
        Title = "Sistemul de operare nu indeplineste cerintele"
        Msg   = "Weasis necesita Windows 10 sau mai nou. Recomandam sa folositi aplicatia RadiAnt pentru vizualizarea imaginilor DICOM."
        Color = "#FF6B35"
        Continue = $false
    },
    @{
        Id    = "ram-block"
        WTitle = "[2/4]  RAM Block  -  sub 2 GB"
        Title = "Memorie RAM insuficienta"
        Msg   = "Calculatorul are doar 1.8 GB RAM. Weasis necesita minim 2 GB. Recomandam sa folositi aplicatia RadiAnt."
        Color = "#FF6B35"
        Continue = $false
    },
    @{
        Id    = "ram-warn"
        WTitle = "[3/4]  RAM Warning  -  2-3 GB"
        Title = "Memorie RAM redusa"
        Msg   = "Calculatorul are doar 3.2 GB RAM. Weasis poate functiona lent. Recomandam minim 4 GB RAM sau aplicatia RadiAnt."
        Color = "#FF6B35"
        Continue = $true
    },
    @{
        Id    = "32bit"
        WTitle = "[4/4]  32-bit Warning"
        Title = "Arhitectura calculatorului este pe 32 de biti."
        Msg   = "Se recomanda utilizarea aplicatiei RadiAnt pentru o experienta optima."
        Color = "#FFD740"
        Continue = $true
    }
)

foreach ($s in $screens) {
    Show-Screen -WindowTitle $s.WTitle -Title $s.Title -Msg $s.Msg -TitleColor $s.Color -ShowContinue $s.Continue
}
