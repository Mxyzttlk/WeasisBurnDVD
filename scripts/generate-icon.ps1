# Generate custom icon for DicomReceiver application
# Design: Radiology-themed — dark blue circle with stylized radiation trefoil symbol
# The trefoil (3 blades) is the universal radiology/radiation symbol
# Colors: bright cyan blades on dark blue, small orange DVD accent
# Sizes: 16, 32, 48, 256 (standard ICO multi-resolution)

Add-Type -AssemblyName System.Drawing

function New-IconImage {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    $g.Clear([System.Drawing.Color]::Transparent)

    $margin = [math]::Max(1, [int]($Size * 0.03))
    $circleSize = $Size - 2 * $margin
    $cx = $Size / 2.0   # center X
    $cy = $Size / 2.0   # center Y

    # --- Background circle: dark blue gradient ---
    $outerRect = New-Object System.Drawing.Rectangle($margin, $margin, $circleSize, $circleSize)
    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $outerRect,
        [System.Drawing.Color]::FromArgb(255, 20, 50, 80),    # Dark navy top-left
        [System.Drawing.Color]::FromArgb(255, 10, 30, 55),    # Even darker bottom-right
        [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal
    )
    $g.FillEllipse($bgBrush, $outerRect)

    # Subtle border glow
    $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(120, 40, 140, 200), [math]::Max(1, $Size * 0.02))
    $g.DrawEllipse($borderPen, $outerRect)

    # --- Radiation trefoil (3 blades at 120 degrees) ---
    # Each blade is a pie slice: inner radius to outer radius, 50-degree arc
    $bladeOuterR = $Size * 0.38    # outer radius of blades
    $bladeInnerR = $Size * 0.14    # inner radius (gap around center)
    $bladeAngle = 50               # each blade arc span in degrees
    $startAngles = @(-115, 5, 125) # 3 blades at 120-degree intervals (rotated so top blade is centered)

    # Blade color: bright cyan
    $bladeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 60, 200, 240))

    foreach ($startAngle in $startAngles) {
        # Create a pie-shaped path for each blade
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath

        # Outer arc
        $outerArcRect = New-Object System.Drawing.RectangleF(
            [float]($cx - $bladeOuterR), [float]($cy - $bladeOuterR),
            [float]($bladeOuterR * 2), [float]($bladeOuterR * 2)
        )
        $path.AddArc($outerArcRect, $startAngle, $bladeAngle)

        # Inner arc (reverse direction to close the shape)
        $innerArcRect = New-Object System.Drawing.RectangleF(
            [float]($cx - $bladeInnerR), [float]($cy - $bladeInnerR),
            [float]($bladeInnerR * 2), [float]($bladeInnerR * 2)
        )
        # Connect outer end to inner end with line, then inner arc reversed
        $endAngle = $startAngle + $bladeAngle
        $innerEndX = $cx + $bladeInnerR * [math]::Cos($endAngle * [math]::PI / 180)
        $innerEndY = $cy + $bladeInnerR * [math]::Sin($endAngle * [math]::PI / 180)
        $path.AddLine(
            [float]($cx + $bladeOuterR * [math]::Cos($endAngle * [math]::PI / 180)),
            [float]($cy + $bladeOuterR * [math]::Sin($endAngle * [math]::PI / 180)),
            [float]$innerEndX, [float]$innerEndY
        )
        $path.AddArc($innerArcRect, [float]$endAngle, [float](-$bladeAngle))
        $path.CloseFigure()

        $g.FillPath($bladeBrush, $path)
        $path.Dispose()
    }

    # --- Center dot (small bright circle) ---
    $centerDotR = [math]::Max(2, [int]($Size * 0.07))
    $centerDotBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 80, 210, 245))
    $g.FillEllipse($centerDotBrush, [float]($cx - $centerDotR), [float]($cy - $centerDotR),
        [float]($centerDotR * 2), [float]($centerDotR * 2))

    # --- Small orange DVD disc accent (bottom-right corner) ---
    $dvdSize = [int]($Size * 0.22)
    $dvdX = [int]($Size * 0.68)
    $dvdY = [int]($Size * 0.68)

    # Orange disc
    $dvdBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240, 255, 152, 0))
    $g.FillEllipse($dvdBrush, $dvdX, $dvdY, $dvdSize, $dvdSize)

    # Disc hole
    $holeSize = [math]::Max(2, [int]($dvdSize * 0.30))
    $holeX = [int]($dvdX + ($dvdSize - $holeSize) / 2)
    $holeY = [int]($dvdY + ($dvdSize - $holeSize) / 2)
    $holeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 200, 110, 0))
    $g.FillEllipse($holeBrush, $holeX, $holeY, $holeSize, $holeSize)

    # Disc border
    $dvdBorderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(180, 180, 90, 0), [math]::Max(1, $Size * 0.01))
    $g.DrawEllipse($dvdBorderPen, $dvdX, $dvdY, $dvdSize, $dvdSize)

    # Cleanup
    $g.Dispose()
    $bgBrush.Dispose()
    $borderPen.Dispose()
    $bladeBrush.Dispose()
    $centerDotBrush.Dispose()
    $dvdBrush.Dispose()
    $holeBrush.Dispose()
    $dvdBorderPen.Dispose()

    return $bmp
}

function Resize-Image {
    param([System.Drawing.Bitmap]$Source, [int]$TargetSize)

    $dst = New-Object System.Drawing.Bitmap($TargetSize, $TargetSize)
    $g = [System.Drawing.Graphics]::FromImage($dst)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
    $g.DrawImage($Source, 0, 0, $TargetSize, $TargetSize)
    $g.Dispose()
    return $dst
}

function Save-MultiSizeIcon {
    param([string]$OutputPath, [int[]]$Sizes)

    # Render at high resolution (512px) then downscale for sharp results
    $baseSize = 512
    $baseBmp = New-IconImage -Size $baseSize
    $images = @()

    foreach ($size in $Sizes) {
        if ($size -eq $baseSize) {
            $bmp = $baseBmp.Clone()
        } else {
            $bmp = Resize-Image -Source $baseBmp -TargetSize $size
        }
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $images += @{ Width = $size; Height = $size; Data = $ms.ToArray() }
        $ms.Dispose()
        $bmp.Dispose()
    }
    $baseBmp.Dispose()

    $count = $images.Count
    $headerSize = 6
    $dirEntrySize = 16
    $dataOffset = $headerSize + ($dirEntrySize * $count)

    $fs = [System.IO.File]::Create($OutputPath)
    $bw = New-Object System.IO.BinaryWriter($fs)

    # ICO Header
    $bw.Write([uint16]0)       # Reserved
    $bw.Write([uint16]1)       # Type: 1 = ICO
    $bw.Write([uint16]$count)  # Image count

    # Directory entries
    $currentOffset = $dataOffset
    for ($i = 0; $i -lt $count; $i++) {
        $img = $images[$i]
        $w = if ($img.Width -ge 256) { 0 } else { $img.Width }
        $h = if ($img.Height -ge 256) { 0 } else { $img.Height }

        $bw.Write([byte]$w)
        $bw.Write([byte]$h)
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([uint16]1)
        $bw.Write([uint16]32)
        $bw.Write([uint32]$img.Data.Length)
        $bw.Write([uint32]$currentOffset)

        $currentOffset += $img.Data.Length
    }

    # Image data (PNG)
    for ($i = 0; $i -lt $count; $i++) {
        $bw.Write($images[$i].Data)
    }

    $bw.Close()
    $fs.Close()

    Write-Host "Icon saved: $OutputPath ($count sizes: $($Sizes -join ', ')px)"
}

# Also save a preview PNG at 256px for easy viewing
function Save-Preview {
    param([string]$OutputPath)
    $bmp = New-IconImage -Size 512
    $bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "Preview saved: $OutputPath (512px)"
}

# Generate the icon
$outputPath = Join-Path $PSScriptRoot "..\src\DicomReceiver\Resources\app.ico"
Save-MultiSizeIcon -OutputPath $outputPath -Sizes @(16, 32, 48, 256)

# Preview for inspection
$previewPath = Join-Path $PSScriptRoot "..\src\DicomReceiver\Resources\app-preview.png"
Save-Preview -OutputPath $previewPath

Write-Host "Done!"
