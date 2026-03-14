# Generate custom icon for DicomReceiver application
# Design: Blue disc with white DICOM cross symbol
# Sizes: 16, 32, 48, 256 (standard ICO multi-resolution)

Add-Type -AssemblyName System.Drawing

function New-IconImage {
    param([int]$Size)

    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

    # Clear transparent
    $g.Clear([System.Drawing.Color]::Transparent)

    $margin = [math]::Max(1, [int]($Size * 0.04))
    $circleSize = $Size - 2 * $margin

    # Outer circle — dark blue-teal gradient background
    $outerRect = New-Object System.Drawing.Rectangle($margin, $margin, $circleSize, $circleSize)
    $outerBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        $outerRect,
        [System.Drawing.Color]::FromArgb(255, 25, 118, 160),   # Teal blue
        [System.Drawing.Color]::FromArgb(255, 15, 80, 130),    # Darker blue
        [System.Drawing.Drawing2D.LinearGradientMode]::ForwardDiagonal
    )
    $g.FillEllipse($outerBrush, $outerRect)

    # Subtle border
    $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200, 10, 60, 100), [math]::Max(1, $Size * 0.02))
    $g.DrawEllipse($borderPen, $outerRect)

    # Inner disc hole (like a CD/DVD center)
    $holeSize = [int]($Size * 0.15)
    $holeX = [int](($Size - $holeSize) / 2)
    $holeBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 12, 70, 110))
    $g.FillEllipse($holeBrush, $holeX, $holeX, $holeSize, $holeSize)

    # Medical cross — white, positioned around the center
    $whiteBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(240, 255, 255, 255))
    $crossThick = [math]::Max(2, [int]($Size * 0.14))
    $crossLen = [int]($Size * 0.50)
    $crossStart = [int](($Size - $crossLen) / 2)
    $crossMid = [int](($Size - $crossThick) / 2)

    # Horizontal bar
    $g.FillRectangle($whiteBrush, $crossStart, $crossMid, $crossLen, $crossThick)
    # Vertical bar
    $g.FillRectangle($whiteBrush, $crossMid, $crossStart, $crossThick, $crossLen)

    # Small orange/amber accent dot (bottom-right) — represents "burn" / fire
    $dotSize = [int]($Size * 0.18)
    $dotX = [int]($Size * 0.70)
    $dotY = [int]($Size * 0.70)
    $dotBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 255, 152, 0))  # Amber
    $g.FillEllipse($dotBrush, $dotX, $dotY, $dotSize, $dotSize)
    $dotBorderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200, 200, 100, 0), [math]::Max(1, $Size * 0.015))
    $g.DrawEllipse($dotBorderPen, $dotX, $dotY, $dotSize, $dotSize)

    # Cleanup
    $g.Dispose()
    $outerBrush.Dispose()
    $borderPen.Dispose()
    $holeBrush.Dispose()
    $whiteBrush.Dispose()
    $dotBrush.Dispose()
    $dotBorderPen.Dispose()

    return $bmp
}

function Save-MultiSizeIcon {
    param([string]$OutputPath, [int[]]$Sizes)

    # ICO file format:
    # Header: 6 bytes (reserved=0, type=1, count=N)
    # Directory entries: 16 bytes each
    # Image data: PNG encoded bitmaps

    $images = @()
    $pngData = @()

    foreach ($size in $Sizes) {
        $bmp = New-IconImage -Size $size
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $pngData += ,($ms.ToArray())
        $images += @{ Width = $size; Height = $size; Data = $ms.ToArray() }
        $ms.Dispose()
        $bmp.Dispose()
    }

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

        $bw.Write([byte]$w)           # Width (0 = 256)
        $bw.Write([byte]$h)           # Height (0 = 256)
        $bw.Write([byte]0)            # Color palette
        $bw.Write([byte]0)            # Reserved
        $bw.Write([uint16]1)          # Color planes
        $bw.Write([uint16]32)         # Bits per pixel
        $bw.Write([uint32]$img.Data.Length)   # Image data size
        $bw.Write([uint32]$currentOffset)     # Offset to image data

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

# Generate the icon
$outputPath = Join-Path $PSScriptRoot "..\src\DicomReceiver\Resources\app.ico"
Save-MultiSizeIcon -OutputPath $outputPath -Sizes @(16, 32, 48, 256)

Write-Host "Done!"
