param(
  [string]$Path,
  [string]$Mode = 'report',      # report | fill | alpha
  [int]$SeedX = -1,
  [int]$SeedY = -1,
  [int]$Tol = 24,                # допуск по цвету от белого
  [int]$MinArea = 20,
  [string]$Out = ''
)
Add-Type -AssemblyName System.Drawing

function Load-Rgba([string]$p) {
  $bmp = [System.Drawing.Bitmap]::new($p)
  $w = $bmp.Width; $h = $bmp.Height
  $data = $bmp.LockBits([System.Drawing.Rectangle]::new(0,0,$w,$h),
      [System.Drawing.Imaging.ImageLockMode]::ReadWrite,
      [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $bytes = New-Object byte[] ($w*$h*4)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
  $bmp.UnlockBits($data)
  return @{ Bmp=$bmp; W=$w; H=$h; Px=$bytes }
}

function Save-Rgba($img, [string]$p) {
  $bmp = $img.Bmp
  $data = $bmp.LockBits([System.Drawing.Rectangle]::new(0,0,$img.W,$img.H),
      [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
      [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  [System.Runtime.InteropServices.Marshal]::Copy($img.Px, 0, $data.Scan0, $img.Px.Length)
  $bmp.UnlockBits($data)
  $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

$img = Load-Rgba $Path
$w = $img.W; $h = $img.H; $px = $img.Px

function IsWhite([int]$x, [int]$y) {
  $i = ($y*$w + $x)*4
  return ($px[$i+3] -gt 8) -and ($px[$i] -ge (255-$Tol)) -and ($px[$i+1] -ge (255-$Tol)) -and ($px[$i+2] -ge (255-$Tol))
}

if ($Mode -eq 'report') {
  $seen = New-Object bool[] ($w*$h)
  $blobs = @()
  for ($y=0; $y -lt $h; $y++) {
    for ($x=0; $x -lt $w; $x++) {
      if ($seen[$y*$w+$x]) { continue }
      if (-not (IsWhite $x $y)) { continue }
      $stack = New-Object System.Collections.Stack
      $stack.Push(@($x,$y)); $seen[$y*$w+$x] = $true
      $minX=$x; $maxX=$x; $minY=$y; $maxY=$y; $area=0; $touchEdge=$false
      while ($stack.Count -gt 0) {
        $pt = $stack.Pop(); $cx=$pt[0]; $cy=$pt[1]; $area++
        if ($cx -lt $minX){$minX=$cx}; if ($cx -gt $maxX){$maxX=$cx}
        if ($cy -lt $minY){$minY=$cy}; if ($cy -gt $maxY){$maxY=$cy}
        if ($cx -le 1 -or $cy -le 1 -or $cx -ge $w-2 -or $cy -ge $h-2) { $touchEdge = $true }
        foreach ($d in @(@(1,0),@(-1,0),@(0,1),@(0,-1))) {
          $nx=$cx+$d[0]; $ny=$cy+$d[1]
          if ($nx -lt 0 -or $ny -lt 0 -or $nx -ge $w -or $ny -ge $h) { continue }
          if ($seen[$ny*$w+$nx]) { continue }
          if (IsWhite $nx $ny) { $seen[$ny*$w+$nx] = $true; $stack.Push(@($nx,$ny)) }
        }
      }
      if ($area -ge $MinArea) {
        $blobs += [pscustomobject]@{ Area=$area; X=$minX; Y=$minY; W=($maxX-$minX+1); H=($maxY-$minY+1); Edge=$touchEdge }
      }
    }
  }
  $img.Bmp.Dispose()
  "файл: $(Split-Path $Path -Leaf)  ${w}x${h}, пятен: $($blobs.Count)"
  $blobs | Sort-Object Area -Descending | Select-Object -First 10 | Format-Table -AutoSize | Out-String
  return
}

if ($Mode -eq 'fill') {
  if ($SeedX -lt 0) { 'нужен SeedX/SeedY'; return }
  $stack = New-Object System.Collections.Stack
  $stack.Push(@($SeedX,$SeedY)); $seen = New-Object bool[] ($w*$h)
  $painted = 0
  while ($stack.Count -gt 0) {
    $pt = $stack.Pop(); $cx=$pt[0]; $cy=$pt[1]
    if ($cx -lt 0 -or $cy -lt 0 -or $cx -ge $w -or $cy -ge $h) { continue }
    if ($seen[$cy*$w+$cx]) { continue }
    if (-not (IsWhite $cx $cy)) { continue }
    $seen[$cy*$w+$cx] = $true
    $px[($cy*$w+$cx)*4+3] = 0
    $painted++
    foreach ($d in @(@(1,0),@(-1,0),@(0,1),@(0,-1))) { $stack.Push(@(($cx+$d[0]),($cy+$d[1]))) }
  }
  $outPath = if ($Out) { $Out } else { $Path }
  Save-Rgba $img $outPath
  "закрашено пикселей: $painted -> $outPath"
  return
}

if ($Mode -eq 'alpha') {
  # полупрозрачные почти-белые пиксели (зубы) делаем непрозрачными
  $fixed = 0
  for ($i=0; $i -lt $px.Length; $i+=4) {
    $a = $px[$i+3]
    if ($a -gt 20 -and $a -lt 250) {
      if ($px[$i] -ge 185 -and $px[$i+1] -ge 185 -and $px[$i+2] -ge 185) {
        $m = [Math]::Min($px[$i], [Math]::Min($px[$i+1], $px[$i+2]))
        $mx = [Math]::Max($px[$i], [Math]::Max($px[$i+1], $px[$i+2]))
        if (($mx - $m) -le 40) { $px[$i+3] = 255; $fixed++ }
      }
    }
  }
  $outPath = if ($Out) { $Out } else { $Path }
  Save-Rgba $img $outPath
  "уплотнено пикселей: $fixed -> $outPath"
  return
}

if ($Mode -eq 'mark') {
  $seen = New-Object bool[] ($w*$h)
  for ($y=0; $y -lt $h; $y++) {
    for ($x=0; $x -lt $w; $x++) {
      if ($seen[$y*$w+$x]) { continue }
      if (-not (IsWhite $x $y)) { continue }
      $stack = New-Object System.Collections.Stack
      $stack.Push(@($x,$y)); $seen[$y*$w+$x] = $true
      $cells = New-Object System.Collections.ArrayList
      while ($stack.Count -gt 0) {
        $pt = $stack.Pop(); $cx=$pt[0]; $cy=$pt[1]
        [void]$cells.Add(@($cx,$cy))
        foreach ($d in @(@(1,0),@(-1,0),@(0,1),@(0,-1))) {
          $nx=$cx+$d[0]; $ny=$cy+$d[1]
          if ($nx -lt 0 -or $ny -lt 0 -or $nx -ge $w -or $ny -ge $h) { continue }
          if ($seen[$ny*$w+$nx]) { continue }
          if (IsWhite $nx $ny) { $seen[$ny*$w+$nx] = $true; $stack.Push(@($nx,$ny)) }
        }
      }
      if ($cells.Count -ge $MinArea) {
        foreach ($c in $cells) {
          $i = ($c[1]*$w + $c[0])*4
          $px[$i]=255; $px[$i+1]=0; $px[$i+2]=255; $px[$i+3]=200
        }
      }
    }
  }
  $outPath = if ($Out) { $Out } else { $Path }
  Save-Rgba $img $outPath
  "помечено -> $outPath"
  return
}
if ($Mode -eq 'dark') {
  # фон тёмный, чтобы видеть белые артефакты; пятна красим в малиновый
  $seen = New-Object bool[] ($w*$h)
  $marks = New-Object bool[] ($w*$h)
  for ($y=0; $y -lt $h; $y++) {
    for ($x=0; $x -lt $w; $x++) {
      if ($seen[$y*$w+$x]) { continue }
      if (-not (IsWhite $x $y)) { continue }
      $stack = New-Object System.Collections.Stack
      $stack.Push(@($x,$y)); $seen[$y*$w+$x] = $true
      $cells = New-Object System.Collections.ArrayList
      while ($stack.Count -gt 0) {
        $pt = $stack.Pop(); $cx=$pt[0]; $cy=$pt[1]
        [void]$cells.Add(@($cx,$cy))
        foreach ($d in @(@(1,0),@(-1,0),@(0,1),@(0,-1))) {
          $nx=$cx+$d[0]; $ny=$cy+$d[1]
          if ($nx -lt 0 -or $ny -lt 0 -or $nx -ge $w -or $ny -ge $h) { continue }
          if ($seen[$ny*$w+$nx]) { continue }
          if (IsWhite $nx $ny) { $seen[$ny*$w+$nx] = $true; $stack.Push(@($nx,$ny)) }
        }
      }
      if ($cells.Count -ge $MinArea) {
        foreach ($c in $cells) { $marks[$c[1]*$w + $c[0]] = $true }
      }
    }
  }
  for ($i=0; $i -lt $px.Length; $i+=4) {
    $a = $px[$i+3]
    $idx = $i/4
    $r = [int]($px[$i]*$a/255 + 22*(1-$a/255))
    $g = [int]($px[$i+1]*$a/255 + 27*(1-$a/255))
    $b = [int]($px[$i+2]*$a/255 + 34*(1-$a/255))
    if ($marks[$idx]) { $r=255; $g=0; $b=120 }
    $px[$i]=$r; $px[$i+1]=$g; $px[$i+2]=$b; $px[$i+3]=255
  }
  $outPath = if ($Out) { $Out } else { $Path }
  Save-Rgba $img $outPath
  "готово -> $outPath"
  return
}