param(
  [string]$Path,
  [string]$Mode = 'report',   # report | dark | erase | alpha
  [int]$SeedX = -1,
  [int]$SeedY = -1,
  [int]$MinLum = 170,         # нижняя граница яркости для «светлого» мусора
  [int]$MaxLum = 255,
  [int]$MaxSat = 30,          # максимальная насыщенность (max-min), чтобы не задеть цветное
  [int]$MinArea = 20,
  [string]$Out = ''
)
Add-Type -AssemblyName System.Drawing

$img = $null; $w = 0; $h = 0; $px = $null

function Load-Img([string]$p) {
  $bytes0 = [System.IO.File]::ReadAllBytes($p)
  $ms = New-Object System.IO.MemoryStream(,$bytes0)
  $bmp = [System.Drawing.Bitmap]::new($ms)
  $script:w = $bmp.Width; $script:h = $bmp.Height
  $data = $bmp.LockBits([System.Drawing.Rectangle]::new(0,0,$script:w,$script:h),
      [System.Drawing.Imaging.ImageLockMode]::ReadWrite,
      [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $bytes = New-Object byte[] ($script:w*$script:h*4)
  [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
  $bmp.UnlockBits($data)
  $script:img = @{ Bmp=$bmp }
  $script:px = $bytes
}

function Save-Img([string]$p) {
  $bmp = $script:img.Bmp
  $data = $bmp.LockBits([System.Drawing.Rectangle]::new(0,0,$script:w,$script:h),
      [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
      [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  [System.Runtime.InteropServices.Marshal]::Copy($script:px, 0, $data.Scan0, $script:px.Length)
  $bmp.UnlockBits($data)
  $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
}

function Lum([int]$i) { return ([int]$script:px[$i] + [int]$script:px[$i+1] + [int]$script:px[$i+2]) / 3.0 }
function Sat([int]$i) {
  $r=[int]$script:px[$i]; $g=[int]$script:px[$i+1]; $b=[int]$script:px[$i+2]
  return ([Math]::Max($r,[Math]::Max($g,$b)) - [Math]::Min($r,[Math]::Min($g,$b)))
}
function Passable([int]$x,[int]$y) {
  $i = ($y*$script:w + $x)*4
  if ($script:px[$i+3] -le 8) { return $true }               # прозрачный фон — проходим
  $l = Lum $i
  if ($l -lt $script:MinLum -or $l -gt $script:MaxLum) { return $false }
  if ((Sat $i) -gt $script:MaxSat) { return $false }
  return $true
}

Load-Img $Path

if ($Mode -eq 'report') {
  $seen = New-Object bool[] ($w*$h); $blobs = @()
  for ($y=0; $y -lt $h; $y++) { for ($x=0; $x -lt $w; $x++) {
    if ($seen[$y*$w+$x]) { continue }
    $i = ($y*$w+$x)*4
    if ($px[$i+3] -le 8) { continue }
    if ((Lum $i) -lt $MinLum -or (Sat $i) -gt $MaxSat) { continue }
    $stack = New-Object System.Collections.Stack; $stack.Push(@($x,$y)); $seen[$y*$w+$x] = $true
    $minX=$x;$maxX=$x;$minY=$y;$maxY=$y;$area=0
    while ($stack.Count -gt 0) {
      $pt=$stack.Pop(); $cx=$pt[0]; $cy=$pt[1]; $area++
      if ($cx -lt $minX){$minX=$cx}; if ($cx -gt $maxX){$maxX=$cx}
      if ($cy -lt $minY){$minY=$cy}; if ($cy -gt $maxY){$maxY=$cy}
      foreach ($d in @(@(1,0),@(-1,0),@(0,1),@(0,-1))) {
        $nx=$cx+$d[0]; $ny=$cy+$d[1]
        if ($nx -lt 0 -or $ny -lt 0 -or $nx -ge $w -or $ny -ge $h) { continue }
        if ($seen[$ny*$w+$nx]) { continue }
        $ni = ($ny*$w+$nx)*4
        if ($px[$ni+3] -le 8) { continue }
        if ((Lum $ni) -lt $MinLum -or (Sat $ni) -gt $MaxSat) { continue }
        $seen[$ny*$w+$nx] = $true; $stack.Push(@($nx,$ny))
      }
    }
    if ($area -ge $MinArea) { $blobs += [pscustomobject]@{Area=$area;X=$minX;Y=$minY;W=($maxX-$minX+1);H=($maxY-$minY+1)} }
  } }
  "file: $(Split-Path $Path -Leaf) ${w}x${h} blobs: $($blobs.Count)"
  $blobs | Sort-Object Area -Descending | Select-Object -First 8 | Format-Table -AutoSize | Out-String
  $img.Bmp.Dispose()
  return
}

if ($Mode -eq 'dark') {
  $out = if ($Out) { $Out } else { $Path }
  for ($i=0; $i -lt $px.Length; $i+=4) {
    $a = $px[$i+3]
    $px[$i]   = [int]($px[$i]*$a/255   + 26*(1-$a/255))
    $px[$i+1] = [int]($px[$i+1]*$a/255 + 31*(1-$a/255))
    $px[$i+2] = [int]($px[$i+2]*$a/255 + 38*(1-$a/255))
    $px[$i+3] = 255
  }
  Save-Img $out
  "ok -> $out"
  return
}

if ($Mode -eq 'erase') {
  if ($SeedX -lt 0) { 'need SeedX/SeedY'; return }
  $stack = New-Object System.Collections.Stack; $stack.Push(@($SeedX,$SeedY))
  $seen = New-Object bool[] ($w*$h); $painted = 0
  while ($stack.Count -gt 0) {
    $pt=$stack.Pop(); $cx=$pt[0]; $cy=$pt[1]
    if ($cx -lt 0 -or $cy -lt 0 -or $cx -ge $w -or $cy -ge $h) { continue }
    $idx = $cy*$w+$cx
    if ($seen[$idx]) { continue }
    if (-not (Passable $cx $cy)) { continue }
    $seen[$idx] = $true
    $i = $idx*4
    if ($px[$i+3] -gt 8) { $px[$i+3] = 0; $painted++ }
    foreach ($d in @(@(1,0),@(-1,0),@(0,1),@(0,-1))) { $stack.Push(@(($cx+$d[0]),($cy+$d[1]))) }
  }
  $out = if ($Out) { $Out } else { $Path }
  Save-Img $out
  "erased $painted px -> $out"
  return
}

if ($Mode -eq 'alpha') {
  $fixed = 0
  for ($i=0; $i -lt $px.Length; $i+=4) {
    $a = $px[$i+3]
    if ($a -gt 20 -and $a -lt 250) {
      $l = ([int]$px[$i] + [int]$px[$i+1] + [int]$px[$i+2]) / 3.0
      if ($l -ge $MinLum -and (Sat $i) -le $MaxSat) { $px[$i+3] = 255; $fixed++ }
    }
  }
  $out = if ($Out) { $Out } else { $Path }
  Save-Img $out
  "alpha fixed $fixed px -> $out"
  return
}

if ($Mode -eq 'border') {
  $stack = New-Object System.Collections.Stack
  for ($x=0; $x -lt $w; $x++) { $stack.Push(@($x,0)); $stack.Push(@($x,($h-1))) }
  for ($y=0; $y -lt $h; $y++) { $stack.Push(@(0,$y)); $stack.Push(@(($w-1),$y)) }
  $seen = New-Object bool[] ($w*$h); $painted = 0
  while ($stack.Count -gt 0) {
    $pt=$stack.Pop(); $cx=$pt[0]; $cy=$pt[1]
    if ($cx -lt 0 -or $cy -lt 0 -or $cx -ge $w -or $cy -ge $h) { continue }
    $idx = $cy*$w+$cx
    if ($seen[$idx]) { continue }
    if (-not (Passable $cx $cy)) { continue }
    $seen[$idx] = $true
    $i = $idx*4
    if ($px[$i+3] -gt 8) { $px[$i+3] = 0; $painted++ }
    foreach ($d in @(@(1,0),@(-1,0),@(0,1),@(0,-1))) { $stack.Push(@(($cx+$d[0]),($cy+$d[1]))) }
  }
  $out = if ($Out) { $Out } else { $Path }
  Save-Img $out
  "border erased $painted px -> $out"
  return
}
if ($Mode -eq 'erase2') {
  # только по цвету, прозрачное не считаем проходимым (для теней и пятен)
  if ($SeedX -lt 0) { 'need SeedX/SeedY'; return }
  $stack = New-Object System.Collections.Stack; $stack.Push(@($SeedX,$SeedY))
  $seen = New-Object bool[] ($w*$h); $painted = 0
  while ($stack.Count -gt 0) {
    $pt=$stack.Pop(); $cx=$pt[0]; $cy=$pt[1]
    if ($cx -lt 0 -or $cy -lt 0 -or $cx -ge $w -or $cy -ge $h) { continue }
    $idx = $cy*$w+$cx
    if ($seen[$idx]) { continue }
    $i = $idx*4
    if ($px[$i+3] -le 8) { $seen[$idx]=$true; continue }
    $l = ([int]$px[$i]+[int]$px[$i+1]+[int]$px[$i+2])/3.0
    if ($l -lt $MinLum -or $l -gt $MaxLum -or (Sat $i) -gt $MaxSat) { continue }
    $seen[$idx] = $true
    $px[$i+3] = 0; $painted++
    foreach ($d in @(@(1,0),@(-1,0),@(0,1),@(0,-1))) { $stack.Push(@(($cx+$d[0]),($cy+$d[1]))) }
  }
  $out = if ($Out) { $Out } else { $Path }
  Save-Img $out
  "erase2 $painted px -> $out"
  return
}