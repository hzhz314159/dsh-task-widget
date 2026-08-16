# dsh-task-widget — Windows 桌面独立小组件（液态玻璃任务台）原生渲染器。
# PowerShell + WPF：无边框、始终置顶、Win11/Win10 一致自绘液态玻璃（真高斯模糊）、
# 深/浅色跟随系统、任务完成 toast + 提示音。
#
# v0.3.1 变更：
#   * 真液态玻璃：新增模糊层 BlurMain/BlurUsage——截屏窗口背后的桌面区域，用 WPF
#     BlurEffect 做高斯模糊（截屏前窗口 Opacity=0 暂隐，避免把自身也截进去递归），
#     常驻模糊背景。卡片不再是「纯半透明」，而是「模糊背景 + accent 着色玻璃」。
#   * 两卡一致：主卡与用量卡使用同一模糊层 + 同一 accent 着色玻璃 + 同一描边，
#     消除「两张卡透明度/颜色不同」的问题（accent 只用于着色与描边，不单独填一整张卡）。
#   * 任务卡：区分「项目名」（主行）与「工作区名」（cwd basename，暗色副行）。
#   * 用量卡：改为四项指标——Token 用量 / 当前花费 / 剩余 Token 量 / 剩余额度（2x2）。
#   * 锁定修复保持（v0.3.0）：LockBtn 用 Add_Click，拖拽由 Card 的 Preview 处理器回溯跳过。
#
# 由宿主守护（lib/index.js）派生：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File widget.ps1
#                  -BaseUrl http://127.0.0.1:<port>/dsh-task-widget
#                  -CommandFile <widget>/.command.json
#
# 数据：轮询 /api/snapshot（2s），toast 用快照内 events 增量。
# 控制：轮询 .command.json（500ms）——宿主写 show/hide/toggle/quit/config，本脚本执行后删除。
#
# 注意：本文件必须保持 UTF-8 带 BOM（Windows PowerShell 5.1 无 BOM 时按 ANSI 读取，
# 中文注释/字符串会乱码并导致解析失败）。
param(
  [string]$BaseUrl = 'http://127.0.0.1:5650/dsh-task-widget',
  [string]$CommandFile = ''
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (-not $CommandFile) { $CommandFile = Join-Path $PSScriptRoot '.command.json' }

# ── 用户配置（软件内调整：强调色 / 透明度 / 锁定）────────────────────────
$script:cfg = @{
  accent    = '#4D9FFF'   # 液态玻璃强调色（电光蓝）
  alpha     = 100         # 玻璃着色强度 40..100（越高色彩越浓）
  cardAlpha = 100         # 卡片（玻璃层）整体不透明度 40..100
  locked    = $false       # 位置锁定（锁定时不可拖动）
}
$script:cfgFile = Join-Path $PSScriptRoot '.config.json'
try {
  if (Test-Path $script:cfgFile) {
    $saved = Get-Content $script:cfgFile -Raw | ConvertFrom-Json
    if ($saved.accent -and $saved.accent -match '^#[0-9A-Fa-f]{6}$') { $script:cfg.accent = $saved.accent }
    if ($null -ne $saved.alpha -and [int]$saved.alpha -ge 40 -and [int]$saved.alpha -le 100) { $script:cfg.alpha = [int]$saved.alpha }
    if ($null -ne $saved.cardAlpha -and [int]$saved.cardAlpha -ge 40 -and [int]$saved.cardAlpha -le 100) { $script:cfg.cardAlpha = [int]$saved.cardAlpha }
    if ($null -ne $saved.locked) { $script:cfg.locked = [bool]$saved.locked }
  }
} catch {}

# Win32 P/Invoke：圆角裁剪 + 强制重绘（WPF 失效传播不可靠时兜底）
Add-Type -Namespace DshW -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern int SetWindowCompositionAttribute(IntPtr hwnd, ref WINDOWCOMPOSITIONATTRIBDATA data);
[StructLayout(LayoutKind.Sequential)] public struct ACCENT_POLICY { public int AccentState; public int AccentFlags; public int GradientColor; public int AnimationId; }
[StructLayout(LayoutKind.Sequential)] public struct WINDOWCOMPOSITIONATTRIBDATA { public int Attribute; public IntPtr Data; public int SizeOfData; }
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int attrValue, int attrSize);
[DllImport("gdi32.dll")] public static extern IntPtr CreateRoundRectRgn(int left, int top, int right, int bottom, int w, int h);
[DllImport("user32.dll")] public static extern int SetWindowRgn(IntPtr hWnd, IntPtr hRgn, bool bRedraw);
[DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr hWnd, IntPtr lprcUpdate, IntPtr hrgnUpdate, uint flags);
'@

$isWin11 = $env:OS -eq "Windows_NT" -and [Environment]::OSVersion.Version.Build -ge 22000

# ── XAML 布局 ────────────────────────────────────────────────────────
# 事件一律不写在 XAML 属性里（XamlReader 无法为 PS 函数建委托，会抛异常），
# 统一在下方 FindName 之后用 Add_* 接线。
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="DSH 任务台" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True"
        Width="340" Height="512" FontFamily="Segoe UI Variable Text, Segoe UI, Microsoft YaHei" UseLayoutRounding="True">
  <Grid Margin="12,10,12,12">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- 主卡（任务区）：自身柔和投影层 + 玻璃卡 -->
    <Grid Grid.Row="0">
      <Border x:Name="MainShadow" CornerRadius="24" Background="#0A0F1A" Opacity="0.34" IsHitTestVisible="False">
        <Border.Effect><BlurEffect Radius="22"/></Border.Effect>
      </Border>
      <Border x:Name="Card" CornerRadius="22" BorderThickness="1" ClipToBounds="True" Background="Transparent" Cursor="SizeAll">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="*"/>
            <RowDefinition Height="30"/>
          </Grid.RowDefinitions>
          <!-- 模糊层（截屏背后桌面 + 高斯模糊），覆盖整卡 -->
          <Image x:Name="BlurMain" Grid.Row="0" Grid.RowSpan="2" Stretch="Fill" Panel.ZIndex="-2" IsHitTestVisible="False"/>
          <!-- accent 着色玻璃（半透明，模糊透出） -->
          <Border x:Name="TintMain" Grid.Row="0" Grid.RowSpan="2" Panel.ZIndex="-1" IsHitTestVisible="False"/>
          <!-- 顶部液态高光带（玻璃反射，置于内容之上） -->
          <Border x:Name="GlossLine" Grid.Row="0" Height="2" VerticalAlignment="Top" Margin="20,0" IsHitTestVisible="False" Panel.ZIndex="10"/>
          <!-- 顶部径向高光（光打在玻璃上的漫反射，置于内容之下） -->
          <Border x:Name="SpecGlow" Grid.Row="0" Height="140" VerticalAlignment="Top" Margin="0" IsHitTestVisible="False" Panel.ZIndex="0"/>
          <!-- 任务列表（滚动区） -->
          <ScrollViewer x:Name="Body" Grid.Row="0" VerticalScrollBarVisibility="Hidden" HorizontalScrollBarVisibility="Disabled" Padding="12,10,12,4" Panel.ZIndex="1">
            <StackPanel>
              <StackPanel x:Name="TaskPanel"/>
              <TextBlock x:Name="Offline" Text="与 DSH 服务断开连接，重连中…" FontSize="10.5" Margin="2,6,0,0" Visibility="Collapsed"/>
            </StackPanel>
          </ScrollViewer>
          <!-- 页脚：更新时间 + 位置锁定（右下角） -->
          <Grid Grid.Row="1" Panel.ZIndex="1">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="FootLeft" Text="—" FontSize="9" VerticalAlignment="Center" Margin="14,0,0,0"/>
            <Button x:Name="LockBtn" Grid.Column="1" Width="26" Height="24" Margin="0,0,10,0" VerticalAlignment="Center" Background="Transparent" BorderThickness="0" Cursor="Hand" ToolTip="锁定位置（锁定后不可拖动）">
              <Button.Style>
                <Style TargetType="Button">
                  <Setter Property="Background" Value="Transparent"/>
                  <Setter Property="BorderThickness" Value="0"/>
                  <Setter Property="Padding" Value="0"/>
                  <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
                  <Setter Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="1" ScaleY="1"/></Setter.Value></Setter>
                  <Style.Triggers>
                    <Trigger Property="IsMouseOver" Value="True"><Setter Property="Opacity" Value="0.85"/></Trigger>
                    <Trigger Property="IsPressed" Value="True"><Setter Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="0.94" ScaleY="0.94"/></Setter.Value></Setter></Trigger>
                  </Style.Triggers>
                </Style>
              </Button.Style>
              <TextBlock x:Name="LockGlyph" Text="&#xE785;" FontFamily="Segoe MDL2 Assets" FontSize="12" VerticalAlignment="Center" HorizontalAlignment="Center"/>
            </Button>
          </Grid>
          <!-- Toast 层 -->
          <StackPanel x:Name="ToastPanel" VerticalAlignment="Top" Margin="10,10,10,0" Panel.ZIndex="20"/>
        </Grid>
      </Border>
    </Grid>

    <!-- Token 用量卡（独立卡片，固定接在主卡底下） -->
    <Grid Grid.Row="1" Margin="0,10,0,0">
      <Border x:Name="UsageShadow" CornerRadius="20" Background="#0A0F1A" Opacity="0.30" IsHitTestVisible="False">
        <Border.Effect><BlurEffect Radius="18"/></Border.Effect>
      </Border>
      <Border x:Name="UsageCard" CornerRadius="18" BorderThickness="1" ClipToBounds="True" Background="Transparent">
        <Grid>
          <Image x:Name="BlurUsage" Stretch="Fill" Panel.ZIndex="-2" IsHitTestVisible="False"/>
          <Border x:Name="TintUsage" Panel.ZIndex="-1" IsHitTestVisible="False"/>
          <Border x:Name="UsageGloss" Height="90" VerticalAlignment="Top" Margin="0" IsHitTestVisible="False" Panel.ZIndex="0"/>
          <StackPanel Margin="12,11,12,11" Panel.ZIndex="1">
            <TextBlock x:Name="UHead" Text="用量" FontSize="11" Margin="0,0,0,8"/>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Grid.Column="0" Margin="0,0,10,8">
                <TextBlock x:Name="UTknL" Text="Token 用量" FontSize="9.5"/>
                <TextBlock x:Name="UTkn" Text="—" FontSize="17" FontWeight="Bold"/>
              </StackPanel>
              <StackPanel Grid.Row="0" Grid.Column="1" Margin="0,0,0,8">
                <TextBlock x:Name="USpendL" Text="当前花费" FontSize="9.5"/>
                <TextBlock x:Name="USpend" Text="—" FontSize="17" FontWeight="Bold"/>
              </StackPanel>
              <StackPanel Grid.Row="1" Grid.Column="0" Margin="0,0,10,0">
                <TextBlock x:Name="URemTknL" Text="剩余 Token 量" FontSize="9.5"/>
                <TextBlock x:Name="URemTkn" Text="—" FontSize="17" FontWeight="Bold"/>
              </StackPanel>
              <StackPanel Grid.Row="1" Grid.Column="1">
                <TextBlock x:Name="UQuotaL" Text="剩余额度" FontSize="9.5"/>
                <TextBlock x:Name="UQuota" Text="—" FontSize="17" FontWeight="Bold"/>
              </StackPanel>
            </Grid>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>
  </Grid>
</Window>
'@

$reader = [System.Windows.Markup.XamlReader]::Parse($xaml)
$win = $reader
$names = @("Card","MainShadow","GlossLine","SpecGlow","BlurMain","TintMain","Body","LockBtn","LockGlyph",
           "UsageCard","UsageShadow","UsageGloss","BlurUsage","TintUsage","UHead","UTkn","UTknL",
           "USpend","USpendL","URemTkn","URemTknL","UQuota","UQuotaL",
           "TaskPanel","Offline",
           "FootLeft","ToastPanel")
$u = @{}
foreach ($n in $names) { $u[$n] = $win.FindName($n) }

# ── 主题刷子 ────────────────────────────────────────────────────────
function New-Brush([string]$hex, [int]$alpha = 255) {
  $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
  return New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb($alpha, $c.R, $c.G, $c.B))
}
function New-Grad([object[]]$stops) {
  $g = New-Object System.Windows.Media.LinearGradientBrush
  $g.StartPoint = New-Object System.Windows.Point(0,0)
  $g.EndPoint = New-Object System.Windows.Point(1,1)
  foreach ($s in $stops) { [void]$g.GradientStops.Add($s) }
  return $g
}
function New-Color([string]$hex, [int]$alpha = 255) {
  $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
  return [System.Windows.Media.Color]::FromArgb($alpha, $c.R, $c.G, $c.B)
}
# 径向高光（光打在玻璃上的漫反射斑）
function New-Radial([string]$hex, [int]$a, [double]$rx, [double]$ry) {
  $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
  $cc = [System.Windows.Media.Color]::FromArgb($a, $c.R, $c.G, $c.B)
  $rs = New-Object System.Windows.Media.RadialGradientBrush
  $rs.Center = New-Object System.Windows.Point(0.5, 0)
  $rs.GradientOrigin = New-Object System.Windows.Point(0.5, 0)
  $rs.RadiusX = $rx; $rs.RadiusY = $ry
  [void]$rs.GradientStops.Add((New-Object System.Windows.Media.GradientStop($cc, 0.0)))
  [void]$rs.GradientStops.Add((New-Object System.Windows.Media.GradientStop([System.Windows.Media.Color]::FromArgb(0, $c.R, $c.G, $c.B), 1.0)))
  return $rs
}

# 着色玻璃（accent 着色 + 顶部白色高光），alpha 控制着色强度
function New-Tint([bool]$light) {
  $k = [double]$script:cfg.alpha / 100.0
  $accent = $script:cfg.accent
  if ($light) {
    $t1 = [int][math]::Round(22 * $k)
    $t2 = [int][math]::Round(60 * $k)
    $t3 = [int][math]::Round(12 * $k)
    return New-Grad @(
      [System.Windows.Media.GradientStop]::new((New-Color $accent $t1), 0.0),
      [System.Windows.Media.GradientStop]::new((New-Color '#FFFFFF' $t2), 0.32),
      [System.Windows.Media.GradientStop]::new((New-Color $accent $t3), 1.0)
    )
  }
  $t1 = [int][math]::Round(28 * $k)
  $t2 = [int][math]::Round(14 * $k)
  $t3 = [int][math]::Round(20 * $k)
  return New-Grad @(
    [System.Windows.Media.GradientStop]::new((New-Color $accent $t1), 0.0),
    [System.Windows.Media.GradientStop]::new((New-Color $accent $t2), 0.5),
    [System.Windows.Media.GradientStop]::new((New-Color $accent $t3), 1.0)
  )
}
# 描边：顶部 accent 亮 + 中部白色高光 + 底部 accent（两卡同款）
function New-BorderSheen([bool]$light) {
  $accent = $script:cfg.accent
  if ($light) {
    return New-Grad @(
      [System.Windows.Media.GradientStop]::new((New-Color $accent 200), 0.0),
      [System.Windows.Media.GradientStop]::new((New-Color '#FFFFFF' 120), 0.18),
      [System.Windows.Media.GradientStop]::new((New-Color $accent 160), 1.0)
    )
  }
  return New-Grad @(
    [System.Windows.Media.GradientStop]::new((New-Color $accent 210), 0.0),
    [System.Windows.Media.GradientStop]::new((New-Color '#FFFFFF' 90), 0.14),
    [System.Windows.Media.GradientStop]::new((New-Color $accent 150), 1.0)
  )
}

function Build-Paint([bool]$light) {
  $ck = [double]$script:cfg.cardAlpha / 100.0   # 卡片（玻璃层）整体不透明度
  if ($light) {
    return @{
      text     = (New-Brush '#1F2430')
      dim      = (New-Brush '#5A6272')
      faint    = (New-Brush '#8A92A5')
      gloss    = (New-Brush '#FFFFFF' 150)
      shade    = (New-Brush '#1F2430' 26)
      cardRow  = (New-Brush $script:cfg.accent 24)
      cardRowB = (New-Brush $script:cfg.accent 46)
      rowTop   = (New-Brush '#FFFFFF' 120)
      rowBot   = (New-Brush '#FFFFFF' 48)
      live     = (New-Brush '#0FA968')
      idle     = (New-Brush '#9AA3B8')
      err      = (New-Brush '#D6454F')
      warn     = (New-Brush '#B26A00')
      accent1  = (New-Brush $script:cfg.accent)
      ck       = $ck
    }
  }
  return @{
    text     = (New-Brush '#F2F4F8')
    dim      = (New-Brush '#9BA3B4')
    faint    = (New-Brush '#6E7688')
    gloss    = (New-Brush '#FFFFFF' 80)
    shade    = (New-Brush '#000000' 60)
    cardRow  = (New-Brush $script:cfg.accent 22)
    cardRowB = (New-Brush $script:cfg.accent 44)
    rowTop   = (New-Brush '#FFFFFF' 34)
    rowBot   = (New-Brush '#FFFFFF' 12)
    live     = (New-Brush '#34D399')
    idle     = (New-Brush '#6E7688')
    err      = (New-Brush '#F87171')
    warn     = (New-Brush '#FBBF24')
    accent1  = (New-Brush $script:cfg.accent)
    ck       = $ck
  }
}

$script:cur = $null
function Apply-Theme([bool]$light) {
  $p = Build-Paint $light
  $script:cur = $p
  # 两卡一致：同一着色玻璃 + 同一描边；模糊层在下方透出
  $u.Card.Background = $null
  $u.UsageCard.Background = $null
  $tint = New-Tint $light
  $u.TintMain.Background = $tint
  $u.TintUsage.Background = $tint
  $sheen = New-BorderSheen $light
  $u.Card.BorderBrush = $sheen
  $u.UsageCard.BorderBrush = $sheen
  # 玻璃层整体不透明度（cardAlpha）：仅作用于模糊+着色层，文字保持清晰
  $u.BlurMain.Opacity = $p.ck
  $u.TintMain.Opacity = $p.ck
  $u.BlurUsage.Opacity = $p.ck
  $u.TintUsage.Opacity = $p.ck
  # 顶部液态高光带（玻璃反射）
  $u.GlossLine.Background = New-Grad @([System.Windows.Media.GradientStop]::new(($p.gloss).Color, 0.0), [System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb(0, 255, 255, 255), 0.7))
  # 顶部径向高光：光打在玻璃上的漫反射（液态玻璃签名）
  $u.SpecGlow.Background = New-Radial '#FFFFFF' $(if ($light) { 50 } else { 34 }) 0.95 0.55
  $u.UsageGloss.Background = New-Radial '#FFFFFF' $(if ($light) { 44 } else { 30 }) 0.85 0.5
  $u.MainShadow.Background = ($p.shade)
  $u.UsageShadow.Background = ($p.shade)
  # 用量卡文字
  $u.UHead.Foreground = $p.faint
  foreach ($pair in @(@("UTkn",$p.text),@("USpend",$p.text),@("URemTkn",$p.text),@("UQuota",$p.text))) {
    $u.($pair[0]).Foreground = $pair[1]; $u.($pair[0]).Typography.NumeralAlignment = [System.Windows.FontNumeralAlignment]::Tabular
  }
  foreach ($pair in @(@("UTknL",$p.dim),@("USpendL",$p.dim),@("URemTknL",$p.dim),@("UQuotaL",$p.dim))) {
    $u.($pair[0]).Foreground = $pair[1]
  }
  $u.Offline.Foreground = $p.err
  $u.FootLeft.Foreground = $p.faint
  $u.FootLeft.Typography.NumeralAlignment = [System.Windows.FontNumeralAlignment]::Tabular
  # 主题切换时一并重绘已存在的任务行（颜色/透明度立即全局生效）
  Repaint-Rows
  # 本环境 WPF 失效传播不可靠：强制重绘使主题/配置立即生效
  if ($script:hwnd -ne [IntPtr]::Zero) {
    try { [void][DshW.Native]::RedrawWindow($script:hwnd, [IntPtr]::Zero, [IntPtr]::Zero, 0x0001 -bor 0x0002 -bor 0x0080) } catch {}
  }
}

function Is-LightTheme {
  try {
    $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
    return ($v.AppsUseLightTheme -eq 1)
  } catch { return $false }
}

# ── 高斯模糊玻璃层 ──────────────────────────────────────────────────
# 截屏窗口背后的桌面区域，做高斯模糊。截屏前窗口 Opacity=0 暂隐，避免把自身
# 也截进去导致「旧模糊叠加新模糊」递归。每卡截其屏幕矩形，对齐精确。
$script:capturing = $false
$script:blurPending = $false
function Get-DpiScale {
  try { return [System.Windows.Media.VisualTreeHelper]::GetDpi($win).PixelsPerDip } catch { return 1.0 }
}
function Capture-Card([System.Windows.Controls.Border]$border, [System.Windows.Controls.Image]$img) {
  try {
    $scale = Get-DpiScale
    $w = [int]([math]::Max(1, $border.ActualWidth) * $scale)
    $h = [int]([math]::Max(1, $border.ActualHeight) * $scale)
    $off = $border.TranslatePoint([System.Windows.Point]::new(0,0), $win)
    $sx = [int](($win.Left + $off.X) * $scale)
    $sy = [int](($win.Top + $off.Y) * $scale)
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try { $g.CopyFromScreen($sx, $sy, 0, 0, $bmp.Size) } finally { $g.Dispose() }
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $ms.Position = 0
    $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create($ms, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $frame = $dec.Frames[0]
    $bmp.Dispose()
    $img.Source = $frame
    if ($null -eq $img.Effect) {
      $be = New-Object System.Windows.Media.Effects.BlurEffect
      $be.Radius = 24
      $be.RenderingBias = [System.Windows.Media.Effects.RenderingBias]::Quality
      $img.Effect = $be
    }
  } catch { /* 截屏失败（如窗口尚未布局）忽略 */ }
}
function Capture-Blur {
  if ($script:capturing) { return }
  if ($script:dragging) { return }   # 拖拽中不截屏，避免每帧闪烁
  if ($null -eq $win -or $win.IsLoaded -eq $false) { return }
  if ($u.Card.ActualWidth -le 0 -or $u.UsageCard.ActualHeight -le 0) { return }
  $script:capturing = $true
  try {
    $win.Opacity = 0
    Start-Sleep -Milliseconds 40   # 等 DWM 把桌面画出来，避免截到自身
    Capture-Card $u.Card $u.BlurMain
    Capture-Card $u.UsageCard $u.BlurUsage
  } catch {} finally {
    $win.Opacity = 1
    $script:capturing = $false
  }
}
# 移动/缩放时防抖刷新（避免拖动中每像素都截屏闪烁）
function Schedule-Blur {
  if ($script:blurPending) { return }
  $script:blurPending = $true
  $t = New-Object System.Windows.Threading.DispatcherTimer
  $t.Interval = [TimeSpan]::FromMilliseconds(220)
  $t.Add_Tick({ param($s, $e) $script:blurPending = $false; $s.Stop(); Capture-Blur })
  $t.Start()
}

# ── 格式化工具 ──────────────────────────────────────────────────────
function Fmt-Tokens([double]$n) {
  if ($null -eq $n -or [double]::IsNaN($n)) { return "—" }
  if ($n -lt 1000) { return [math]::Round($n).ToString() }
  if ($n -lt 1e6) { return ([math]::Round($n/1e3*10)/10).ToString() + "K" }
  return ([math]::Round($n/1e6*10)/10).ToString() + "M"
}
function Fmt-Money([double]$n, [string]$cur) {
  if ($null -eq $n -or [double]::IsNaN($n)) { return "—" }
  $sym = if ($cur -eq "USD") { "$" } else { "¥" }
  return $sym + ($n.ToString("0.00"))
}
function Fmt-Ago([long]$ts) {
  if ($ts -le 0) { return "—" }
  $d = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $ts
  if ($d -lt 0) { $d = 0 }
  if ($d -lt 10000) { return "刚刚" }
  if ($d -lt 60000) { return [math]::Floor($d/1e3).ToString() + " 秒前" }
  if ($d -lt 3600000) { return [math]::Floor($d/60e3).ToString() + " 分钟前" }
  if ($d -lt 86400000) { return [math]::Floor($d/3600e3).ToString() + " 小时前" }
  return ([DateTimeOffset]::FromUnixTimeMilliseconds($ts).ToLocalTime().ToString("HH:mm"))
}
function Fmt-Dur([long]$ms) {
  if ($ms -le 0) { return "" }
  $s = [math]::Floor($ms/1e3)
  if ($s -lt 60) { return ($s.ToString() + "s") }
  $m = [math]::Floor($s/60); $r = $s % 60
  if ($m -lt 60) { return ($m.ToString() + "m " + $r.ToString() + "s") }
  return ([math]::Floor($m/60)).ToString() + "h " + ($m % 60).ToString() + "m"
}

$script:bootTs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$script:lastSeenToast = 0
$script:toastTimers = @()

# ── 任务行 ──────────────────────────────────────────────────────────
# 任务行背景：hover 提亮（液态玻璃微交互）
function Row-Bg([bool]$hover) {
  $top = ($cur.rowTop).Color
  $bot = ($cur.rowBot).Color
  $ta = $top.A; $ba = $bot.A
  if ($hover) { $ta = [math]::Min(255, $ta + 30); $ba = [math]::Min(255, $ba + 22) }
  $topC = [System.Windows.Media.Color]::FromArgb($ta, $top.R, $top.G, $top.B)
  $botC = [System.Windows.Media.Color]::FromArgb($ba, $bot.R, $bot.G, $bot.B)
  return New-Grad @([System.Windows.Media.GradientStop]::new($topC, 0.0), [System.Windows.Media.GradientStop]::new($botC, 1.0))
}

function New-TaskRow($t) {
  # 任务卡：项目名（主行）+ 工作区名（cwd basename，暗色副行）；running=三点跑马灯
  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = [System.Windows.CornerRadius]::new(10)
  $b.Margin = [System.Windows.Thickness]::new(0,0,0,6)
  $b.Padding = [System.Windows.Thickness]::new(10,7,10,7)
  $b.Tag = [string]$t.id
  $b.Cursor = "Hand"
  $b.ToolTip = "点击跳转到该会话"
  $b.BorderThickness = [System.Windows.Thickness]::new(1)
  $running = [bool]$t.running
  if ($running) { $b.BorderBrush = ($cur.live) } else { $b.BorderBrush = New-Grad @([System.Windows.Media.GradientStop]::new(($cur.cardRowB).Color, 0.0), [System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb([int]($cur.cardRowB.Color.A * 0.5), ($cur.cardRowB).Color.R, ($cur.cardRowB).Color.G, ($cur.cardRowB).Color.B), 1.0)) }
  $line1 = New-Object System.Windows.Controls.StackPanel
  $line1.Orientation = "Horizontal"
  # 运行中：三点跑马灯
  $dots = @()
  foreach ($di in 0..2) {
    $td = New-Object System.Windows.Controls.TextBlock
    $td.FontSize = 11; $td.VerticalAlignment = "Center"
    $td.Margin = [System.Windows.Thickness]::new(0,0,2,0)
    $td.Foreground = ($cur.accent1)
    $td.Text = $(if ($di -eq 0) { [char]0x25CF } else { [char]0x25CB })
    [void]$line1.Children.Add($td)
    $dots += $td
  }
  if (-not $running) { foreach ($td in $dots) { $td.Visibility = "Collapsed" } }
  # 静态点（idle 时可见）
  $dot = New-Object System.Windows.Shapes.Ellipse
  $dot.Width = 8; $dot.Height = 8
  $dot.VerticalAlignment = "Center"; $dot.Margin = [System.Windows.Thickness]::new(3,0,9,0)
  $dot.Fill = $cur.idle
  if ($running) { $dot.Visibility = "Collapsed" }
  [void]$line1.Children.Add($dot)

  $title = New-Object System.Windows.Controls.TextBlock
  $title.Text = [string]$t.title; $title.FontSize = 12.5; $title.FontWeight = "Medium"
  $title.Foreground = $cur.text; $title.VerticalAlignment = "Center"
  $title.TextTrimming = "CharacterEllipsis"; $title.MaxWidth = 188
  [void]$line1.Children.Add($title)
  $st = New-Object System.Windows.Controls.TextBlock
  $st.Text = "运行中"; $st.FontSize = 9.5; $st.Foreground = ($cur.live)
  $st.VerticalAlignment = "Center"; $st.Margin = [System.Windows.Thickness]::new(8,0,0,0)
  if (-not $running) { $st.Visibility = "Collapsed" }
  [void]$line1.Children.Add($st)

  # 工作区名（副行，与项目名区分）
  $ws = New-Object System.Windows.Controls.TextBlock
  $wsText = [string]$t.workspace
  if ($wsText -and $wsText -ne [string]$t.title) {
    $ws.Text = "工作区 · " + $wsText
    $ws.FontSize = 9.5; $ws.Foreground = $cur.faint; $ws.Margin = [System.Windows.Thickness]::new(0,2,0,0)
    $ws.TextTrimming = "CharacterEllipsis"; $ws.MaxWidth = 200
  } else { $ws.Visibility = "Collapsed" }

  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.Orientation = "Vertical"
  [void]$sp.Children.Add($line1)
  if ($ws.Visibility -ne "Collapsed") { [void]$sp.Children.Add($ws) }
  $b.Child = $sp

  # 行结构（含 hover 状态与缓存背景，供 Repaint-Rows 复用）
  $row = @{
    border = $b; dots = $dots; dot = $dot; title = $title; st = $st; ws = $ws;
    running = $running; hovering = $false;
    baseBg = (Row-Bg $false); hoverBg = (Row-Bg $true)
  }
  $b.Background = $row.baseBg
  # hover 微交互（提亮）
  $b.Add_MouseEnter({ param($s, $e) try { $row.hovering = $true; $s.Background = $row.hoverBg } catch {} })
  $b.Add_MouseLeave({ param($s, $e) try { $row.hovering = $false; $s.Background = $row.baseBg } catch {} })
  return $row
}

function New-Toast($ev) {
  $b = New-Object System.Windows.Controls.Border
  $b.CornerRadius = [System.Windows.CornerRadius]::new(10)
  $b.Margin = [System.Windows.Thickness]::new(0,0,0,6); $b.Padding = [System.Windows.Thickness]::new(11,8,11,8)
  $b.Cursor = "Hand"
  $b.Background = New-Brush "#171A21" 236
  $b.BorderBrush = New-Brush "#FFFFFF" 42; $b.BorderThickness = [System.Windows.Thickness]::new(1)
  $sp = New-Object System.Windows.Controls.StackPanel
  $sp.Orientation = "Horizontal"
  $ico = New-Object System.Windows.Controls.TextBlock
  $ico.FontFamily = [System.Windows.Media.FontFamily]::new("Segoe MDL2 Assets")
  if ($ev.kind -eq "job-done") { $ico.Text = [string][char]0xE713 } elseif ($ev.kind -eq "todos-done") { $ico.Text = [string][char]0xE930 } else { $ico.Text = [string][char]0xE73E }
  $ico.FontSize = 13; $ico.Margin = [System.Windows.Thickness]::new(0,0,8,0); $ico.VerticalAlignment = "Center"
  if ($ev.kind -eq "job-done") { $ico.Foreground = ($cur.accent1) } else { $ico.Foreground = ($cur.live) }
  $body = New-Object System.Windows.Controls.StackPanel
  $t1 = New-Object System.Windows.Controls.TextBlock
  $t1.Text = [string]$ev.title; $t1.FontSize = 12; $t1.FontWeight = "SemiBold"; $t1.Foreground = [System.Windows.Media.Brushes]::White
  $t2 = New-Object System.Windows.Controls.TextBlock
  $t2.Text = [string]$ev.detail; $t2.FontSize = 10; $t2.Foreground = (New-Brush "#9BA3B4")
  $t2.TextTrimming = "CharacterEllipsis"; $t2.MaxWidth = 220
  [void]$body.Children.Add($t1); [void]$body.Children.Add($t2)
  [void]$sp.Children.Add($ico); [void]$sp.Children.Add($body)
  $b.Child = $sp
  # 点击关闭：$this = 发送者（Border 自身）
  $b.Add_MouseLeftButtonUp({ $this.Visibility = "Collapsed" })
  return $b
}

# ── 渲染 ────────────────────────────────────────────────────────────
$script:snap = $null
$script:taskRows = @{}   # sessionId -> 行结构（行复用：不重建卡片，动画不被打断）

$script:spinners = @()
$script:spinDriver = $null
function Start-Spin($row) {
  # 三点跑马灯：200ms 依次点亮（文本通道，渲染可靠）
  $row.spinIdx = 0
  $script:spinners += $row
  if ($null -eq $script:spinDriver) {
    $script:spinDriver = New-Object System.Windows.Threading.DispatcherTimer
    $script:spinDriver.Interval = [TimeSpan]::FromMilliseconds(200)
    $script:spinDriver.Add_Tick({
      foreach ($r in @($script:spinners)) {
        try {
          $r.spinIdx = ($r.spinIdx + 1) % 3
          for ($di = 0; $di -lt 3; $di++) {
            $r.dots[$di].Text = $(if ($di -eq $r.spinIdx) { [char]0x25CF } else { [char]0x25CB })
          }
        } catch {}
      }
    })
    $script:spinDriver.Start()
  }
}
function Stop-Spin($row) {
  $script:spinners = @($script:spinners | Where-Object { $_ -ne $row })
  if (@($script:spinners).Count -eq 0 -and $null -ne $script:spinDriver) {
    $script:spinDriver.Stop()
    $script:spinDriver = $null
  }
}

# 主题/配置热应用：重绘已有任务行（颜色/透明度立即可见，不只是新行）
function Repaint-Rows {
  if ($null -eq $cur) { return }
  foreach ($id in @($script:taskRows.Keys)) {
    try {
      $row = $script:taskRows[$id]
      $row.baseBg = (Row-Bg $false)
      $row.hoverBg = (Row-Bg $true)
      if (-not $row.hovering) { $row.border.Background = $row.baseBg }
      if ($row.running) { $row.border.BorderBrush = ($cur.live) } else { $row.border.BorderBrush = New-Grad @([System.Windows.Media.GradientStop]::new(($cur.cardRowB).Color, 0.0), [System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb([int]($cur.cardRowB.Color.A * 0.5), ($cur.cardRowB).Color.R, ($cur.cardRowB).Color.G, ($cur.cardRowB).Color.B), 1.0)) }
      foreach ($td in $row.dots) { $td.Foreground = ($cur.accent1) }
      $row.dot.Fill = $cur.idle
      $row.title.Foreground = $cur.text
      $row.st.Foreground = ($cur.live)
      $row.ws.Foreground = $cur.faint
    } catch {}
  }
}

function Render-Snapshot {
  $s = $script:snap
  if ($null -eq $s) { return }
  $u.Offline.Visibility = "Collapsed"
  # 收集压力/用量/余额（取首个带上下文窗口的会话）
  $pressure = $null; $usage = $null; $balance = $s.balance
  foreach ($ss in $s.sessions) {
    if ($ss.contextPressure -and $ss.contextPressure.contextWindow) {
      $pressure = $ss.contextPressure; $usage = $ss.tokenUsage; break
    }
  }
  # —— 底部卡：四项指标 ——
  $used = 0; $cap = 0
  if ($null -ne $pressure) {
    if ($null -ne $pressure.projectedTokens) { $used = [double]$pressure.projectedTokens } else { $used = [double]$pressure.pressureTokens }
    $cap = [double]$pressure.contextWindow
  }
  # Token 用量（总耗 token）
  $tknTotal = 0
  if ($null -ne $usage) {
    $tknTotal = [double]$usage.uncachedInputTokens + [double]$usage.cacheReadTokens + [double]$usage.cacheWriteTokens + [double]$usage.outputTokens
  }
  $u.UTkn.Text = if ($tknTotal -gt 0) { Fmt-Tokens $tknTotal } else { "—" }
  # 当前花费（¥，总额度 − 可用额度）
  if ($null -ne $balance -and $null -ne $balance.total -and $null -ne $balance.available) {
    $u.USpend.Text = Fmt-Money ([double]$balance.total - [double]$balance.available) ($balance.currency)
  } elseif ($null -ne $balance -and $balance.error -and $balance.error -ne "no-api-key") {
    $u.USpend.Text = "查询失败"
  } else { $u.USpend.Text = "—" }
  # 剩余 Token 量（上下文容量 − 已用）
  if ($cap -gt 0) { $u.URemTkn.Text = Fmt-Tokens ([math]::Max(0, $cap - $used)) } else { $u.URemTkn.Text = "—" }
  # 剩余额度（可用余额）
  if ($null -ne $balance -and $null -ne $balance.available) {
    $u.UQuota.Text = Fmt-Money ([double]$balance.available) ($balance.currency)
  } elseif ($null -ne $balance -and $balance.error -and $balance.error -ne "no-api-key") {
    $u.UQuota.Text = "查询失败"
  } else { $u.UQuota.Text = "—" }

  # —— 主卡：任务列表（行复用）——
  $seen = @{}
  foreach ($ss in $s.sessions) {
    $id = [string]$ss.id
    $running = [bool]$ss.running
    $seen[$id] = $true
    $row = $script:taskRows[$id]
    if ($null -ne $row) {
      $row.title.Text = [string]$ss.title
      if ($ss.workspace -and $ss.workspace -ne [string]$ss.title) {
        $row.ws.Text = "工作区 · " + [string]$ss.workspace; $row.ws.Visibility = "Visible"
      } else { $row.ws.Visibility = "Collapsed" }
      if ($running) {
        if (-not $row.running) {
          foreach ($td in $row.dots) { $td.Visibility = "Visible" }
          $row.dot.Visibility = "Collapsed"; $row.st.Visibility = "Visible"
          $row.border.BorderBrush = ($cur.live)
          Start-Spin $row
        }
      } else {
        if ($row.running) {
          foreach ($td in $row.dots) { $td.Visibility = "Collapsed" }
          $row.dot.Visibility = "Visible"; $row.st.Visibility = "Collapsed"
          $row.border.BorderBrush = New-Grad @([System.Windows.Media.GradientStop]::new(($cur.cardRowB).Color, 0.0), [System.Windows.Media.GradientStop]::new([System.Windows.Media.Color]::FromArgb([int]($cur.cardRowB.Color.A * 0.5), ($cur.cardRowB).Color.R, ($cur.cardRowB).Color.G, ($cur.cardRowB).Color.B), 1.0))
          Stop-Spin $row
        }
      }
      $row.running = $running
    } else {
      $row = New-TaskRow @{ id = $id; title = [string]$ss.title; workspace = [string]($ss.workspace); running = $running }
      [void]$u.TaskPanel.Children.Add($row.border)
      if ($running) { Start-Spin $row }
      $script:taskRows[$id] = $row
    }
  }
  # 清理消失的会话行
  foreach ($id in @($script:taskRows.Keys)) {
    if (-not $seen.ContainsKey($id)) {
      $gone = $script:taskRows[$id]
      Stop-Spin $gone
      $u.TaskPanel.Children.Remove($gone.border)
      $script:taskRows.Remove($id)
    }
  }
  if ($u.TaskPanel.Children.Count -eq 0) {
    $e = New-Object System.Windows.Controls.TextBlock
    $e.Text = "暂无任务"; $e.FontSize = 11; $e.Foreground = $cur.faint
    $e.HorizontalAlignment = "Center"; $e.Margin = [System.Windows.Thickness]::new(0,14,0,14)
    [void]$u.TaskPanel.Children.Add($e)
  }

  $now = Get-Date
  $u.FootLeft.Text = "更新于 " + $now.ToString("HH:mm:ss") + " · " + $s.sessions.Count + " 会话"
  foreach ($ev in $s.events) {
    $ts = [long]$ev.ts
    if ($ts -le $script:lastSeenToast) { continue }
    $script:lastSeenToast = $ts
    if ($u.ToastPanel.Children.Count -ge 3) { $u.ToastPanel.Children.RemoveAt(0) }
    $toast = New-Toast $ev
    [void]$u.ToastPanel.Children.Add($toast)
    # 进入动画：200ms ease-out（translateY -12px + 淡入）
    if ([System.Windows.SystemParameters]::ClientAreaAnimation) {
      $toast.RenderTransformOrigin = [System.Windows.Point]::new(0.5, 0.5)
      $tr = New-Object System.Windows.Media.TranslateTransform
      $tr.Y = -12
      $toast.RenderTransform = $tr
      $toast.Opacity = 0
      $animO = New-Object System.Windows.Media.Animation.DoubleAnimation(1, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(200)))
      $animO.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
      $null = $toast.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $animO)
      $animY = New-Object System.Windows.Media.Animation.DoubleAnimation(0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(200)))
      $animY.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase
      $tr.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $animY)
    }
    $dt = New-Object System.Windows.Threading.DispatcherTimer
    $dt.Interval = [TimeSpan]::FromSeconds(6)
    $toast.Tag = $dt
    $dt.Add_Tick({
      param($s2, $e2)
      $s2.Stop()
      $target = $s2.Tag
      if ($null -eq $target) { return }
      if ([System.Windows.SystemParameters]::ClientAreaAnimation) {
        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(150)))
        $fade.Tag = $target
        $fade.add_Completed({ $u.ToastPanel.Children.Remove($this.Tag) })
        $target.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
      } else {
        $u.ToastPanel.Children.Remove($target)
      }
    })
    $dt.Start()
  }
}

# ── 命令文件轮询（宿主控制）────────────────────────────────────────
function Process-Command {
  if (-not (Test-Path $CommandFile)) { return }
  try {
    $cmd = Get-Content $CommandFile -Raw | ConvertFrom-Json
    Remove-Item $CommandFile -Force -ErrorAction SilentlyContinue
  } catch { return }
  # 启动 2.5s 内的 quit 视为宿主重载残留，忽略（防毒死新进程）
  $age = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $script:bootTs
  if ($cmd.action -eq "quit" -and $age -lt 2500) { return }
  switch ($cmd.action) {
    "show" { $win.Show(); $win.Activate() }
    "hide" { $win.Hide() }
    "toggle" { if ($win.IsVisible) { $win.Hide() } else { $win.Show(); $win.Activate() } }
    "config" {
      # 软件内调整：重读 .config.json 并立即应用
      try {
        if (Test-Path $script:cfgFile) {
          $saved = Get-Content $script:cfgFile -Raw | ConvertFrom-Json
          if ($saved.accent -and $saved.accent -match '^#[0-9A-Fa-f]{6}$') { $script:cfg.accent = $saved.accent }
          if ($null -ne $saved.alpha -and [int]$saved.alpha -ge 40 -and [int]$saved.alpha -le 100) { $script:cfg.alpha = [int]$saved.alpha }
          if ($null -ne $saved.cardAlpha -and [int]$saved.cardAlpha -ge 40 -and [int]$saved.cardAlpha -le 100) { $script:cfg.cardAlpha = [int]$saved.cardAlpha }
          if ($null -ne $saved.locked) { $script:cfg.locked = [bool]$saved.locked }
        }
      } catch {}
      Apply-Theme (Is-LightTheme)
      Capture-Blur
      # 锁定状态同步到锁按钮
      if ($script:cfg.locked) { $u.LockGlyph.Text = [string][char]0xE72E; $u.LockBtn.ToolTip = '已锁定位置（解锁后可拖动）' } else { $u.LockGlyph.Text = [string][char]0xE785; $u.LockBtn.ToolTip = '锁定位置（锁定后不可拖动）' }
    }
    "quit" { $win.Close() }
  }
}

# ── 事件处理与接线 ────────────────────────────────────────────────
# 拖拽：整主卡可拖（锁定后禁用）；锁按钮在右下角
function OnLock {
  $script:cfg.locked = -not $script:cfg.locked
  if ($script:cfg.locked) { $u.LockGlyph.Text = [string][char]0xE72E } else { $u.LockGlyph.Text = [string][char]0xE785 }
  $u.LockBtn.ToolTip = $(if ($script:cfg.locked) { '已锁定位置（解锁后可拖动）' } else { '锁定位置（锁定后不可拖动）' })
  try { Set-Content -Path $script:cfgFile -Value (@{ accent = $script:cfg.accent; alpha = $script:cfg.alpha; cardAlpha = $script:cfg.cardAlpha; locked = $script:cfg.locked } | ConvertTo-Json) -Encoding utf8 } catch {}
}
# 手动拖拽（稳健：不受 DragMove 状态影响；锁定检查在按下/移动时都生效）
$script:dragging = $false
$script:wasDragging = $false
$script:dragStartPos = $null
$script:dragWinPos = $null
# 拖动在 Preview 阶段处理（bubbling 的 MouseLeftButtonDown 在本环境被内层拦截）
$u.Card.Add_PreviewMouseLeftButtonDown({
  param($s, $e)
  # 锁按钮区域不触发拖动（向上回溯找到 LockBtn 即跳过）
  $n = $e.OriginalSource
  while ($null -ne $n) {
    if ($n -eq $u.LockBtn) { return }
    $n = [System.Windows.Media.VisualTreeHelper]::GetParent($n)
  }
  if ($script:cfg.locked) { return }
  $script:dragging = $true
  $script:dragStartPos = [System.Windows.Forms.Cursor]::Position
  $script:dragWinPos = @([double]$win.Left, [double]$win.Top)
  $u.Card.CaptureMouse()
  $e.Handled = $true
})
$u.Card.Add_MouseMove({
  param($s, $e)
  if (-not $script:dragging) { return }
  if ($script:cfg.locked) { $script:dragging = $false; $u.Card.ReleaseMouseCapture(); return }
  $p = [System.Windows.Forms.Cursor]::Position
  if ([math]::Abs($p.X - $script:dragStartPos.X) + [math]::Abs($p.Y - $script:dragStartPos.Y) -gt 8) { $script:wasDragging = $true }
  $win.Left = $script:dragWinPos[0] + ($p.X - $script:dragStartPos.X)
  $win.Top = $script:dragWinPos[1] + ($p.Y - $script:dragStartPos.Y)
  $e.Handled = $true
})
$u.Card.Add_MouseLeftButtonUp({
  param($s, $e)
  $script:dragging = $false
  $u.Card.ReleaseMouseCapture()
  # 任务卡点击跳转（拖动超过阈值则不跳转）
  if ($script:wasDragging) { $script:wasDragging = $false; return }
  if ($script:cfg.locked) { return }
  $node = $e.OriginalSource
  while ($null -ne $node) {
    if ($node -is [System.Windows.FrameworkElement] -and $null -ne $node.Tag -and $node.Tag -is [string] -and [string]$node.Tag -ne '') { break }
    $node = [System.Windows.Media.VisualTreeHelper]::GetParent($node)
  }
  if ($null -ne $node -and $null -ne $node.Tag) {
    try { Invoke-RestMethod -Uri ($BaseUrl + "/api/ctl?action=activate&session=" + [Uri]::EscapeDataString([string]$node.Tag)) -Method Post -TimeoutSec 3 | Out-Null } catch {}
  }
})
# 锁按钮直接挂 Click（之前挂的 PreviewMouseLeftButtonDown{Handled=true} 会吞掉 Click，
# 导致锁按钮点了没反应——这是「锁定功能无法使用」的根因）。拖拽拦截已由 Card 的
# Preview 处理器在向上回溯到 LockBtn 时 return 处理，无需在 LockBtn 上再拦。
$u.LockBtn.Add_Click({ OnLock })

# ── 启动 ────────────────────────────────────────────────────────────
$app = New-Object System.Windows.Application
$script:lastLight = $null

# 纯 WPF 自绘液态玻璃 + 真高斯模糊（截屏背后桌面），不依赖 DWM backdrop，
# 深/浅主题与激活态一致。
$script:hwnd = [IntPtr]::Zero
function Apply-Backdrop([bool]$light) {
  $win.Background = [System.Windows.Media.Brushes]::Transparent
}

$null = $win.Add_Loaded({
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $win.Left = $wa.Right - $win.Width - 20
  $win.Top = $wa.Top + 20
  $script:hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
  $script:lastLight = $null
  Apply-Theme (Is-LightTheme)
  Schedule-Blur   # 首帧模糊（窗口已定位）
  # 锁按钮初始状态（跟随配置）
  if ($script:cfg.locked) { $u.LockGlyph.Text = [string][char]0xE72E; $u.LockBtn.ToolTip = '已锁定位置（解锁后可拖动）' } else { $u.LockGlyph.Text = [string][char]0xE785; $u.LockBtn.ToolTip = '锁定位置（锁定后不可拖动）' }
})
# 移动/缩放时刷新模糊（防抖）
$null = $win.Add_LocationChanged({ Schedule-Blur })
$null = $win.Add_SizeChanged({ Schedule-Blur })

$themeTimer = New-Object System.Windows.Threading.DispatcherTimer
$themeTimer.Interval = [TimeSpan]::FromSeconds(5)
$themeTimer.Add_Tick({
  $light = Is-LightTheme
  if ($light -ne $script:lastLight) {
    $script:lastLight = $light
    Apply-Theme $light
    Capture-Blur
  }
})

# 周期刷新模糊（背景变化也能反映；Opacity 暂隐仅 ~40ms，几乎无感）
$blurTimer = New-Object System.Windows.Threading.DispatcherTimer
$blurTimer.Interval = [TimeSpan]::FromSeconds(5)
$blurTimer.Add_Tick({ Capture-Blur })

$fetchTimer = New-Object System.Windows.Threading.DispatcherTimer
$fetchTimer.Interval = [TimeSpan]::FromSeconds(2)
$fetchTimer.Add_Tick({
  try {
    $r = Invoke-RestMethod -Uri ($BaseUrl + "/api/snapshot") -TimeoutSec 4
    $script:snap = $r
    try { Render-Snapshot } catch {}
  } catch {
    $u.Offline.Visibility = "Visible"
  }
})

$cmdTimer = New-Object System.Windows.Threading.DispatcherTimer
$cmdTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$cmdTimer.Add_Tick({ Process-Command })

$null = $win.Add_Closed({
  $fetchTimer.Stop(); $cmdTimer.Stop(); $themeTimer.Stop(); $blurTimer.Stop()
  foreach ($t in $script:toastTimers) { try { $t.Stop() } catch {} }
  [System.Windows.Application]::Current.Shutdown()
})

$script:lastLight = (Is-LightTheme)
Apply-Theme $script:lastLight
$themeTimer.Start(); $fetchTimer.Start(); $cmdTimer.Start(); $blurTimer.Start()
$null = $app.Run($win)

# EOF
